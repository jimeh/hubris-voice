import Foundation
import HubrisVoiceCore

// `id` consistently means a transcription invocation identity in this boundary.
// swiftlint:disable identifier_name

protocol TranscriptionEngineRuntime: AnyObject, Sendable {
  var events: AsyncStream<TranscriptionEngineEvent> { get }

  /// Returns false after shutdown or when the pending PCM append budget is exhausted.
  /// A live runtime always accepts lifecycle commands so rejected audio can be cancelled.
  func submit(_ command: TranscriptionEngineCommand) -> Bool
}

/// Preserves one FIFO while bounding only queued PCM appends. Lifecycle commands remain
/// guaranteed while live; the reducer emits a bounded number of them per invocation.
final class TranscriptionEngineCommandPipe: @unchecked Sendable {
  let stream: AsyncStream<TranscriptionEngineCommand>
  private let continuation: AsyncStream<TranscriptionEngineCommand>.Continuation
  private let maximumPendingAudioCommands: Int
  private let lock = NSLock()
  private var pendingAudioCommands = 0
  private var acceptingCommands = true

  init(capacity: Int = 512) {
    precondition(capacity > 0)
    let pair = AsyncStream.makeStream(of: TranscriptionEngineCommand.self)
    stream = pair.stream
    continuation = pair.continuation
    maximumPendingAudioCommands = capacity
  }

  func submit(_ command: TranscriptionEngineCommand) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard acceptingCommands else { return false }
    let reservesAudioPermit = command.isAudioAppend
    if reservesAudioPermit {
      guard pendingAudioCommands < maximumPendingAudioCommands else { return false }
      pendingAudioCommands += 1
    }
    switch continuation.yield(command) {
    case .enqueued:
      return true
    case .dropped, .terminated:
      if reservesAudioPermit {
        pendingAudioCommands -= 1
      }
      return false
    @unknown default:
      if reservesAudioPermit {
        pendingAudioCommands -= 1
      }
      return false
    }
  }

  func didConsume(_ command: TranscriptionEngineCommand) {
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

  deinit {
    eventTask?.cancel()
  }

  @discardableResult
  func submit(_ command: TranscriptionEngineCommand) -> Bool {
    guard command.epoch == epoch else { return false }
    let accepted = runtime.submit(command)
    if accepted, case .cancel(let id) = command {
      terminalInvocations.insert(id)
      trimTerminalInvocations()
    }
    return accepted
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
        guard let self else { return }
        guard self.epoch == epoch else { return }
        guard event.epoch == epoch else { continue }
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
  var isAudioAppend: Bool {
    if case .append = self {
      true
    } else {
      false
    }
  }

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
