import Foundation

// The transition table is intentionally kept together for direct review against the design contract.
// swiftlint:disable file_length

public struct OverlayPresentation: Equatable, Sendable {
  public enum Mode: Equatable, Sendable {
    case listening
    case finalizing
    case attention
  }

  public let mode: Mode
  public let transcript: String
  /// Empty while everything is normal. Non-empty only for connection status
  /// while listening and for the reason in attention. Never a key hint; the
  /// app appends the recovery hint because it owns the shortcut settings.
  public let message: String
  public let pendingCount: Int
  public let isLocked: Bool

  public init(
    mode: Mode,
    transcript: String,
    message: String,
    pendingCount: Int,
    isLocked: Bool = false
  ) {
    self.mode = mode
    self.transcript = transcript
    self.message = message
    self.pendingCount = pendingCount
    self.isLocked = isLocked
  }
}

public struct DictationSession: Equatable, Sendable {
  public struct Snippet: Equatable, Sendable {
    public let generation: Int
    public var itemID: String?
    public var transcript: String

    public init(generation: Int, itemID: String? = nil, transcript: String = "") {
      self.generation = generation
      self.itemID = itemID
      self.transcript = transcript
    }
  }

  public enum ConnectionState: Equatable, Sendable {
    case unconfigured
    case disconnected(attempt: Int)
    case connecting(attempt: Int)
    case ready
  }

  public enum PresentedResult: Equatable, Sendable {
    case rejected(text: String, reason: RejectionReason)
    case timedOut(text: String)
    case error(message: String, text: String)
  }

  public enum RejectionReason: Equatable, Sendable {
    case noTarget
    case secureField
  }

  public enum Event: Equatable, Sendable {
    case pressed
    case released(heldDuration: TimeInterval)
    case cancelRequested
    case dismissRequested
    case pasteLastRequested(text: String)
    case connectRequested(force: Bool)
    case credentialsChanged(hasKey: Bool)
    case localError(message: String)
    case bufferFull(generation: Int)
    case sessionReady
    case connectionFailed(message: String)
    case connectionLost(message: String)
    case server(RealtimeServerEvent)
    case reconnectDelayElapsed(attempt: Int)
    case finalizingTimedOut(generation: Int)
    case dismissDelayElapsed
    case insertionFinished(
      generation: Int,
      outcome: PasteOutcome,
      reason: RejectionReason?
    )
  }

  public enum Effect: Equatable, Sendable {
    case startCapture(generation: Int)
    case stopCapture
    case replayAudio(generation: Int)
    case commitAudio(generation: Int)
    case clearAudio(generation: Int)
    case connect(attempt: Int)
    case disconnect
    case scheduleReconnect(after: Duration, attempt: Int)
    case cancelReconnect
    case scheduleFinalizingTimeout(generation: Int, after: Duration)
    case cancelFinalizingTimeout(generation: Int)
    case recordTranscript(generation: Int, text: String)
    case insert(generation: Int, text: String)
    case insertAtCurrentFocus(generation: Int, text: String)
    case scheduleDismiss(after: Duration)
    case cancelDismiss
    case discardSnippet(generation: Int)
  }

  public struct Configuration: Equatable, Sendable {
    public var minimumHoldDuration: TimeInterval
    public var finalizingTimeout: Duration
    public var attentionLinger: Duration
    public var maximumPendingSnippets: Int
    public var reconnect: ReconnectPolicy
    public var tapToLock: Bool

    public init(
      minimumHoldDuration: TimeInterval = 0.2,
      finalizingTimeout: Duration = .seconds(8),
      attentionLinger: Duration = .seconds(4),
      maximumPendingSnippets: Int = 4,
      reconnect: ReconnectPolicy = .init(),
      tapToLock: Bool = false
    ) {
      self.minimumHoldDuration = minimumHoldDuration
      self.finalizingTimeout = finalizingTimeout
      self.attentionLinger = attentionLinger
      self.maximumPendingSnippets = maximumPendingSnippets
      self.reconnect = reconnect
      self.tapToLock = tapToLock
    }
  }

  public private(set) var connection: ConnectionState
  public private(set) var listening: Snippet?
  public private(set) var pending: [Snippet] = []
  public private(set) var inserting: [Snippet] = []
  public private(set) var presented: PresentedResult?
  public private(set) var nextGeneration = 0
  public private(set) var isLocked = false

  private var configuration: Configuration
  public init(configuration: Configuration = .init(), hasKey: Bool) {
    self.configuration = configuration
    connection = hasKey ? .disconnected(attempt: 0) : .unconfigured
  }

  public mutating func setTapToLock(_ enabled: Bool) {
    configuration.tapToLock = enabled
  }

  // swiftlint:disable:next cyclomatic_complexity
  public mutating func transition(_ event: Event) -> [Effect] {
    switch event {
    case .credentialsChanged(let hasKey):
      return credentialsChanged(hasKey: hasKey)
    case .connectRequested(let force):
      return connectRequested(force: force)
    case .connectionFailed(let message):
      return connectionFailed(message: message)
    case .connectionLost(let message):
      return connectionLost(message: message)
    case .reconnectDelayElapsed(let attempt):
      return reconnectDelayElapsed(attempt: attempt)
    case .sessionReady:
      return sessionBecameReady()
    case .pressed:
      return pressed()
    case .released(let heldDuration):
      return released(heldDuration: heldDuration)
    case .bufferFull(let generation):
      guard listening?.generation == generation else {
        return []
      }
      return releaseListeningSnippet()
    case .cancelRequested:
      return cancelRequested()
    case .dismissRequested:
      return dismissRequested()
    case .pasteLastRequested(let text):
      return pasteLastRequested(text: text)
    case .localError(let message):
      return localError(message: message)
    case .server(let serverEvent):
      return handle(serverEvent)
    case .finalizingTimedOut(let generation):
      return finalizingTimedOut(generation: generation)
    case .dismissDelayElapsed:
      guard presented != nil else {
        return []
      }
      presented = nil
      return []
    case .insertionFinished(let generation, let outcome, let reason):
      return insertionFinished(generation: generation, outcome: outcome, reason: reason)
    }
  }

  public var presentation: OverlayPresentation? {
    if let listening {
      let message = switch connection {
      case .ready: ""
      case .connecting: "Connecting…"
      case .disconnected: "Reconnecting…"
      case .unconfigured: "Add an OpenAI API key before dictating."
      }
      return OverlayPresentation(
        mode: .listening,
        transcript: listening.transcript,
        message: message,
        pendingCount: pending.count,
        isLocked: isLocked
      )
    }
    if let presented {
      let values = presentationValues(for: presented)
      return OverlayPresentation(
        mode: values.mode,
        transcript: values.text,
        message: values.message,
        pendingCount: pending.count
      )
    }
    if !pending.isEmpty || !inserting.isEmpty {
      let transcript = pending.last?.transcript ?? inserting.last?.transcript ?? ""
      let pendingCount = max(0, pending.count + inserting.count - 1)
      return OverlayPresentation(
        mode: .finalizing,
        transcript: transcript,
        message: "",
        pendingCount: pendingCount
      )
    }
    return nil
  }

  public var phaseTitle: String {
    if listening != nil {
      return "Listening"
    }
    if let presented {
      switch presented {
      case .rejected, .timedOut: return "Transcript ready"
      case .error: return "Needs attention"
      }
    }
    if !pending.isEmpty || !inserting.isEmpty {
      return "Finalizing"
    }
    switch connection {
    case .unconfigured: return "Add an API key"
    case .connecting: return "Connecting"
    case .disconnected: return "Reconnecting"
    case .ready: return "Ready"
    }
  }
}

private extension DictationSession {
  mutating func credentialsChanged(hasKey: Bool) -> [Effect] {
    guard hasKey else {
      connection = .unconfigured
      clearPendingItemIDs()
      return [.disconnect, .cancelReconnect]
    }
    guard connection == .unconfigured else { return [] }
    connection = .connecting(attempt: 0)
    return [.connect(attempt: 0)]
  }

  mutating func connectRequested(force: Bool) -> [Effect] {
    if force {
      guard connection != .unconfigured else { return [] }
      connection = .connecting(attempt: 0)
      clearPendingItemIDs()
      return [.disconnect, .cancelReconnect, .connect(attempt: 0)]
    }
    guard case .disconnected = connection else { return [] }
    connection = .connecting(attempt: 0)
    return [.cancelReconnect, .connect(attempt: 0)]
  }

  mutating func connectionFailed(message _: String) -> [Effect] {
    guard case .connecting(let attempt) = connection else { return [] }
    let nextAttempt = attempt + 1
    connection = .disconnected(attempt: nextAttempt)
    return [
      .scheduleReconnect(
        after: configuration.reconnect.delay(forAttempt: nextAttempt),
        attempt: nextAttempt
      ),
    ]
  }

  mutating func connectionLost(message _: String) -> [Effect] {
    switch connection {
    case .ready:
      connection = .disconnected(attempt: 1)
      clearPendingItemIDs()
      return [
        .scheduleReconnect(
          after: configuration.reconnect.delay(forAttempt: 1),
          attempt: 1
        ),
      ]
    case .connecting:
      return connectionFailed(message: "")
    case .unconfigured, .disconnected:
      return []
    }
  }

  mutating func reconnectDelayElapsed(attempt: Int) -> [Effect] {
    guard connection == .disconnected(attempt: attempt) else { return [] }
    connection = .connecting(attempt: attempt)
    return [.connect(attempt: attempt)]
  }

  mutating func sessionBecameReady() -> [Effect] {
    guard case .connecting = connection else { return [] }
    connection = .ready
    clearPendingItemIDs()
    var effects = pending.flatMap { snippet in
      [Effect.replayAudio(generation: snippet.generation), .commitAudio(generation: snippet.generation)]
    }
    if let listening {
      effects.append(.replayAudio(generation: listening.generation))
    }
    return effects
  }

  mutating func pressed() -> [Effect] {
    if listening != nil, isLocked {
      return releaseListeningSnippet()
    }
    guard connection != .unconfigured else {
      setPresented(.error(message: "Add an OpenAI API key before dictating.", text: ""))
      return [.scheduleDismiss(after: configuration.attentionLinger)]
    }
    guard listening == nil else { return [] }
    guard pending.count + inserting.count < configuration.maximumPendingSnippets else {
      setPresented(.error(message: "Waiting for previous transcripts.", text: ""))
      return [.scheduleDismiss(after: configuration.attentionLinger)]
    }

    let generation = nextGeneration
    nextGeneration += 1
    listening = Snippet(generation: generation)
    presented = nil
    var effects: [Effect] = [.cancelDismiss]
    if case .disconnected = connection {
      connection = .connecting(attempt: 0)
      effects += [.cancelReconnect, .connect(attempt: 0)]
    }
    effects.append(.startCapture(generation: generation))
    return effects
  }

  mutating func released(heldDuration: TimeInterval) -> [Effect] {
    guard let listening else { return [] }
    guard heldDuration >= configuration.minimumHoldDuration else {
      if configuration.tapToLock {
        isLocked = true
        return []
      }
      self.listening = nil
      isLocked = false
      return [
        .stopCapture,
        .clearAudio(generation: listening.generation),
        .discardSnippet(generation: listening.generation),
      ]
    }
    return releaseListeningSnippet()
  }

  mutating func releaseListeningSnippet() -> [Effect] {
    guard let listening else { return [] }
    self.listening = nil
    isLocked = false
    pending.append(listening)
    var effects: [Effect] = [.stopCapture]
    if connection == .ready {
      effects.append(.commitAudio(generation: listening.generation))
    }
    effects.append(
      .scheduleFinalizingTimeout(
        generation: listening.generation,
        after: configuration.finalizingTimeout
      )
    )
    return effects
  }

  mutating func cancelRequested() -> [Effect] {
    if let listening {
      self.listening = nil
      isLocked = false
      return [
        .stopCapture,
        .clearAudio(generation: listening.generation),
        .discardSnippet(generation: listening.generation),
      ]
    }
    if presented != nil {
      return dismissRequested()
    }
    guard !pending.isEmpty else { return [] }
    let snippets = pending
    pending = []
    return snippets.flatMap { snippet in
      [
        .cancelFinalizingTimeout(generation: snippet.generation),
        .discardSnippet(generation: snippet.generation),
      ]
    }
  }

  mutating func dismissRequested() -> [Effect] {
    guard presented != nil else { return [] }
    presented = nil
    return [.cancelDismiss]
  }

  mutating func pasteLastRequested(text: String) -> [Effect] {
    guard listening == nil, !text.isEmpty else { return [] }
    return beginCurrentFocusInsertion(text: text)
  }

  mutating func localError(message: String) -> [Effect] {
    guard let listening else {
      setPresented(.error(message: message, text: ""))
      return [.scheduleDismiss(after: configuration.attentionLinger)]
    }
    self.listening = nil
    isLocked = false
    setPresented(.error(message: message, text: listening.transcript))
    return [
      .stopCapture,
      .clearAudio(generation: listening.generation),
      .discardSnippet(generation: listening.generation),
      .scheduleDismiss(after: configuration.attentionLinger),
    ]
  }

  mutating func handle(_ event: RealtimeServerEvent) -> [Effect] {
    switch event {
    case .sessionReady:
      return sessionBecameReady()
    case .inputCommitted(let itemID):
      guard !pending.contains(where: { $0.itemID == itemID }) else { return [] }
      guard let index = pending.firstIndex(where: { $0.itemID == nil }) else { return [] }
      pending[index].itemID = itemID
      return []
    case .transcriptDelta(let itemID, let delta):
      if let index = pending.firstIndex(where: { $0.itemID == itemID }) {
        pending[index].transcript += delta
        return []
      }
      // The server streams deltas for the uncommitted buffer while recording,
      // so the first live delta names the item the listening snippet will commit.
      guard listening != nil, listening?.itemID == nil || listening?.itemID == itemID else { return [] }
      listening?.itemID = itemID
      listening?.transcript += delta
      return []
    case .transcriptCompleted(let itemID, let transcript):
      return transcriptCompleted(itemID: itemID, transcript: transcript)
    case .error(let message):
      return serverError(message: message)
    case .ignored:
      return []
    }
  }

  mutating func transcriptCompleted(itemID: String, transcript: String) -> [Effect] {
    guard let index = pending.firstIndex(where: { $0.itemID == itemID }) else { return [] }
    var snippet = pending.remove(at: index)
    let text = transcript.trimmingWhitespace
    guard !text.isEmpty else {
      setPresented(.error(message: "No speech was detected.", text: ""))
      return [
        .cancelFinalizingTimeout(generation: snippet.generation),
        .clearAudio(generation: snippet.generation),
        .discardSnippet(generation: snippet.generation),
        .scheduleDismiss(after: configuration.attentionLinger),
      ]
    }
    snippet.transcript = text
    inserting.append(snippet)
    return [
      .cancelFinalizingTimeout(generation: snippet.generation),
      .clearAudio(generation: snippet.generation),
      .recordTranscript(generation: snippet.generation, text: text),
      .insert(generation: snippet.generation, text: text),
    ]
  }

  mutating func serverError(message: String) -> [Effect] {
    let text = listening?.transcript ?? pending.last?.transcript ?? inserting.last?.transcript ?? ""
    setPresented(.error(message: message, text: text))
    var effects: [Effect] = []
    if let listening {
      self.listening = nil
      isLocked = false
      effects += [
        .stopCapture,
        .clearAudio(generation: listening.generation),
        .discardSnippet(generation: listening.generation),
      ]
    }
    effects.append(.scheduleDismiss(after: configuration.attentionLinger))
    return effects
  }

  mutating func finalizingTimedOut(generation: Int) -> [Effect] {
    guard let index = pending.firstIndex(where: { $0.generation == generation }) else { return [] }
    let snippet = pending.remove(at: index)
    setPresented(.timedOut(text: snippet.transcript))
    return [
      .clearAudio(generation: generation),
      .discardSnippet(generation: generation),
      .scheduleDismiss(after: configuration.attentionLinger),
    ]
  }

  mutating func insertionFinished(
    generation: Int,
    outcome: PasteOutcome,
    reason: RejectionReason?
  ) -> [Effect] {
    guard let index = inserting.firstIndex(where: { $0.generation == generation }) else { return [] }
    let snippet = inserting.remove(at: index)
    switch outcome {
    case .confirmed, .attempted:
      presented = nil
      return [.discardSnippet(generation: generation), .cancelDismiss]
    case .rejected:
      setPresented(.rejected(text: snippet.transcript, reason: reason ?? .noTarget))
      return [
        .discardSnippet(generation: generation),
        .cancelDismiss,
        .scheduleDismiss(after: configuration.attentionLinger),
      ]
    }
  }

  mutating func setPresented(_ result: PresentedResult) {
    presented = result
  }

  mutating func beginCurrentFocusInsertion(text: String) -> [Effect] {
    let generation = nextGeneration
    nextGeneration += 1
    inserting.append(Snippet(generation: generation, transcript: text))
    presented = nil
    return [
      .cancelDismiss,
      .insertAtCurrentFocus(generation: generation, text: text),
    ]
  }

  /// A new socket re-transcribes replayed audio from scratch, so live item IDs
  /// and their partial transcripts are both stale.
  mutating func clearPendingItemIDs() {
    for index in pending.indices {
      pending[index].itemID = nil
      pending[index].transcript = ""
    }
    listening?.itemID = nil
    listening?.transcript = ""
  }

  func presentationValues(for result: PresentedResult) -> PresentationValues {
    switch result {
    case .rejected(let text, let reason):
      let message = switch reason {
      case .noTarget: "No text field is focused"
      case .secureField: "Secure field"
      }
      return PresentationValues(mode: .attention, text: text, message: message)
    case .timedOut(let text):
      return PresentationValues(mode: .attention, text: text, message: "No transcript arrived")
    case .error(let message, let text):
      return PresentationValues(mode: .attention, text: text, message: message)
    }
  }
}

private struct PresentationValues {
  let mode: OverlayPresentation.Mode
  let text: String
  let message: String
}

private extension String {
  var trimmingWhitespace: String {
    let withoutLeading = drop(while: \.isWhitespace)
    return String(withoutLeading.reversed().drop(while: \.isWhitespace).reversed())
  }
}
