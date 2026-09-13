import Foundation
import HubrisVoiceCore

// `id` consistently means a transcription invocation identity in this boundary.
// swiftlint:disable identifier_name

protocol TranscriptionEngineRuntime: AnyObject, Sendable {
  var events: AsyncStream<TranscriptionEngineEvent> { get }

  /// Returns false when the bounded command mailbox cannot accept more work.
  func submit(_ command: TranscriptionEngineCommand) -> Bool
}

final class TranscriptionEngineCommandPipe: @unchecked Sendable {
  let stream: AsyncStream<TranscriptionEngineCommand>
  private let continuation: AsyncStream<TranscriptionEngineCommand>.Continuation

  init(capacity: Int = 512) {
    let pair = AsyncStream.makeStream(
      of: TranscriptionEngineCommand.self,
      bufferingPolicy: .bufferingOldest(capacity)
    )
    stream = pair.stream
    continuation = pair.continuation
  }

  func submit(_ command: TranscriptionEngineCommand) -> Bool {
    switch continuation.yield(command) {
    case .enqueued:
      true
    case .dropped, .terminated:
      false
    @unknown default:
      false
    }
  }

  func finish() {
    continuation.finish()
  }
}

@MainActor
final class TranscriptionEngineCoordinator {
  private(set) var epoch: TranscriptionBackendEpoch
  let events: AsyncStream<TranscriptionEngineEvent>

  private let eventContinuation: AsyncStream<TranscriptionEngineEvent>.Continuation
  private var runtime: any TranscriptionEngineRuntime
  private var eventTask: Task<Void, Never>?
  private var terminalInvocations: Set<TranscriptionInvocationID> = []

  init(runtime: any TranscriptionEngineRuntime, epoch: TranscriptionBackendEpoch) {
    self.runtime = runtime
    self.epoch = epoch
    // Text events are low volume. Keep this lossless so a preview burst cannot
    // evict a terminal result or readiness change.
    let pair = AsyncStream.makeStream(of: TranscriptionEngineEvent.self)
    events = pair.stream
    eventContinuation = pair.continuation
    consume(runtime.events, epoch: epoch)
  }

  @discardableResult
  func submit(_ command: TranscriptionEngineCommand) -> Bool {
    guard command.epoch == epoch else { return false }
    if case .cancel(let id) = command {
      terminalInvocations.insert(id)
      trimTerminalInvocations()
    }
    return runtime.submit(command)
  }

  func replace(
    runtime: any TranscriptionEngineRuntime,
    epoch: TranscriptionBackendEpoch
  ) {
    precondition(epoch > self.epoch)
    eventTask?.cancel()
    self.runtime = runtime
    self.epoch = epoch
    terminalInvocations.removeAll()
    consume(runtime.events, epoch: epoch)
  }

  private func consume(
    _ runtimeEvents: AsyncStream<TranscriptionEngineEvent>,
    epoch: TranscriptionBackendEpoch
  ) {
    eventTask = Task { [weak self] in
      for await event in runtimeEvents {
        guard let self, self.epoch == epoch, event.epoch == epoch else { continue }
        if let id = event.invocationID {
          if terminalInvocations.contains(id) {
            continue
          }
          if event.isTerminal {
            terminalInvocations.insert(id)
            trimTerminalInvocations()
          }
        }
        eventContinuation.yield(event)
      }
    }
  }

  private func trimTerminalInvocations() {
    guard terminalInvocations.count > 256 else { return }
    let ordered = terminalInvocations.sorted { $0.generation < $1.generation }
    terminalInvocations.subtract(ordered.prefix(terminalInvocations.count - 256))
  }
}

private extension TranscriptionEngineCommand {
  var epoch: TranscriptionBackendEpoch {
    switch self {
    case .prepare(let epoch): epoch
    case .begin(let invocation): invocation.id.epoch
    case .append(let id, _, _), .finish(let id), .cancel(let id): id.epoch
    }
  }
}

private extension TranscriptionEngineEvent {
  var epoch: TranscriptionBackendEpoch {
    switch self {
    case .readiness(let epoch, _): epoch
    case .preview(let id, _), .final(let id, _): id.epoch
    case .failure(let epoch, _, _): epoch
    }
  }

  var invocationID: TranscriptionInvocationID? {
    switch self {
    case .preview(let id, _), .final(let id, _): id
    case .failure(_, let id, _): id
    case .readiness: nil
    }
  }

  var isTerminal: Bool {
    switch self {
    case .final, .failure(epoch: _, id: .some, failure: _): true
    case .readiness, .preview, .failure(epoch: _, id: nil, failure: _): false
    }
  }
}

// swiftlint:enable identifier_name
