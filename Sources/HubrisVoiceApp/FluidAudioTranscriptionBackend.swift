import Foundation
import HubrisVoiceCore

final class FluidAudioTranscriptionBackend: TranscriptionEngineRuntime, @unchecked Sendable {
  let events: AsyncStream<TranscriptionEngineEvent>

  private let commands = TranscriptionEngineCommandPipe()
  private let state: FluidAudioTranscriptionState
  private var commandTask: Task<Void, Never>?

  convenience init(
    store: LocalModelStore,
    context: LocalInvocationContext,
    correctionPolicy: LocalCorrectionPolicy
  ) {
    self.init(
      context: context,
      correctionPolicy: correctionPolicy,
      processor: FluidAudioProcessor(),
      acquireModels: { _, _ in
        let primary = try await store.acquire(LocalModelCatalog.primaryID)
        return FluidAudioModelLease(
          primaryDirectory: primary.directory,
          release: { await store.release(primary) }
        )
      },
      acquireCorrection: {
        let correction = try await store.acquire(LocalModelCatalog.correctionID)
        return FluidAudioCorrectionLease(
          directory: correction.directory,
          release: { await store.release(correction) }
        )
      }
    )
  }

  init(
    context: LocalInvocationContext,
    correctionPolicy: LocalCorrectionPolicy,
    processor: any FluidAudioProcessing,
    acquireModels: @escaping @Sendable (
      LocalInvocationContext,
      LocalCorrectionPolicy
    ) async throws -> FluidAudioModelLease,
    acquireCorrection: @escaping @Sendable () async throws -> FluidAudioCorrectionLease? = { nil }
  ) {
    let pair = AsyncStream.makeStream(of: TranscriptionEngineEvent.self)
    events = pair.stream
    state = FluidAudioTranscriptionState(
      context: context,
      correctionPolicy: correctionPolicy,
      processor: processor,
      acquireModels: acquireModels,
      acquireCorrection: acquireCorrection,
      events: pair.continuation
    )
    let stream = commands.stream
    commandTask = Task { [state, commands] in
      for await command in stream {
        commands.didConsume(command)
        guard !Task.isCancelled else { return }
        await state.handle(command)
      }
    }
  }

  deinit { commandTask?.cancel() }

  func submit(_ command: TranscriptionEngineCommand) -> Bool {
    commands.submit(command)
  }

  func unload() async {
    await state.unload()
  }

  func updateConfiguration(
    context: LocalInvocationContext,
    correctionPolicy: LocalCorrectionPolicy
  ) async throws -> Bool {
    try await state.updateConfiguration(context: context, correctionPolicy: correctionPolicy)
  }
}

struct FluidAudioModelLease: Sendable {
  let primaryDirectory: URL
  let release: @Sendable () async -> Void
}

struct FluidAudioCorrectionLease: Sendable {
  let directory: URL
  let release: @Sendable () async -> Void
}

private actor FluidAudioTranscriptionState {
  private struct Invocation {
    var nextSequence = 0
    var audioBytes = 0
    var chunks: [Data] = []
    var finishRequested = false
  }

  private static let maximumInvocations = 4
  private static let maximumAudioBytes = 90 * 16_000 * MemoryLayout<Int16>.size

  private var context: LocalInvocationContext
  private var correctionPolicy: LocalCorrectionPolicy
  private let processor: any FluidAudioProcessing
  private let acquireModels: @Sendable (
    LocalInvocationContext,
    LocalCorrectionPolicy
  ) async throws -> FluidAudioModelLease
  private let acquireCorrection: @Sendable () async throws -> FluidAudioCorrectionLease?
  private let events: AsyncStream<TranscriptionEngineEvent>.Continuation
  private var epoch = TranscriptionBackendEpoch(0)
  private var lease: FluidAudioModelLease?
  private var correctionLease: FluidAudioCorrectionLease?
  private var isPrepared = false
  private var isReconfiguring = false
  private var preparationGeneration = 0
  private var preparationTask: Task<Void, Never>?
  private var operationTask: Task<Void, Never>?
  private var order: [TranscriptionInvocationID] = []
  private var invocations: [TranscriptionInvocationID: Invocation] = [:]
  private var activeID: TranscriptionInvocationID?
  private var retired: Set<TranscriptionInvocationID> = []

  init(
    context: LocalInvocationContext,
    correctionPolicy: LocalCorrectionPolicy,
    processor: any FluidAudioProcessing,
    acquireModels: @escaping @Sendable (
      LocalInvocationContext,
      LocalCorrectionPolicy
    ) async throws -> FluidAudioModelLease,
    acquireCorrection: @escaping @Sendable () async throws -> FluidAudioCorrectionLease?,
    events: AsyncStream<TranscriptionEngineEvent>.Continuation
  ) {
    self.context = context
    self.correctionPolicy = correctionPolicy
    self.processor = processor
    self.acquireModels = acquireModels
    self.acquireCorrection = acquireCorrection
    self.events = events
  }

  func handle(_ command: TranscriptionEngineCommand) {
    switch command {
    case .prepare(let epoch): prepare(epoch: epoch)
    case .begin(let invocation): begin(invocation)
    case .append(let invocationID, let sequence, let audio):
      append(id: invocationID, sequence: sequence, audio: audio)
    case .finish(let invocationID): finish(id: invocationID)
    case .cancel(let invocationID): cancel(id: invocationID)
    }
  }

  func unload() async {
    preparationGeneration &+= 1
    let pendingPreparation = preparationTask
    let pendingOperation = operationTask
    pendingPreparation?.cancel()
    pendingOperation?.cancel()
    preparationTask = nil
    operationTask = nil
    invocations.removeAll()
    order.removeAll()
    activeID = nil
    isPrepared = false
    isReconfiguring = false
    await pendingPreparation?.value
    await pendingOperation?.value
    await processor.unload()
    if let lease {
      await lease.release()
      self.lease = nil
    }
    if let correctionLease {
      await correctionLease.release()
      self.correctionLease = nil
    }
  }

  func updateConfiguration(
    context: LocalInvocationContext,
    correctionPolicy: LocalCorrectionPolicy
  ) async throws -> Bool {
    guard
      !isReconfiguring,
      preparationTask == nil,
      operationTask == nil,
      activeID == nil,
      order.isEmpty
    else {
      return false
    }
    let previousContext = self.context
    let previousCorrectionPolicy = self.correctionPolicy
    self.context = context
    self.correctionPolicy = correctionPolicy
    guard let lease, isPrepared else { return true }

    isReconfiguring = true
    isPrepared = false
    let needsCorrection = correctionPolicy == .strict && !context.resolvedEntries.isEmpty
    var acquiredCorrectionLease: FluidAudioCorrectionLease?
    if needsCorrection, correctionLease == nil {
      acquiredCorrectionLease = try? await acquireCorrection()
      correctionLease = acquiredCorrectionLease
    }
    do {
      let correctionDirectory = needsCorrection
        ? correctionLease?.directory
        : nil
      try await processor.prepare(
        primaryDirectory: lease.primaryDirectory,
        correctionDirectory: correctionDirectory,
        context: context,
        correctionPolicy: correctionPolicy
      )
      let correctionLeaseToRelease = !needsCorrection ? correctionLease : nil
      if correctionLeaseToRelease != nil {
        correctionLease = nil
      }
      isPrepared = true
      isReconfiguring = false
      await correctionLeaseToRelease?.release()
      pump()
      return true
    } catch {
      if acquiredCorrectionLease != nil {
        correctionLease = nil
      }
      self.context = previousContext
      self.correctionPolicy = previousCorrectionPolicy
      isPrepared = true
      isReconfiguring = false
      await acquiredCorrectionLease?.release()
      throw TranscriptionFailure(
        kind: .configuration,
        message: "The local correction configuration could not be applied.",
        isRecoverable: false
      )
    }
  }

  private func prepare(epoch: TranscriptionBackendEpoch) {
    preparationGeneration &+= 1
    let generation = preparationGeneration
    self.epoch = epoch
    events.yield(.readiness(epoch: epoch, state: .preparing(message: "Loading local model…")))
    preparationTask?.cancel()
    let context = context
    let correctionPolicy = correctionPolicy
    preparationTask = Task { [weak self, acquireModels, acquireCorrection, context, correctionPolicy, processor] in
      do {
        let lease = try await acquireModels(context, correctionPolicy)
        let needsCorrection = correctionPolicy == .strict && !context.resolvedEntries.isEmpty
        let correctionLease = needsCorrection ? try? await acquireCorrection() : nil
        do {
          try Task.checkCancellation()
          try await processor.prepare(
            primaryDirectory: lease.primaryDirectory,
            correctionDirectory: correctionLease?.directory,
            context: context,
            correctionPolicy: correctionPolicy
          )
          try Task.checkCancellation()
        } catch {
          await correctionLease?.release()
          await lease.release()
          throw error
        }
        guard let self else {
          await correctionLease?.release()
          await lease.release()
          return
        }
        await prepared(
          lease: lease,
          correctionLease: correctionLease,
          epoch: epoch,
          generation: generation
        )
      } catch is CancellationError {
        return
      } catch {
        await self?.preparationFailed(error, epoch: epoch, generation: generation)
      }
    }
  }

  private func prepared(
    lease: FluidAudioModelLease,
    correctionLease: FluidAudioCorrectionLease?,
    epoch: TranscriptionBackendEpoch,
    generation: Int
  ) async {
    guard self.epoch == epoch, preparationGeneration == generation else {
      await correctionLease?.release()
      await lease.release()
      return
    }
    let previousLease = self.lease
    let previousCorrectionLease = self.correctionLease
    self.lease = lease
    self.correctionLease = correctionLease
    isPrepared = true
    await previousCorrectionLease?.release()
    await previousLease?.release()
    guard self.epoch == epoch, preparationGeneration == generation else { return }
    preparationTask = nil
    events.yield(.readiness(epoch: epoch, state: .ready))
    pump()
  }

  private func preparationFailed(
    _: Error,
    epoch: TranscriptionBackendEpoch,
    generation: Int
  ) {
    guard self.epoch == epoch, preparationGeneration == generation else { return }
    preparationTask = nil
    isPrepared = false
    let pending = order
    for invocationID in pending where invocations[invocationID] != nil {
      retired.insert(invocationID)
      fail(
        invocationID,
        kind: .configuration,
        message: "The local transcription model could not be loaded."
      )
    }
    invocations.removeAll()
    order.removeAll()
    activeID = nil
    events.yield(.readiness(
      epoch: epoch,
      state: .unavailable(
        reason: "The local transcription model could not be loaded.",
        action: "Download the local model in Settings."
      )
    ))
  }

  private func begin(_ invocation: TranscriptionInvocation) {
    guard invocation.id.epoch == epoch, invocations[invocation.id] == nil,
          !retired.contains(invocation.id)
    else { return }
    guard invocation.format == .local else {
      retired.insert(invocation.id)
      fail(invocation.id, kind: .configuration, message: "Local transcription requires 16 kHz mono PCM16 audio.")
      return
    }
    guard invocations.count < Self.maximumInvocations else {
      retired.insert(invocation.id)
      fail(invocation.id, kind: .capture, message: "Too many local snippets are pending.")
      return
    }
    invocations[invocation.id] = Invocation()
    order.append(invocation.id)
    pump()
  }

  private func append(id invocationID: TranscriptionInvocationID, sequence: Int, audio: Data) {
    guard var invocation = invocations[invocationID], !retired.contains(invocationID),
          !invocation.finishRequested
    else { return }
    guard sequence == invocation.nextSequence else {
      retire(invocationID)
      fail(invocationID, kind: .capture, message: "Local audio arrived out of order.")
      return
    }
    guard invocation.audioBytes + audio.count <= Self.maximumAudioBytes else {
      retire(invocationID)
      fail(invocationID, kind: .capture, message: "Local dictation reached the 90-second audio limit.")
      return
    }
    invocation.nextSequence += 1
    invocation.audioBytes += audio.count
    invocation.chunks.append(audio)
    invocations[invocationID] = invocation
    pump()
  }

  private func finish(id invocationID: TranscriptionInvocationID) {
    guard var invocation = invocations[invocationID], !retired.contains(invocationID) else { return }
    invocation.finishRequested = true
    invocations[invocationID] = invocation
    pump()
  }

  private func cancel(id invocationID: TranscriptionInvocationID) {
    retired.insert(invocationID)
    if retired.count > 100 {
      retired.removeAll(keepingCapacity: true)
      retired.insert(invocationID)
    }
    invocations.removeValue(forKey: invocationID)
    order.removeAll { $0 == invocationID }
    if activeID == invocationID {
      operationTask?.cancel()
    }
    pump()
  }

  private func pump() {
    guard isPrepared, operationTask == nil else { return }
    if activeID == nil {
      activeID = order.first
      guard activeID != nil else { return }
      operationTask = Task { [weak self, processor] in
        do {
          try await processor.reset()
          await self?.operationCompleted(preview: nil, final: nil, error: nil)
        } catch {
          await self?.operationCompleted(preview: nil, final: nil, error: error)
        }
      }
      return
    }
    guard let activeID, var invocation = invocations[activeID] else {
      finishActive()
      return
    }
    if !invocation.chunks.isEmpty {
      let chunk = invocation.chunks.removeFirst()
      invocations[activeID] = invocation
      operationTask = Task { [weak self, processor] in
        do {
          let preview = try await processor.append(chunk)
          await self?.operationCompleted(preview: preview, final: nil, error: nil)
        } catch {
          await self?.operationCompleted(preview: nil, final: nil, error: error)
        }
      }
    } else if invocation.finishRequested {
      operationTask = Task { [weak self, processor] in
        do {
          let final = try await processor.finish()
          await self?.operationCompleted(preview: nil, final: final, error: nil)
        } catch {
          await self?.operationCompleted(preview: nil, final: nil, error: error)
        }
      }
    }
  }

  private func operationCompleted(
    preview: String?,
    final: FluidAudioProcessResult?,
    error: Error?
  ) {
    operationTask = nil
    guard let activeID else {
      pump()
      return
    }
    guard invocations[activeID] != nil, !retired.contains(activeID) else {
      finishActive()
      return
    }
    if error != nil {
      retired.insert(activeID)
      fail(activeID, kind: .transcription, message: "Local transcription failed. Try loading the model again.")
      finishActive()
      return
    }
    if let preview, !preview.isEmpty {
      events.yield(.preview(id: activeID, text: preview))
    }
    if let final {
      let corrected: LocalCorrectionResult = if let candidate = final.candidateText {
        LocalTranscriptCorrection.guardCandidate(
          rawText: final.rawText,
          candidateText: candidate,
          context: context,
          policy: correctionPolicy
        )
      } else {
        LocalCorrectionResult(
          text: final.rawText,
          outcome: correctionPolicy == .disabled || context.resolvedEntries.isEmpty ? .disabled : .rejected
        )
      }
      let outcome: TranscriptionCorrectionOutcome = switch corrected.outcome {
      case .disabled: .disabled
      case .applied, .unchanged: .applied
      case .rejected: .degraded
      }
      events.yield(.final(
        id: activeID,
        result: TranscriptionFinalResult(text: corrected.text, correction: outcome)
      ))
      finishActive()
      return
    }
    pump()
  }

  private func finishActive() {
    if let activeID {
      invocations.removeValue(forKey: activeID)
      order.removeAll { $0 == activeID }
    }
    activeID = nil
    operationTask = nil
    pump()
  }

  private func retire(_ invocationID: TranscriptionInvocationID) {
    retired.insert(invocationID)
    invocations.removeValue(forKey: invocationID)
    order.removeAll { $0 == invocationID }
    if activeID == invocationID {
      operationTask?.cancel()
    }
  }

  private func fail(
    _ invocationID: TranscriptionInvocationID,
    kind: TranscriptionFailure.Kind,
    message: String
  ) {
    events.yield(.failure(
      epoch: epoch,
      id: invocationID,
      failure: TranscriptionFailure(kind: kind, message: message, isRecoverable: false)
    ))
  }
}
