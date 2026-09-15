import Foundation
import HubrisVoiceCore

final class FluidAudioTranscriptionBackend: TranscriptionEngineRuntime, @unchecked Sendable {
  let events: AsyncStream<TranscriptionEngineEvent>

  private let commands = FluidAudioCommandPipe()
  private let state: FluidAudioTranscriptionState
  private var commandTask: Task<Void, Never>?

  convenience init(
    store: LocalModelStore,
    context: LocalInvocationContext,
    correctionPolicy: LocalCorrectionPolicy,
    allowsEphemeralContext: Bool = false
  ) {
    self.init(
      context: context,
      correctionPolicy: correctionPolicy,
      allowsEphemeralContext: allowsEphemeralContext,
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
    allowsEphemeralContext: Bool = false,
    processor: any FluidAudioProcessing,
    acquireModels: @escaping @Sendable (
      LocalInvocationContext,
      LocalCorrectionPolicy
    ) async throws -> FluidAudioModelLease,
    acquireCorrection: @escaping @Sendable () async throws -> FluidAudioCorrectionLease? = { nil },
    trace: @escaping @Sendable (String) -> Void = { message in
      Task { @MainActor in
        DevelopmentTrace.shared.record(message)
      }
    }
  ) {
    let pair = AsyncStream.makeStream(of: TranscriptionEngineEvent.self)
    events = pair.stream
    state = FluidAudioTranscriptionState(
      context: context,
      correctionPolicy: correctionPolicy,
      allowsEphemeralContext: allowsEphemeralContext,
      processor: processor,
      acquireModels: acquireModels,
      acquireCorrection: acquireCorrection,
      trace: trace,
      events: pair.continuation
    )
    let stream = commands.stream
    commandTask = Task { [state, commands] in
      for await command in stream {
        commands.didConsume(command)
        guard !Task.isCancelled else { return }
        switch command {
        case .engine(let command):
          await state.handle(command)
        case .invocationContext(let invocationID, let context, let continuation):
          let accepted = await state.updateInvocationContext(id: invocationID, context: context)
          continuation?.resume(returning: accepted)
        }
      }
    }
  }

  deinit {
    commands.finish()
  }

  func submit(_ command: TranscriptionEngineCommand) -> Bool {
    commands.submit(.engine(command))
  }

  /// Replaces only the ephemeral terms for an invocation that has begun but has not been finished.
  func updateInvocationContext(
    id invocationID: TranscriptionInvocationID,
    context: LocalInvocationContext
  ) async -> Bool {
    await withCheckedContinuation { continuation in
      guard commands.submit(.invocationContext(
        invocationID: invocationID,
        context: context,
        continuation: continuation
      )) else {
        continuation.resume(returning: false)
        return
      }
    }
  }

  /// Enqueues a context change on the same FIFO as audio and lifecycle commands.
  /// This lets release-time invalidation remain ordered immediately before `finish`.
  func submitInvocationContextUpdate(
    id invocationID: TranscriptionInvocationID,
    context: LocalInvocationContext
  ) -> Bool {
    commands.submit(.invocationContext(
      invocationID: invocationID,
      context: context,
      continuation: nil
    ))
  }

  func unload() async {
    await state.unload()
  }

  func updateConfiguration(
    context: LocalInvocationContext,
    correctionPolicy: LocalCorrectionPolicy,
    allowsEphemeralContext: Bool = false
  ) async throws -> Bool {
    try await state.updateConfiguration(
      context: context,
      correctionPolicy: correctionPolicy,
      allowsEphemeralContext: allowsEphemeralContext
    )
  }
}

private enum FluidAudioCommand: @unchecked Sendable {
  case engine(TranscriptionEngineCommand)
  case invocationContext(
    invocationID: TranscriptionInvocationID,
    context: LocalInvocationContext,
    continuation: CheckedContinuation<Bool, Never>?
  )

  var isAudioAppend: Bool {
    if case .engine(.append) = self {
      true
    } else {
      false
    }
  }
}

/// Keeps lifecycle and invocation-context changes on one FIFO while bounding only PCM appends.
private final class FluidAudioCommandPipe: @unchecked Sendable {
  let stream: AsyncStream<FluidAudioCommand>
  private let continuation: AsyncStream<FluidAudioCommand>.Continuation
  private let maximumPendingAudioCommands: Int
  private let lock = NSLock()
  private var pendingAudioCommands = 0
  private var acceptingCommands = true

  init(capacity: Int = 512) {
    precondition(capacity > 0)
    let pair = AsyncStream.makeStream(of: FluidAudioCommand.self)
    stream = pair.stream
    continuation = pair.continuation
    maximumPendingAudioCommands = capacity
  }

  func submit(_ command: FluidAudioCommand) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard acceptingCommands else { return false }
    if command.isAudioAppend {
      guard pendingAudioCommands < maximumPendingAudioCommands else { return false }
      pendingAudioCommands += 1
    }
    switch continuation.yield(command) {
    case .enqueued:
      return true
    case .dropped, .terminated:
      if command.isAudioAppend {
        pendingAudioCommands -= 1
      }
      return false
    @unknown default:
      if command.isAudioAppend {
        pendingAudioCommands -= 1
      }
      return false
    }
  }

  func didConsume(_ command: FluidAudioCommand) {
    guard command.isAudioAppend else { return }
    lock.lock()
    pendingAudioCommands -= 1
    lock.unlock()
  }

  func finish() {
    lock.lock()
    acceptingCommands = false
    lock.unlock()
    continuation.finish()
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
