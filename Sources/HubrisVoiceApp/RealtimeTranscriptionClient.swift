import Foundation
import HubrisVoiceCore

private enum RealtimeOutboundAction: Sendable {
  case append(Data)
  case commit(String)
  case clear
}

private final class RealtimeWebSocketDelegate:
  NSObject, URLSessionWebSocketDelegate, @unchecked Sendable
{
  private let attemptID: String
  private let handshake: RealtimeConnectionHandshake

  init(
    attemptID: String,
    handshake: RealtimeConnectionHandshake
  ) {
    self.attemptID = attemptID
    self.handshake = handshake
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    let protocolName = `protocol` ?? "none"
    let response = Self.responseSummary(webSocketTask.response)
    let state = Self.stateName(webSocketTask.state)
    Task {
      await DiagnosticLog.shared.record(
        "attempt=\(attemptID) delegate didOpen "
          + "protocol=\(protocolName) state=\(state) response=\(response)"
      )
      await handshake.open()
    }
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    let reasonText = reason.flatMap {
      String(data: $0, encoding: .utf8)
    }
    let reasonSummary = reasonText ?? "none"
    let state = Self.stateName(webSocketTask.state)
    Task {
      await DiagnosticLog.shared.record(
        "attempt=\(attemptID) delegate didClose "
          + "code=\(closeCode.rawValue) reason=\(reasonSummary) state=\(state)",
        level: .error
      )
      await handshake.fail(
        .closed(code: Int(closeCode.rawValue), reason: reasonText)
      )
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    let response = task.response as? HTTPURLResponse
    let failure: RealtimeConnectionFailure
    let errorSummary =
      error.map {
        RealtimeDiagnosticFormatter.errorSummary($0)
      } ?? "none"
    let responseSummary = Self.responseSummary(response)
    let state = Self.stateName(task.state)

    if let response, response.statusCode != 101 {
      failure = .rejected(
        statusCode: response.statusCode,
        requestID: response.value(forHTTPHeaderField: "x-request-id")
      )
    } else if let error {
      failure = .transport(message: error.localizedDescription)
    } else {
      failure = .transport(
        message: "The connection ended before the handshake completed."
      )
    }

    Task {
      await DiagnosticLog.shared.record(
        "attempt=\(attemptID) delegate didComplete "
          + "state=\(state) response=\(responseSummary) error=\(errorSummary)",
        level: error == nil ? .info : .error
      )
      await handshake.fail(failure)
    }
  }

  private static func responseSummary(_ response: URLResponse?) -> String {
    guard let response = response as? HTTPURLResponse else {
      return "none"
    }
    let requestID =
      response.value(forHTTPHeaderField: "x-request-id") ?? "none"
    return "HTTP-\(response.statusCode)-request-\(requestID)"
  }

  private static func stateName(_ state: URLSessionTask.State) -> String {
    switch state {
    case .running:
      return "running"
    case .suspended:
      return "suspended"
    case .canceling:
      return "canceling"
    case .completed:
      return "completed"
    @unknown default:
      return "unknown-\(state.rawValue)"
    }
  }
}

final class RealtimeOutboundPipe: @unchecked Sendable {
  private let continuation: AsyncStream<RealtimeOutboundAction>.Continuation

  fileprivate init(
    continuation: AsyncStream<RealtimeOutboundAction>.Continuation
  ) {
    self.continuation = continuation
  }

  func appendAudio(_ data: Data) {
    continuation.yield(.append(data))
  }

  @discardableResult
  func commitAudio() -> String {
    let eventID = UUID().uuidString
    continuation.yield(.commit(eventID))
    return eventID
  }

  func clearAudio() {
    continuation.yield(.clear)
  }
}

actor RealtimeTranscriptionClient {
  enum ClientError: Error, LocalizedError {
    case invalidEndpoint
    case notConnected
    case unsupportedMessage

    var errorDescription: String? {
      switch self {
      case .invalidEndpoint:
        "The OpenAI Realtime endpoint URL is invalid."
      case .notConnected:
        "The OpenAI Realtime session is not connected."
      case .unsupportedMessage:
        "The OpenAI Realtime session sent an unsupported message."
      }
    }
  }

  nonisolated let outbound: RealtimeOutboundPipe
  nonisolated let events: AsyncStream<RealtimeServerEvent>

  private let outboundStream: AsyncStream<RealtimeOutboundAction>
  private let eventContinuation: AsyncStream<RealtimeServerEvent>.Continuation
  private var outboundTask: Task<Void, Never>?
  private var receiveTask: Task<Void, Never>?
  private var session: URLSession?
  private var sessionDelegate: RealtimeWebSocketDelegate?
  private var socket: URLSessionWebSocketTask?
  private var isReady = false
  private var pendingActions: [RealtimeOutboundAction] = []

  init() {
    let outboundPair = AsyncStream.makeStream(
      of: RealtimeOutboundAction.self,
      bufferingPolicy: .unbounded
    )
    outbound = RealtimeOutboundPipe(
      continuation: outboundPair.continuation
    )
    outboundStream = outboundPair.stream

    let eventPair = AsyncStream.makeStream(
      of: RealtimeServerEvent.self,
      bufferingPolicy: .bufferingNewest(100)
    )
    events = eventPair.stream
    eventContinuation = eventPair.continuation
  }

  func start() {
    guard outboundTask == nil else {
      return
    }
    outboundTask = Task { [weak self] in
      await self?.consumeOutboundActions()
    }
  }

  func connect(
    apiKey: String,
    configuration: RealtimeSessionConfiguration
  ) async throws {
    start()
    disconnectSocket()
    let attemptID = String(UUID().uuidString.prefix(8))
    await DiagnosticLog.shared.record(
      "attempt=\(attemptID) connect start "
        + "transcriptionModel=\(RealtimeAPI.transcriptionModel) "
        + "endpoint=/v1/realtime intent=transcription"
    )

    guard let endpoint = RealtimeAPI.endpoint else {
      throw ClientError.invalidEndpoint
    }

    var request = URLRequest(url: endpoint)
    request.timeoutInterval = 30
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let handshake = RealtimeConnectionHandshake()
    let sessionDelegate = RealtimeWebSocketDelegate(
      attemptID: attemptID,
      handshake: handshake
    )
    let session = URLSession(
      configuration: .ephemeral,
      delegate: sessionDelegate,
      delegateQueue: nil
    )
    let socket = session.webSocketTask(with: request)
    self.session = session
    self.sessionDelegate = sessionDelegate
    self.socket = socket
    isReady = false
    pendingActions.removeAll(keepingCapacity: true)

    socket.resume()
    await DiagnosticLog.shared.record(
      "attempt=\(attemptID) task resumed state=\(socket.state.rawValue)"
    )
    receiveTask = Task { [weak self, weak socket] in
      guard let socket else {
        return
      }
      await self?.receiveLoop(socket: socket, attemptID: attemptID)
    }

    do {
      await DiagnosticLog.shared.record(
        "attempt=\(attemptID) waiting for didOpen"
      )
      try await handshake.waitForOpen(timeout: .seconds(30))
      await DiagnosticLog.shared.record(
        "attempt=\(attemptID) didOpen observed; "
          + "sending session.update state=\(socket.state.rawValue)"
      )
      let sessionEvent = RealtimeClientEvent.sessionUpdate(configuration)
      try await send(sessionEvent, through: socket)
      await DiagnosticLog.shared.record(
        "attempt=\(attemptID) session.update send completed"
      )
    } catch {
      await DiagnosticLog.shared.record(
        "attempt=\(attemptID) connect failed "
          + RealtimeDiagnosticFormatter.errorSummary(error),
        level: .error
      )
      disconnectSocket()
      throw error
    }
  }

  func disconnect() {
    disconnectSocket()
    pendingActions.removeAll()
  }

  private func disconnectSocket() {
    isReady = false
    receiveTask?.cancel()
    receiveTask = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    session?.invalidateAndCancel()
    session = nil
    sessionDelegate = nil
  }

  private func consumeOutboundActions() async {
    for await action in outboundStream {
      guard !Task.isCancelled else {
        return
      }

      if isReady {
        do {
          try await send(action)
        } catch {
          isReady = false
          pendingActions.append(action)
          eventContinuation.yield(
            .error(message: error.localizedDescription)
          )
        }
      } else {
        pendingActions.append(action)
      }
    }
  }

  private func receiveLoop(
    socket: URLSessionWebSocketTask,
    attemptID: String
  ) async {
    await DiagnosticLog.shared.record(
      "attempt=\(attemptID) receive loop started"
    )
    do {
      while !Task.isCancelled {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .data(let messageData):
          data = messageData
        case .string(let string):
          data = Data(string.utf8)
        @unknown default:
          throw ClientError.unsupportedMessage
        }

        let event = try RealtimeServerEvent.decode(data)
        await DiagnosticLog.shared.record(
          "attempt=\(attemptID) received \(event.diagnosticName)"
        )
        if event == .sessionReady {
          isReady = true
          try await flushPendingActions()
        }
        eventContinuation.yield(event)
      }
    } catch is CancellationError {
      await DiagnosticLog.shared.record(
        "attempt=\(attemptID) receive loop cancelled"
      )
      return
    } catch {
      isReady = false
      await DiagnosticLog.shared.record(
        "attempt=\(attemptID) receive loop failed "
          + RealtimeDiagnosticFormatter.errorSummary(error),
        level: .error
      )
      eventContinuation.yield(
        .error(message: error.localizedDescription)
      )
    }
  }

  private func flushPendingActions() async throws {
    let queued = pendingActions
    pendingActions.removeAll(keepingCapacity: true)
    for action in queued {
      try await send(action)
    }
  }

  private func send(_ action: RealtimeOutboundAction) async throws {
    guard let socket else {
      throw ClientError.notConnected
    }

    switch action {
    case .append(let data):
      try await send(.appendAudio(data), through: socket)
    case .commit(let eventID):
      try await send(.commitAudio(eventID: eventID), through: socket)
    case .clear:
      try await send(.clearAudio, through: socket)
    }
  }

  private func send(
    _ event: RealtimeClientEvent,
    through socket: URLSessionWebSocketTask
  ) async throws {
    let data = try event.encoded()
    guard let json = String(data: data, encoding: .utf8) else {
      throw ClientError.unsupportedMessage
    }
    try await socket.send(.string(json))
  }
}

private extension RealtimeServerEvent {
  var diagnosticName: String {
    switch self {
    case .sessionReady:
      "session.updated"
    case .inputCommitted:
      "input_audio_buffer.committed"
    case .transcriptDelta:
      "transcript.delta"
    case .transcriptCompleted:
      "transcript.completed"
    case .error(let message):
      "server.error message=\(message)"
    case .ignored(let type):
      "ignored.\(type)"
    }
  }
}
