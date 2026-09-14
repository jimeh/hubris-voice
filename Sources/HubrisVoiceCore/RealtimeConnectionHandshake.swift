import Foundation

public enum RealtimeConnectionFailure:
  Error, Equatable, LocalizedError, Sendable
{
  case timedOut
  case rejected(statusCode: Int, requestID: String?)
  case closed(code: Int, reason: String?)
  case transport(message: String)

  public var errorDescription: String? {
    switch self {
    case .timedOut:
      return "OpenAI Realtime connection timed out before the WebSocket opened."
    case .rejected(let statusCode, let requestID):
      let request = requestID.map { ", request \($0)" } ?? ""
      return "OpenAI rejected the Realtime WebSocket handshake "
        + "(HTTP \(statusCode)\(request))."
    case .closed(let code, let reason):
      let detail = reason.map { ": \($0)" } ?? ""
      return "OpenAI closed the Realtime WebSocket before it opened "
        + "(code \(code)\(detail))."
    case .transport(let message):
      return "OpenAI Realtime connection failed before the WebSocket opened: "
        + message
    }
  }
}

public actor RealtimeConnectionHandshake {
  private enum State {
    case waiting
    case open
    case failed(RealtimeConnectionFailure)
  }

  private var state = State.waiting
  private var waiter: CheckedContinuation<Void, any Error>?
  private var timeoutTask: Task<Void, Never>?

  public init() {}

  var isWaitingForOpen: Bool {
    waiter != nil
  }

  public func waitForOpen(timeout: Duration) async throws {
    switch state {
    case .open:
      return
    case .failed(let failure):
      throw failure
    case .waiting:
      break
    }

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiter = continuation
        timeoutTask = Task { [weak self] in
          do {
            try await Task.sleep(for: timeout)
          } catch {
            return
          }
          await self?.fail(.timedOut)
        }
      }
    } onCancel: {
      Task {
        await self.cancelWait()
      }
    }
  }

  public func open() {
    guard case .waiting = state else {
      return
    }
    state = .open
    finishWaiter(with: .success(()))
  }

  public func fail(_ failure: RealtimeConnectionFailure) {
    guard case .waiting = state else {
      return
    }
    state = .failed(failure)
    finishWaiter(with: .failure(failure))
  }

  private func cancelWait() {
    guard case .waiting = state else {
      return
    }
    finishWaiter(with: .failure(CancellationError()))
  }

  private func finishWaiter(with result: Result<Void, any Error>) {
    timeoutTask?.cancel()
    timeoutTask = nil

    guard let waiter else {
      return
    }
    self.waiter = nil
    waiter.resume(with: result)
  }
}
