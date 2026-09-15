import Foundation
import HubrisVoiceCore

// swiftlint:disable file_length

actor FluidAudioTranscriptionState {
  private struct Invocation {
    var nextSequence = 0
    var audioBytes = 0
    var chunks: [Data] = []
    var finishRequested = false
    var context: LocalInvocationContext
    var contextNeedsPreparation = true
  }

  private static let maximumInvocations = 4
  private static let maximumAudioBytes = 90 * 16_000 * MemoryLayout<Int16>.size

  private var context: LocalInvocationContext
  private var correctionPolicy: LocalCorrectionPolicy
  private var allowsEphemeralContext: Bool
  private let processor: any FluidAudioProcessing
  private let acquireModels: @Sendable (
    LocalInvocationContext,
    LocalCorrectionPolicy
  ) async throws -> FluidAudioModelLease
  private let acquireCorrection: @Sendable () async throws -> FluidAudioCorrectionLease?
  private let trace: @Sendable (String) -> Void
  private let events: AsyncStream<TranscriptionEngineEvent>.Continuation
  private var epoch = TranscriptionBackendEpoch(0)
  private var lease: FluidAudioModelLease?
  private var correctionLease: FluidAudioCorrectionLease?
  private var isPrepared = false
  private var isReconfiguring = false
  private var preparationGeneration = 0
  private var nextReconfigurationID = 0
  private var activeReconfigurationID: Int?
  private var preparationTask: Task<Void, Never>?
  private var reconfigurationTask: Task<FluidAudioReconfigurationOutcome, Never>?
  private var operationTask: Task<Void, Never>?
  private var order: [TranscriptionInvocationID] = []
  private var invocations: [TranscriptionInvocationID: Invocation] = [:]
  private var activeID: TranscriptionInvocationID?
  private var retired: Set<TranscriptionInvocationID> = []

  init(
    context: LocalInvocationContext,
    correctionPolicy: LocalCorrectionPolicy,
    allowsEphemeralContext: Bool = false,
    processor: any FluidAudioProcessing,
    acquireModels: @escaping @Sendable (
      LocalInvocationContext,
      LocalCorrectionPolicy
    ) async throws -> FluidAudioModelLease,
    acquireCorrection: @escaping @Sendable () async throws -> FluidAudioCorrectionLease?,
    trace: @escaping @Sendable (String) -> Void = { _ in },
    events: AsyncStream<TranscriptionEngineEvent>.Continuation
  ) {
    self.context = context
    self.correctionPolicy = correctionPolicy
    self.allowsEphemeralContext = allowsEphemeralContext
    self.processor = processor
    self.acquireModels = acquireModels
    self.acquireCorrection = acquireCorrection
    self.trace = trace
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
    let pendingReconfiguration = reconfigurationTask
    let pendingOperation = operationTask
    pendingPreparation?.cancel()
    pendingReconfiguration?.cancel()
    pendingOperation?.cancel()
    preparationTask = nil
    reconfigurationTask = nil
    activeReconfigurationID = nil
    operationTask = nil
    invocations.removeAll()
    order.removeAll()
    activeID = nil
    isPrepared = false
    isReconfiguring = false
    await pendingPreparation?.value
    _ = await pendingReconfiguration?.value
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

  private func prepare(epoch: TranscriptionBackendEpoch) {
    preparationGeneration &+= 1
    let generation = preparationGeneration
    if self.epoch != epoch {
      operationTask?.cancel()
      invocations.removeAll()
      order.removeAll()
      activeID = nil
    }
    self.epoch = epoch
    isPrepared = false
    events.yield(.readiness(epoch: epoch, state: .preparing(message: "Loading local model…")))
    preparationTask?.cancel()
    let pendingReconfiguration = reconfigurationTask
    pendingReconfiguration?.cancel()
    let context = context
    let correctionPolicy = correctionPolicy
    let allowsEphemeralContext = allowsEphemeralContext
    preparationTask = Task { [weak self, acquireModels, acquireCorrection, context, correctionPolicy, processor] in
      do {
        _ = await pendingReconfiguration?.value
        let lease = try await acquireModels(context, correctionPolicy)
        let needsCorrection = correctionPolicy == .strict
          && (!context.resolvedEntries.isEmpty || allowsEphemeralContext)
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
    invocations[invocation.id] = Invocation(context: context)
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

  func updateInvocationContext(
    id invocationID: TranscriptionInvocationID,
    context: LocalInvocationContext
  ) -> Bool {
    guard var invocation = invocations[invocationID], !retired.contains(invocationID),
          !invocation.finishRequested, invocationID.epoch == epoch
    else { return false }
    invocation.context = LocalInvocationContext(
      permanentEntries: invocation.context.permanentEntries,
      ephemeralEntries: context.ephemeralEntries
    )
    invocation.contextNeedsPreparation = true
    invocations[invocationID] = invocation
    pump()
    return true
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
      guard let activeID, var invocation = invocations[activeID] else { return }
      invocation.contextNeedsPreparation = false
      invocations[activeID] = invocation
      let correctionPolicy = correctionPolicy
      operationTask = Task { [weak self, processor] in
        do {
          try await processor.updateCorrection(
            context: invocation.context,
            correctionPolicy: correctionPolicy
          )
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
    if invocation.contextNeedsPreparation {
      invocation.contextNeedsPreparation = false
      invocations[activeID] = invocation
      let correctionPolicy = correctionPolicy
      operationTask = Task { [weak self, processor] in
        do {
          try await processor.updateCorrection(
            context: invocation.context,
            correctionPolicy: correctionPolicy
          )
          await self?.operationCompleted(preview: nil, final: nil, error: nil)
        } catch {
          await self?.operationCompleted(preview: nil, final: nil, error: error)
        }
      }
    } else if !invocation.chunks.isEmpty {
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
      guard let invocation = invocations[activeID] else {
        finishActive()
        return
      }
      let invocationContext = invocation.context
      let corrected: LocalCorrectionResult = if let candidate = final.candidateText {
        LocalTranscriptCorrection.guardCandidate(
          rawText: final.rawText,
          candidateText: candidate,
          context: invocationContext,
          policy: correctionPolicy
        )
      } else {
        LocalCorrectionResult(
          text: final.rawText,
          outcome: correctionPolicy == .disabled || invocationContext.resolvedEntries.isEmpty ? .disabled : .rejected
        )
      }
      let outcome: TranscriptionCorrectionOutcome = switch corrected.outcome {
      case .disabled: .disabled
      case .applied, .unchanged: .applied
      case .rejected: .degraded
      }
      let decisions = corrected.decisions.map { decision in
        "raw=\(String(reflecting: decision.rawText)) "
          + "candidate=\(String(reflecting: decision.candidateText)) "
          + "accepted=\(decision.accepted) reason=\(decision.reason)"
      }
      trace(
        "local correction generation=\(activeID.generation) "
          + "raw=\(String(reflecting: final.rawText)) "
          + "candidate=\(String(reflecting: final.candidateText)) "
          + "outcome=\(corrected.outcome) "
          + "decisions=\(String(reflecting: decisions)) "
          + "final=\(String(reflecting: corrected.text))"
      )
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

extension FluidAudioTranscriptionState {
  func updateConfiguration(
    context: LocalInvocationContext,
    correctionPolicy: LocalCorrectionPolicy,
    allowsEphemeralContext: Bool = false
  ) async throws -> Bool {
    guard
      !isReconfiguring,
      preparationTask == nil,
      reconfigurationTask == nil,
      operationTask == nil,
      activeID == nil,
      order.isEmpty
    else {
      return false
    }
    let previousConfiguration = FluidAudioConfigurationSnapshot(
      context: self.context,
      correctionPolicy: self.correctionPolicy,
      allowsEphemeralContext: self.allowsEphemeralContext
    )
    self.context = context
    self.correctionPolicy = correctionPolicy
    self.allowsEphemeralContext = allowsEphemeralContext
    guard let lease, isPrepared else { return true }

    let generation = preparationGeneration
    nextReconfigurationID &+= 1
    let reconfigurationID = nextReconfigurationID
    activeReconfigurationID = reconfigurationID
    isReconfiguring = true
    isPrepared = false
    let needsCorrection = correctionPolicy == .strict
      && (!context.resolvedEntries.isEmpty || allowsEphemeralContext)
    let existingCorrectionLease = correctionLease
    let task = Task { [acquireCorrection, processor] in
      await prepareFluidAudioReconfiguration(
        request: FluidAudioReconfigurationRequest(
          primaryDirectory: lease.primaryDirectory,
          existingCorrectionLease: existingCorrectionLease,
          needsCorrection: needsCorrection,
          context: context,
          correctionPolicy: correctionPolicy
        ),
        acquireCorrection: acquireCorrection,
        processor: processor
      )
    }
    reconfigurationTask = task
    switch await task.value {
    case .prepared(let acquiredCorrectionLease):
      return await completeReconfiguration(
        acquiredCorrectionLease: acquiredCorrectionLease,
        needsCorrection: needsCorrection,
        generation: generation,
        reconfigurationID: reconfigurationID
      )
    case .failed(let acquiredCorrectionLease):
      return try await failReconfiguration(
        acquiredCorrectionLease: acquiredCorrectionLease,
        previousConfiguration: previousConfiguration,
        generation: generation,
        reconfigurationID: reconfigurationID
      )
    }
  }

  private func completeReconfiguration(
    acquiredCorrectionLease: FluidAudioCorrectionLease?,
    needsCorrection: Bool,
    generation: Int,
    reconfigurationID: Int
  ) async -> Bool {
    guard preparationGeneration == generation else {
      await acquiredCorrectionLease?.release()
      retireReconfiguration(reconfigurationID)
      return false
    }
    let correctionLeaseToRelease = !needsCorrection ? correctionLease : nil
    if correctionLeaseToRelease != nil {
      correctionLease = nil
    }
    await correctionLeaseToRelease?.release()
    guard preparationGeneration == generation else {
      retireReconfiguration(reconfigurationID)
      return false
    }
    if let acquiredCorrectionLease {
      correctionLease = acquiredCorrectionLease
    }
    isPrepared = true
    retireReconfiguration(reconfigurationID)
    pump()
    return true
  }

  private func failReconfiguration(
    acquiredCorrectionLease: FluidAudioCorrectionLease?,
    previousConfiguration: FluidAudioConfigurationSnapshot,
    generation: Int,
    reconfigurationID: Int
  ) async throws -> Bool {
    guard preparationGeneration == generation else {
      await acquiredCorrectionLease?.release()
      retireReconfiguration(reconfigurationID)
      return false
    }
    await acquiredCorrectionLease?.release()
    guard preparationGeneration == generation else {
      retireReconfiguration(reconfigurationID)
      return false
    }
    context = previousConfiguration.context
    correctionPolicy = previousConfiguration.correctionPolicy
    allowsEphemeralContext = previousConfiguration.allowsEphemeralContext
    isPrepared = true
    retireReconfiguration(reconfigurationID)
    throw TranscriptionFailure(
      kind: .configuration,
      message: "The local correction configuration could not be applied.",
      isRecoverable: false
    )
  }

  private func retireReconfiguration(_ reconfigurationID: Int) {
    guard activeReconfigurationID == reconfigurationID else { return }
    activeReconfigurationID = nil
    reconfigurationTask = nil
    isReconfiguring = false
  }
}
