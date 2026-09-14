import Foundation
@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

@MainActor
final class AppModelCoordinationTests: XCTestCase {
  func testInsertionAdmissionRejectsEngineChangesAndPendingConfiguration() {
    XCTAssertTrue(AppModelCoordinationPolicy.acceptsNewInsertion(
      changingEngine: false,
      pendingConfiguration: false
    ))
    XCTAssertFalse(AppModelCoordinationPolicy.acceptsNewInsertion(
      changingEngine: true,
      pendingConfiguration: false
    ))
    XCTAssertFalse(AppModelCoordinationPolicy.acceptsNewInsertion(
      changingEngine: false,
      pendingConfiguration: true
    ))
  }

  func testEngineReplacementDoesNotAdvanceCoordinatorWhenSessionIsNotQuiescent() {
    var session = DictationSession(readiness: .ready)
    _ = session.transition(.pasteLastRequested(text: "queued"))
    var coordinatorAdvanced = false

    let applied = AppModelCoordinationPolicy.applyEngineReplacement(
      session: &session,
      replacement: .init(
        coordinatorEpoch: .init(0),
        newEpoch: .init(1),
        previousFormat: .openAI,
        newFormat: .local,
        readiness: .unavailable(reason: "Local model unloaded.", action: nil)
      )
    ) {
      coordinatorAdvanced = true
    }

    XCTAssertFalse(applied)
    XCTAssertFalse(coordinatorAdvanced)
    XCTAssertEqual(session.epoch, .init(0))
  }

  func testRejectedReplacementRestoresPreviousFormatBeforeCoordinatorAdvances() throws {
    var session = DictationSession(readiness: .ready)
    var coordinatorAdvanced = false

    let applied = AppModelCoordinationPolicy.applyEngineReplacement(
      session: &session,
      replacement: .init(
        coordinatorEpoch: .init(0),
        newEpoch: .init(0),
        previousFormat: .openAI,
        newFormat: .local,
        readiness: .unavailable(reason: "Local model unloaded.", action: nil)
      )
    ) {
      coordinatorAdvanced = true
    }

    XCTAssertFalse(applied)
    XCTAssertFalse(coordinatorAdvanced)
    XCTAssertEqual(session.epoch, .init(0))
    let effects = session.transition(.pressed)
    let invocation = try XCTUnwrap(effects.compactMap { effect -> TranscriptionInvocation? in
      guard case .startCapture(let invocation) = effect else { return nil }
      return invocation
    }.first)
    XCTAssertEqual(invocation.format, .openAI)
  }

  func testEngineReplacementAdvancesCoordinatorAfterSessionAcceptsEpoch() {
    var session = DictationSession(readiness: .ready)
    var coordinatorAdvanced = false

    let applied = AppModelCoordinationPolicy.applyEngineReplacement(
      session: &session,
      replacement: .init(
        coordinatorEpoch: .init(0),
        newEpoch: .init(1),
        previousFormat: .openAI,
        newFormat: .local,
        readiness: .unavailable(reason: "Local model unloaded.", action: nil)
      )
    ) {
      coordinatorAdvanced = true
    }

    XCTAssertTrue(applied)
    XCTAssertTrue(coordinatorAdvanced)
    XCTAssertEqual(session.epoch, .init(1))
  }

  func testRecoveryHintRequiresPresentedTranscriptToBeLatestHistoryEntry() {
    let older = TranscriptEntry(text: "older", targetBundleID: nil, outcome: .pasted)
    XCTAssertNil(AppModelCoordinationPolicy.recoveryHint(
      presentedHistoryEntryID: nil,
      latestEntry: older,
      presentedText: "unfinished local preview",
      shortcutDisplayName: "Fn"
    ))
    XCTAssertNil(AppModelCoordinationPolicy.recoveryHint(
      presentedHistoryEntryID: UUID(),
      latestEntry: older,
      presentedText: older.text,
      shortcutDisplayName: "Fn"
    ))
    XCTAssertNil(AppModelCoordinationPolicy.recoveryHint(
      presentedHistoryEntryID: older.id,
      latestEntry: older,
      presentedText: "different text",
      shortcutDisplayName: "Fn"
    ))
    XCTAssertEqual(AppModelCoordinationPolicy.recoveryHint(
      presentedHistoryEntryID: older.id,
      latestEntry: older,
      presentedText: older.text,
      shortcutDisplayName: "Fn"
    ), "Fn inserts it")
  }

  func testLocalConnectionSummaryUsesLocalReadinessAndTerms() throws {
    let suite = "HubrisVoice.AppModelCoordinationTest.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(TranscriptionEngineSelection.fluidAudio.rawValue, forKey: TranscriptionPreferences.Key.engine)
    let model = AppModel(defaults: defaults)
    model.localModels.loadState = .loaded
    model.localModels.entries = [
      LocalVocabularyEntry(canonicalText: "PostgreSQL"),
      LocalVocabularyEntry(canonicalText: "URLSession"),
    ]

    XCTAssertEqual(model.connectionSummary, "On-device · Loaded · 2 local dictionary terms")
  }
}
