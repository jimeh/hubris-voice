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
