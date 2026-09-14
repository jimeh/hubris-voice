import Foundation
import HubrisVoiceCore

enum AppModelCoordinationPolicy {
  enum LocalConfigurationResult: Equatable {
    case applied
    case requiresFullReplacement
  }

  static let maximumLocalConfigurationAttempts = 200

  struct EngineReplacement {
    let coordinatorEpoch: TranscriptionBackendEpoch
    let newEpoch: TranscriptionBackendEpoch
    let previousFormat: TranscriptionPCMFormat
    let newFormat: TranscriptionPCMFormat
    let readiness: TranscriptionEngineReadiness
  }

  static func acceptsNewInsertion(
    changingEngine: Bool,
    pendingConfiguration: Bool
  ) -> Bool {
    !changingEngine && !pendingConfiguration
  }

  static func shouldStartCapture(
    _ invocation: TranscriptionInvocation,
    session: DictationSession
  ) -> Bool {
    session.listening?.id == invocation.id
  }

  @discardableResult
  static func submitEngineCommand(
    _ command: TranscriptionEngineCommand,
    submit: (TranscriptionEngineCommand) -> Bool,
    handleRejection: (DictationSession.Event) -> Void
  ) -> Bool {
    guard submit(command) else {
      let message = "The transcription engine is not accepting audio."
      switch command {
      case .append(let invocationID, _, _), .finish(let invocationID):
        handleRejection(.commandRejected(id: invocationID, message: message))
      case .cancel:
        break
      case .prepare, .begin:
        handleRejection(.localError(message: message))
      }
      return false
    }
    return true
  }

  @MainActor
  static func applyLocalConfiguration(
    maximumAttempts: Int = maximumLocalConfigurationAttempts,
    retryDelay: Duration = .milliseconds(25),
    update: () async throws -> Bool,
    sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async throws -> LocalConfigurationResult {
    precondition(maximumAttempts > 0)
    for attempt in 1 ... maximumAttempts {
      try Task.checkCancellation()
      if try await update() {
        return .applied
      }
      if attempt < maximumAttempts {
        try await sleep(retryDelay)
      }
    }
    return .requiresFullReplacement
  }

  static func applyEngineReplacement(
    session: inout DictationSession,
    replacement: EngineReplacement,
    advanceCoordinator: () -> Void
  ) -> Bool {
    guard
      session.epoch == replacement.coordinatorEpoch,
      session.setFormat(replacement.newFormat)
    else {
      return false
    }
    let previousEpoch = session.epoch
    _ = session.transition(.engineReplaced(
      epoch: replacement.newEpoch,
      readiness: replacement.readiness
    ))
    guard session.epoch == replacement.newEpoch, session.epoch > previousEpoch else {
      _ = session.setFormat(replacement.previousFormat)
      return false
    }
    advanceCoordinator()
    return true
  }

  static func recoveryHint(
    presentedHistoryEntryID: UUID?,
    latestEntry: TranscriptEntry?,
    presentedText: String,
    shortcutDisplayName: String?
  ) -> String? {
    guard
      let presentedHistoryEntryID,
      latestEntry?.id == presentedHistoryEntryID,
      latestEntry?.text == presentedText
    else {
      return nil
    }
    if let shortcutDisplayName {
      return "\(shortcutDisplayName) inserts it"
    }
    return "Copy it from the menu bar"
  }
}
