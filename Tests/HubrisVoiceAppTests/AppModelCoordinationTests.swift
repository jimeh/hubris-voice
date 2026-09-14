import Foundation
@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

@MainActor
final class AppModelCoordinationTests: XCTestCase {
  func testLocalConfigurationFallsBackAfterBoundedBusyResponses() async throws {
    var updateCount = 0
    var sleepCount = 0

    let result = try await AppModelCoordinationPolicy.applyLocalConfiguration(
      maximumAttempts: 3,
      update: {
        updateCount += 1
        return false
      },
      sleep: { _ in sleepCount += 1 }
    )

    XCTAssertEqual(result, .requiresFullReplacement)
    XCTAssertEqual(updateCount, 3)
    XCTAssertEqual(sleepCount, 2)
  }

  func testLocalConfigurationAppliesWhenBackendBecomesIdleWithinBound() async throws {
    var updateCount = 0

    let result = try await AppModelCoordinationPolicy.applyLocalConfiguration(
      maximumAttempts: 3,
      update: {
        updateCount += 1
        return updateCount == 3
      },
      sleep: { _ in }
    )

    XCTAssertEqual(result, .applied)
    XCTAssertEqual(updateCount, 3)
  }

  func testLocalConfigurationPreservesCancellation() async {
    var updateCount = 0
    do {
      _ = try await AppModelCoordinationPolicy.applyLocalConfiguration(
        maximumAttempts: 3,
        update: {
          updateCount += 1
          return false
        },
        sleep: { _ in throw CancellationError() }
      )
      XCTFail("Cancellation must escape the retry policy")
    } catch is CancellationError {
      XCTAssertEqual(updateCount, 1)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

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

  func testRejectedAppendAndCleanupCancelRetireOnlyTargetInvocation() throws {
    var session = DictationSession(epoch: .init(7), readiness: .ready)
    let rejectedID = try makePending(in: &session)
    _ = session.transition(.engine(.preview(id: rejectedID, text: "recover pending")))
    let preservedPendingID = try makePending(in: &session)
    _ = session.transition(.pressed)
    let listeningID = try XCTUnwrap(session.listening?.id)
    let sink = RejectingEngineCommandSink()
    let message = "The transcription engine is not accepting audio."
    var effects: [DictationSession.Effect] = []

    XCTAssertFalse(AppModelCoordinationPolicy.submitEngineCommand(
      .append(id: rejectedID, sequence: 3, audio: Data([1, 2, 3])),
      submit: sink.submit
    ) { effects += session.transition($0) })
    XCTAssertEqual(effects, [
      .cancelFinalizingTimeout(generation: rejectedID.generation),
      .cancelTranscription(id: rejectedID),
      .discardSnippet(generation: rejectedID.generation),
      .scheduleDismiss(after: .seconds(4)),
    ])
    XCTAssertEqual(session.listening?.id, listeningID)
    XCTAssertEqual(session.pending.map(\.id), [preservedPendingID])
    XCTAssertEqual(session.presented, .error(message: message, text: "recover pending"))

    var cleanupEffects: [DictationSession.Effect] = []
    XCTAssertFalse(AppModelCoordinationPolicy.submitEngineCommand(
      .cancel(id: rejectedID),
      submit: sink.submit
    ) { cleanupEffects += session.transition($0) })
    XCTAssertEqual(cleanupEffects, [])
    XCTAssertEqual(session.listening?.id, listeningID)
    XCTAssertEqual(session.pending.map(\.id), [preservedPendingID])
    XCTAssertEqual(session.presented, .error(message: message, text: "recover pending"))
    XCTAssertEqual(sink.commands, [
      .append(id: rejectedID, sequence: 3, audio: Data([1, 2, 3])),
      .cancel(id: rejectedID),
    ])
  }

  func testRejectedFinishRetiresPendingInvocationAndIgnoresLateFinal() throws {
    var session = DictationSession(epoch: .init(7), readiness: .ready)
    let rejectedID = try makePending(in: &session)
    _ = session.transition(.engine(.preview(id: rejectedID, text: "recover final chunk")))
    let sink = RejectingEngineCommandSink()
    var effects: [DictationSession.Effect] = []

    XCTAssertFalse(AppModelCoordinationPolicy.submitEngineCommand(
      .finish(id: rejectedID),
      submit: sink.submit
    ) { effects += session.transition($0) })
    XCTAssertEqual(effects, [
      .cancelFinalizingTimeout(generation: rejectedID.generation),
      .cancelTranscription(id: rejectedID),
      .discardSnippet(generation: rejectedID.generation),
      .scheduleDismiss(after: .seconds(4)),
    ])
    XCTAssertEqual(session.pending, [])
    XCTAssertEqual(
      session.presented,
      .error(
        message: "The transcription engine is not accepting audio.",
        text: "recover final chunk"
      )
    )
    XCTAssertEqual(session.transition(.engine(.final(
      id: rejectedID,
      result: .init(text: "late final", correction: .disabled)
    ))), [])
    XCTAssertEqual(sink.commands, [.finish(id: rejectedID)])
  }

  func testAcceptedEngineCommandDoesNotReportRejection() {
    let command = TranscriptionEngineCommand.prepare(epoch: .init(3))
    var submittedCommands: [TranscriptionEngineCommand] = []
    var rejectionEvents: [DictationSession.Event] = []

    XCTAssertTrue(AppModelCoordinationPolicy.submitEngineCommand(
      command,
      submit: {
        submittedCommands.append($0)
        return true
      },
      handleRejection: { rejectionEvents.append($0) }
    ))
    XCTAssertEqual(submittedCommands, [command])
    XCTAssertEqual(rejectionEvents, [])
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

  private func makePending(
    in session: inout DictationSession
  ) throws -> TranscriptionInvocationID {
    _ = session.transition(.pressed)
    let invocationID = try XCTUnwrap(session.listening?.id)
    _ = session.transition(.released(heldDuration: 1))
    return invocationID
  }
}

private final class RejectingEngineCommandSink {
  private(set) var commands: [TranscriptionEngineCommand] = []

  func submit(_ command: TranscriptionEngineCommand) -> Bool {
    commands.append(command)
    return false
  }
}
