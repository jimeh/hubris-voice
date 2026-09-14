import Foundation
import HubrisVoiceCore

enum AppModelCoordinationPolicy {
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
