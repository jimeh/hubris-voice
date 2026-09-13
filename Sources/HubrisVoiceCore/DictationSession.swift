import Foundation

// `id` consistently means a transcription invocation identity in this reducer.
// swiftlint:disable identifier_name

public struct OverlayPresentation: Equatable, Sendable {
  public enum Mode: Equatable, Sendable { case listening, finalizing, attention }
  public let mode: Mode
  public let transcript: String
  /// Empty while everything is normal. Non-empty only for engine status
  /// while listening and for the reason in attention. The app owns shortcut hints.
  public let message: String
  public let pendingCount: Int
  public let isLocked: Bool

  public init(
    mode: Mode, transcript: String, message: String, pendingCount: Int, isLocked: Bool = false
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
    public let id: TranscriptionInvocationID
    public var transcript: String
    public internal(set) var isInsertionStarted: Bool
    public var generation: Int {
      id.generation
    }

    public init(
      id: TranscriptionInvocationID,
      transcript: String = "",
      isInsertionStarted: Bool = false
    ) {
      self.id = id
      self.transcript = transcript
      self.isInsertionStarted = isInsertionStarted
    }

    public init(generation: Int, transcript: String = "") {
      self.init(id: .init(epoch: .init(0), generation: generation), transcript: transcript)
    }
  }

  public enum PresentedResult: Equatable, Sendable {
    case rejected(text: String, reason: RejectionReason)
    case timedOut(text: String)
    case error(message: String, text: String)
  }

  public enum RejectionReason: Equatable, Sendable { case noTarget, secureField, deliveryFailed }

  public enum Event: Equatable, Sendable {
    case pressed
    case released(heldDuration: TimeInterval)
    case cancelRequested
    case dismissRequested
    case pasteLastRequested(text: String)
    case localError(message: String)
    case bufferFull(generation: Int)
    case engine(TranscriptionEngineEvent)
    case engineReplaced(epoch: TranscriptionBackendEpoch, readiness: TranscriptionEngineReadiness)
    case finalizingTimedOut(generation: Int)
    case insertionStarted(generation: Int)
    case dismissDelayElapsed
    case insertionFinished(generation: Int, outcome: PasteOutcome, reason: RejectionReason?)
  }

  public enum Effect: Equatable, Sendable {
    case startCapture(TranscriptionInvocation)
    case stopCapture(generation: Int)
    case beginTranscription(TranscriptionInvocation)
    case finishTranscription(id: TranscriptionInvocationID)
    case cancelTranscription(id: TranscriptionInvocationID)
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
    public var tapToLock: Bool
    public var format: TranscriptionPCMFormat

    public init(
      minimumHoldDuration: TimeInterval = 0.2,
      finalizingTimeout: Duration = .seconds(8),
      attentionLinger: Duration = .seconds(4),
      maximumPendingSnippets: Int = 4,
      tapToLock: Bool = false,
      format: TranscriptionPCMFormat = .openAI
    ) {
      self.minimumHoldDuration = minimumHoldDuration
      self.finalizingTimeout = finalizingTimeout
      self.attentionLinger = attentionLinger
      self.maximumPendingSnippets = maximumPendingSnippets
      self.tapToLock = tapToLock
      self.format = format
    }
  }

  public private(set) var epoch: TranscriptionBackendEpoch
  public private(set) var readiness: TranscriptionEngineReadiness
  public private(set) var listening: Snippet?
  public private(set) var pending: [Snippet] = []
  public private(set) var inserting: [Snippet] = []
  public private(set) var presented: PresentedResult?
  public private(set) var nextGeneration = 0
  public private(set) var isLocked = false
  private var configuration: Configuration

  public init(
    configuration: Configuration = .init(),
    epoch: TranscriptionBackendEpoch = .init(0),
    readiness: TranscriptionEngineReadiness
  ) {
    self.configuration = configuration
    self.epoch = epoch
    self.readiness = readiness
  }

  public mutating func setTapToLock(_ enabled: Bool) {
    configuration.tapToLock = enabled
  }

  @discardableResult
  public mutating func setFormat(_ format: TranscriptionPCMFormat) -> Bool {
    guard listening == nil, pending.isEmpty, inserting.isEmpty else { return false }
    configuration.format = format
    return true
  }

  // This switch is the reducer's direct, exhaustive event dispatch.
  // swiftlint:disable:next cyclomatic_complexity
  public mutating func transition(_ event: Event) -> [Effect] {
    switch event {
    case .pressed: pressed()
    case .released(let heldDuration): released(heldDuration: heldDuration)
    case .bufferFull(let generation):
      listening?.generation == generation ? releaseListeningSnippet() : []
    case .cancelRequested: cancelRequested()
    case .dismissRequested: dismissRequested()
    case .pasteLastRequested(let text): pasteLastRequested(text: text)
    case .localError(let message): localError(message: message)
    case .engine(let event): handle(event)
    case .engineReplaced(let epoch, let readiness):
      replaceEngine(epoch: epoch, readiness: readiness)
    case .finalizingTimedOut(let generation): finalizingTimedOut(generation: generation)
    case .insertionStarted(let generation): insertionStarted(generation: generation)
    case .dismissDelayElapsed: dismissDelayElapsed()
    case .insertionFinished(let generation, let outcome, let reason):
      insertionFinished(generation: generation, outcome: outcome, reason: reason)
    }
  }

  public var presentation: OverlayPresentation? {
    if let listening {
      return OverlayPresentation(
        mode: .listening, transcript: listening.transcript,
        message: readiness.listeningMessage, pendingCount: pending.count, isLocked: isLocked
      )
    }
    if let presented {
      let values = presentationValues(for: presented)
      return OverlayPresentation(
        mode: values.mode, transcript: values.text, message: values.message,
        pendingCount: pending.count
      )
    }
    if !pending.isEmpty || !inserting.isEmpty {
      let transcript = pending.last?.transcript ?? inserting.last?.transcript ?? ""
      return OverlayPresentation(
        mode: .finalizing, transcript: transcript, message: "",
        pendingCount: max(0, pending.count + inserting.count - 1)
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
    return readiness.phaseTitle
  }
}

private extension DictationSession {
  mutating func pressed() -> [Effect] {
    if listening != nil, isLocked {
      return releaseListeningSnippet()
    }
    guard readiness.permitsBoundedCapture else {
      if case .unavailable(let reason, let action) = readiness {
        setPresented(.error(message: [reason, action].compactMap(\.self).joined(separator: " "), text: ""))
      }
      return [.scheduleDismiss(after: configuration.attentionLinger)]
    }
    guard listening == nil else { return [] }
    guard pending.count + inserting.count < configuration.maximumPendingSnippets else {
      setPresented(.error(message: "Waiting for previous transcripts.", text: ""))
      return [.scheduleDismiss(after: configuration.attentionLinger)]
    }
    let id = TranscriptionInvocationID(epoch: epoch, generation: nextGeneration)
    nextGeneration += 1
    let invocation = TranscriptionInvocation(id: id, format: configuration.format)
    listening = Snippet(id: id)
    presented = nil
    return [.cancelDismiss, .beginTranscription(invocation), .startCapture(invocation)]
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
        .stopCapture(generation: listening.generation),
        .cancelTranscription(id: listening.id),
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
    return [
      .stopCapture(generation: listening.generation),
      .finishTranscription(id: listening.id),
      .scheduleFinalizingTimeout(generation: listening.generation, after: configuration.finalizingTimeout),
    ]
  }

  mutating func cancelRequested() -> [Effect] {
    if let listening {
      self.listening = nil
      isLocked = false
      return [
        .stopCapture(generation: listening.generation),
        .cancelTranscription(id: listening.id),
        .discardSnippet(generation: listening.generation),
      ]
    }
    let pendingSnippets = pending
    let queuedInsertions = inserting.filter { !$0.isInsertionStarted }
    guard !pendingSnippets.isEmpty || !queuedInsertions.isEmpty else {
      return presented == nil ? [] : dismissRequested()
    }
    pending = []
    inserting.removeAll { !$0.isInsertionStarted }
    let pendingEffects: [Effect] = pendingSnippets.flatMap { snippet in
      [
        .cancelFinalizingTimeout(generation: snippet.generation),
        .cancelTranscription(id: snippet.id),
        .discardSnippet(generation: snippet.generation),
      ]
    }
    let queuedInsertionEffects: [Effect] = queuedInsertions.flatMap { snippet in
      [
        .cancelTranscription(id: snippet.id),
        .discardSnippet(generation: snippet.generation),
      ]
    }
    return pendingEffects + queuedInsertionEffects
  }

  mutating func dismissRequested() -> [Effect] {
    guard presented != nil else { return [] }
    presented = nil
    return [.cancelDismiss]
  }

  mutating func dismissDelayElapsed() -> [Effect] {
    guard presented != nil else { return [] }
    presented = nil
    return []
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
      .stopCapture(generation: listening.generation),
      .cancelTranscription(id: listening.id),
      .discardSnippet(generation: listening.generation),
      .scheduleDismiss(after: configuration.attentionLinger),
    ]
  }

  mutating func replaceEngine(
    epoch: TranscriptionBackendEpoch, readiness: TranscriptionEngineReadiness
  ) -> [Effect] {
    guard listening == nil, pending.isEmpty, inserting.isEmpty, epoch > self.epoch else { return [] }
    self.epoch = epoch
    self.readiness = readiness
    return []
  }

  mutating func handle(_ event: TranscriptionEngineEvent) -> [Effect] {
    switch event {
    case .readiness(let eventEpoch, let state):
      guard eventEpoch == epoch else { return [] }
      readiness = state
      return []
    case .preview(let id, let text):
      guard id.epoch == epoch else { return [] }
      if listening?.id == id {
        listening?.transcript = text
      } else if let index = pending.firstIndex(where: { $0.id == id }) {
        pending[index].transcript = text
      }
      return []
    case .final(let id, let result): return transcriptCompleted(id: id, result: result)
    case .failure(let eventEpoch, let id, let failure):
      guard eventEpoch == epoch else { return [] }
      return engineFailure(id: id, failure: failure)
    }
  }

  mutating func transcriptCompleted(
    id: TranscriptionInvocationID, result: TranscriptionFinalResult
  ) -> [Effect] {
    guard id.epoch == epoch, let index = pending.firstIndex(where: { $0.id == id }) else { return [] }
    var snippet = pending.remove(at: index)
    let text = result.text.trimmingWhitespace
    guard !text.isEmpty else {
      setPresented(.error(message: "No speech was detected.", text: ""))
      return [
        .cancelFinalizingTimeout(generation: snippet.generation),
        .discardSnippet(generation: snippet.generation),
        .scheduleDismiss(after: configuration.attentionLinger),
      ]
    }
    snippet.transcript = text
    inserting.append(snippet)
    return [
      .cancelFinalizingTimeout(generation: snippet.generation),
      .recordTranscript(generation: snippet.generation, text: text),
      .insert(generation: snippet.generation, text: text),
    ]
  }

  mutating func engineFailure(
    id: TranscriptionInvocationID?, failure: TranscriptionFailure
  ) -> [Effect] {
    if let id {
      guard id.epoch == epoch else { return [] }
      if let index = pending.firstIndex(where: { $0.id == id }) {
        let snippet = pending.remove(at: index)
        setPresented(.error(message: failure.message, text: snippet.transcript))
        return [
          .cancelFinalizingTimeout(generation: snippet.generation),
          .discardSnippet(generation: snippet.generation),
          .scheduleDismiss(after: configuration.attentionLinger),
        ]
      }
      guard listening?.id == id else { return [] }
    }
    let text = listening?.transcript ?? pending.last?.transcript ?? inserting.last?.transcript ?? ""
    setPresented(.error(message: failure.message, text: text))
    var effects: [Effect] = []
    if let listening {
      self.listening = nil
      isLocked = false
      effects += [
        .stopCapture(generation: listening.generation),
        .cancelTranscription(id: listening.id),
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
      .cancelTranscription(id: snippet.id),
      .discardSnippet(generation: generation),
      .scheduleDismiss(after: configuration.attentionLinger),
    ]
  }

  mutating func insertionFinished(
    generation: Int, outcome: PasteOutcome, reason: RejectionReason?
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
        .discardSnippet(generation: generation), .cancelDismiss,
        .scheduleDismiss(after: configuration.attentionLinger),
      ]
    }
  }

  mutating func insertionStarted(generation: Int) -> [Effect] {
    guard let index = inserting.firstIndex(where: { $0.generation == generation }) else { return [] }
    inserting[index].isInsertionStarted = true
    return []
  }

  mutating func setPresented(_ result: PresentedResult) {
    presented = result
  }

  mutating func beginCurrentFocusInsertion(text: String) -> [Effect] {
    let generation = nextGeneration
    nextGeneration += 1
    inserting.append(Snippet(id: .init(epoch: epoch, generation: generation), transcript: text))
    presented = nil
    return [.cancelDismiss, .insertAtCurrentFocus(generation: generation, text: text)]
  }

  func presentationValues(for result: PresentedResult) -> PresentationValues {
    switch result {
    case .rejected(let text, let reason):
      let message = switch reason {
      case .noTarget: "No text field is focused"
      case .secureField: "Secure field"
      case .deliveryFailed: "Could not send paste"
      }
      return PresentationValues(mode: .attention, text: text, message: message)
    case .timedOut(let text):
      return PresentationValues(mode: .attention, text: text, message: "No transcript arrived")
    case .error(let message, let text):
      return PresentationValues(mode: .attention, text: text, message: message)
    }
  }
}

private extension TranscriptionEngineReadiness {
  var listeningMessage: String {
    switch self {
    case .ready: ""
    case .preparing(let message), .recovering(let message): message
    case .unavailable(let reason, _): reason
    }
  }

  var phaseTitle: String {
    switch self {
    case .ready: "Ready"
    case .preparing: "Preparing"
    case .recovering: "Recovering"
    case .unavailable: "Unavailable"
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

// swiftlint:enable identifier_name
