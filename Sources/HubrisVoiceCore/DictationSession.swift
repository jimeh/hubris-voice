import Foundation

// The transition table is intentionally kept together for direct review against the design contract.
// swiftlint:disable file_length

public struct OverlayPresentation: Equatable, Sendable {
  public enum Mode: Equatable, Sendable {
    case listening
    case finalizing
    case completed
    case copied
    case attention
  }

  public let mode: Mode
  public let transcript: String
  public let message: String
  public let canCopy: Bool
  public let canPasteHere: Bool
  public let canDismiss: Bool
  public let pendingCount: Int

  public init(
    mode: Mode,
    transcript: String,
    message: String,
    canCopy: Bool,
    canPasteHere: Bool,
    canDismiss: Bool,
    pendingCount: Int
  ) {
    self.mode = mode
    self.transcript = transcript
    self.message = message
    self.canCopy = canCopy
    self.canPasteHere = canPasteHere
    self.canDismiss = canDismiss
    self.pendingCount = pendingCount
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
    case confirmed(text: String)
    case attempted(text: String)
    case rejected(text: String, reason: RejectionReason)
    case timedOut(text: String)
    case error(message: String, text: String)
  }

  public enum RejectionReason: Equatable, Sendable {
    case noTarget
    case focusChanged
    case secureField
  }

  public enum Event: Equatable, Sendable {
    case pressed
    case released(heldDuration: TimeInterval)
    case cancelRequested
    case dismissRequested
    case copied
    case pasteHereRequested
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
    case insert(generation: Int, text: String)
    case insertAtCurrentFocus(generation: Int, text: String)
    case scheduleDismiss(after: Duration)
    case cancelDismiss
    case discardSnippet(generation: Int)
  }

  public struct Configuration: Equatable, Sendable {
    public var minimumHoldDuration: TimeInterval
    public var finalizingTimeout: Duration
    public var copiedLinger: Duration
    public var attentionLinger: Duration
    public var maximumPendingSnippets: Int
    public var reconnect: ReconnectPolicy

    public init(
      minimumHoldDuration: TimeInterval = 0.2,
      finalizingTimeout: Duration = .seconds(8),
      copiedLinger: Duration = .milliseconds(850),
      attentionLinger: Duration = .seconds(4),
      maximumPendingSnippets: Int = 4,
      reconnect: ReconnectPolicy = .init()
    ) {
      self.minimumHoldDuration = minimumHoldDuration
      self.finalizingTimeout = finalizingTimeout
      self.copiedLinger = copiedLinger
      self.attentionLinger = attentionLinger
      self.maximumPendingSnippets = maximumPendingSnippets
      self.reconnect = reconnect
    }
  }

  public private(set) var connection: ConnectionState
  public private(set) var listening: Snippet?
  public private(set) var pending: [Snippet] = []
  public private(set) var inserting: [Snippet] = []
  public private(set) var presented: PresentedResult?
  public private(set) var nextGeneration = 0

  private let configuration: Configuration
  private var wasCopied = false

  public init(configuration: Configuration = .init(), hasKey: Bool) {
    self.configuration = configuration
    connection = hasKey ? .disconnected(attempt: 0) : .unconfigured
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
    case .copied:
      return copied()
    case .pasteHereRequested:
      return pasteHereRequested()
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
      wasCopied = false
      return []
    case .insertionFinished(let generation, let outcome, let reason):
      return insertionFinished(generation: generation, outcome: outcome, reason: reason)
    }
  }

  public var presentation: OverlayPresentation? {
    if let listening {
      let message = switch connection {
      case .ready: "Release to insert"
      case .connecting: "Connecting…"
      case .disconnected: "Reconnecting…"
      case .unconfigured: "Add an OpenAI API key before dictating."
      }
      return OverlayPresentation(
        mode: .listening,
        transcript: listening.transcript,
        message: message,
        canCopy: false,
        canPasteHere: false,
        canDismiss: false,
        pendingCount: pending.count
      )
    }
    if let presented {
      let values = presentationValues(for: presented)
      return OverlayPresentation(
        mode: wasCopied ? .copied : values.mode,
        transcript: values.text,
        message: wasCopied ? "Copied to the clipboard" : values.message,
        canCopy: !values.text.isEmpty && !wasCopied,
        canPasteHere: !wasCopied && values.mode == .attention && !values.text.isEmpty,
        canDismiss: true,
        pendingCount: pending.count
      )
    }
    if !pending.isEmpty || !inserting.isEmpty {
      let transcript = pending.last?.transcript ?? inserting.last?.transcript ?? ""
      let pendingCount = max(0, pending.count + inserting.count - 1)
      return OverlayPresentation(
        mode: .finalizing,
        transcript: transcript,
        message: "Completing the transcript…",
        canCopy: false,
        canPasteHere: false,
        canDismiss: false,
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
      case .confirmed: break
      case .attempted: return "Paste attempted"
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
    wasCopied = false
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
      self.listening = nil
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
    wasCopied = false
    return [.cancelDismiss]
  }

  mutating func copied() -> [Effect] {
    guard let presented, !presented.text.isEmpty else { return [] }
    wasCopied = true
    return [
      .cancelDismiss,
      .scheduleDismiss(after: configuration.copiedLinger),
    ]
  }

  mutating func pasteHereRequested() -> [Effect] {
    guard let presented else { return [] }
    let text: String
    switch presented {
    case .attempted(let attemptedText),
         .rejected(let attemptedText, _),
         .timedOut(let attemptedText):
      text = attemptedText
    case .confirmed, .error:
      return []
    }
    guard !text.isEmpty else { return [] }

    let generation = nextGeneration
    nextGeneration += 1
    inserting.append(Snippet(generation: generation, transcript: text))
    self.presented = nil
    wasCopied = false
    return [
      .cancelDismiss,
      .insertAtCurrentFocus(generation: generation, text: text),
    ]
  }

  mutating func localError(message: String) -> [Effect] {
    guard let listening else {
      setPresented(.error(message: message, text: ""))
      return [.scheduleDismiss(after: configuration.attentionLinger)]
    }
    self.listening = nil
    setPresented(.error(message: message, text: listening.transcript))
    var effects: [Effect] = [
      .stopCapture,
      .clearAudio(generation: listening.generation),
      .discardSnippet(generation: listening.generation),
    ]
    if listening.transcript.isEmpty {
      effects.append(.scheduleDismiss(after: configuration.attentionLinger))
    }
    return effects
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
      .insert(generation: snippet.generation, text: text),
    ]
  }

  mutating func serverError(message: String) -> [Effect] {
    let text = listening?.transcript ?? pending.last?.transcript ?? inserting.last?.transcript ?? ""
    setPresented(.error(message: message, text: text))
    var effects: [Effect] = []
    if let listening {
      self.listening = nil
      effects += [
        .stopCapture,
        .clearAudio(generation: listening.generation),
        .discardSnippet(generation: listening.generation),
      ]
    }
    if text.isEmpty {
      effects.append(.scheduleDismiss(after: configuration.attentionLinger))
    }
    return effects
  }

  mutating func finalizingTimedOut(generation: Int) -> [Effect] {
    guard let index = pending.firstIndex(where: { $0.generation == generation }) else { return [] }
    let snippet = pending.remove(at: index)
    setPresented(.timedOut(text: snippet.transcript))
    var effects: [Effect] = [
      .clearAudio(generation: generation),
      .discardSnippet(generation: generation),
    ]
    if snippet.transcript.isEmpty {
      effects.append(.scheduleDismiss(after: configuration.attentionLinger))
    }
    return effects
  }

  mutating func insertionFinished(
    generation: Int,
    outcome: PasteOutcome,
    reason: RejectionReason?
  ) -> [Effect] {
    guard let index = inserting.firstIndex(where: { $0.generation == generation }) else { return [] }
    let snippet = inserting.remove(at: index)
    let result: PresentedResult
    let dismissalEffects: [Effect]
    switch outcome {
    case .confirmed:
      presented = nil
      wasCopied = false
      return [.discardSnippet(generation: generation), .cancelDismiss]
    case .attempted:
      result = .attempted(text: snippet.transcript)
      dismissalEffects = [.cancelDismiss, .scheduleDismiss(after: configuration.attentionLinger)]
    case .rejected:
      result = .rejected(text: snippet.transcript, reason: reason ?? .focusChanged)
      dismissalEffects = [.cancelDismiss]
    }
    setPresented(result)
    return [.discardSnippet(generation: generation)] + dismissalEffects
  }

  mutating func setPresented(_ result: PresentedResult) {
    presented = result
    wasCopied = false
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
    case .confirmed(let text):
      return PresentationValues(mode: .completed, text: text, message: "Inserted into the focused field")
    case .attempted(let text):
      return PresentationValues(mode: .attention, text: text, message: "Paste attempted · copy if needed")
    case .rejected(let text, let reason):
      let message = switch reason {
      case .noTarget: "No target app was captured · copy instead"
      case .focusChanged: "Focus or app changed · copy instead"
      case .secureField: "Secure field · copy instead"
      }
      return PresentationValues(mode: .attention, text: text, message: message)
    case .timedOut(let text):
      return PresentationValues(mode: .attention, text: text, message: "No result arrived · copy what was heard")
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

private extension DictationSession.PresentedResult {
  var text: String {
    switch self {
    case .confirmed(let text), .attempted(let text), .timedOut(let text): text
    case .rejected(let text, _): text
    case .error(_, let text): text
    }
  }
}
