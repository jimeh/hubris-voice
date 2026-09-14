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

  func testLocalConfigurationChecksCancellationAfterSuccessfulUpdate() async {
    await assertConfigurationUpdateCancellation(updateResult: true)
  }

  func testLocalConfigurationChecksCancellationAfterFinalBusyUpdate() async {
    await assertConfigurationUpdateCancellation(updateResult: false)
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

  func testRejectedListeningCommandRecordsCancelledRecoveryHistory() throws {
    var session = DictationSession(readiness: .ready)
    _ = session.transition(.pressed)
    let invocationID = try XCTUnwrap(session.listening?.id)
    _ = session.transition(.engine(.preview(id: invocationID, text: "recover listening")))
    let model = try makeModel(initialSession: session)

    model.testingRejectEngineCommand(id: invocationID, message: "Engine closed")

    XCTAssertEqual(model.history.entries.count, 1)
    XCTAssertEqual(model.history.latest?.text, "recover listening")
    XCTAssertEqual(model.history.latest?.outcome, .cancelled)
    XCTAssertEqual(model.overlayModel.transcript, "recover listening")
    XCTAssertEqual(model.overlayModel.message, "Engine closed · Copy it from the menu bar")

    model.testingRejectEngineCommand(id: invocationID, message: "Already retired")
    XCTAssertEqual(model.history.entries.count, 1)
  }

  func testRejectedPendingCommandRecordsCancelledRecoveryHistory() throws {
    var session = DictationSession(readiness: .ready)
    let invocationID = try makePending(in: &session)
    _ = session.transition(.engine(.preview(id: invocationID, text: "recover pending")))
    let model = try makeModel(initialSession: session)

    model.testingRejectEngineCommand(id: invocationID, message: "Engine closed")

    XCTAssertEqual(model.history.entries.count, 1)
    XCTAssertEqual(model.history.latest?.text, "recover pending")
    XCTAssertEqual(model.history.latest?.outcome, .cancelled)
    XCTAssertEqual(model.overlayModel.transcript, "recover pending")
    XCTAssertEqual(model.overlayModel.message, "Engine closed · Copy it from the menu bar")
  }

  func testTargetedListeningFailureRecordsRejectedRecoveryHistory() throws {
    var session = DictationSession(readiness: .ready)
    _ = session.transition(.pressed)
    let invocationID = try XCTUnwrap(session.listening?.id)
    _ = session.transition(.engine(.preview(id: invocationID, text: "recover listening failure")))
    let model = try makeModel(initialSession: session)
    model.testingHandleEngineEvent(.failure(
      epoch: invocationID.epoch,
      id: invocationID,
      failure: .init(kind: .transport, message: "Transport failed", isRecoverable: true)
    ))
    XCTAssertEqual(model.history.latest?.text, "recover listening failure")
    XCTAssertEqual(model.history.latest?.outcome, .rejected)
    XCTAssertEqual(model.overlayModel.message, "Transport failed · Copy it from the menu bar")
  }

  func testTargetedPendingFailureRecordsOnlyExactInvocation() throws {
    var session = DictationSession(readiness: .ready)
    let invocationID = try makePending(in: &session)
    _ = session.transition(.engine(.preview(id: invocationID, text: "recover pending failure")))
    let model = try makeModel(initialSession: session)
    let staleID = TranscriptionInvocationID(
      epoch: .init(invocationID.epoch.rawValue + 1),
      generation: invocationID.generation
    )
    model.testingHandleEngineEvent(.failure(
      epoch: staleID.epoch,
      id: staleID,
      failure: .init(kind: .transport, message: "Stale", isRecoverable: true)
    ))
    XCTAssertTrue(model.history.entries.isEmpty)
    model.testingHandleEngineEvent(.failure(
      epoch: invocationID.epoch,
      id: invocationID,
      failure: .init(kind: .transport, message: "Transport failed", isRecoverable: true)
    ))
    XCTAssertEqual(model.history.latest?.text, "recover pending failure")
    XCTAssertEqual(model.history.latest?.outcome, .rejected)
  }

  func testUnavailableReadinessRecordsCancelledRecoveryHistory() throws {
    var session = DictationSession(readiness: .ready)
    _ = session.transition(.pressed)
    let invocationID = try XCTUnwrap(session.listening?.id)
    _ = session.transition(.engine(.preview(id: invocationID, text: "recover unavailable")))
    let model = try makeModel(initialSession: session)
    model.testingHandleEngineEvent(.readiness(
      epoch: invocationID.epoch,
      state: .unavailable(reason: "Connection unavailable.", action: nil)
    ))
    XCTAssertEqual(model.history.latest?.text, "recover unavailable")
    XCTAssertEqual(model.history.latest?.outcome, .cancelled)
    XCTAssertEqual(model.overlayModel.message, "Connection unavailable. · Copy it from the menu bar")
  }

  func testRejectedCommandDoesNotRecordStaleOrEmptySnippet() throws {
    var session = DictationSession(readiness: .ready)
    _ = session.transition(.pressed)
    let invocationID = try XCTUnwrap(session.listening?.id)
    _ = session.transition(.engine(.preview(id: invocationID, text: "keep current")))
    let model = try makeModel(initialSession: session)
    let staleID = TranscriptionInvocationID(
      epoch: .init(invocationID.epoch.rawValue + 1),
      generation: invocationID.generation
    )

    model.testingRejectEngineCommand(id: staleID, message: "Stale")
    XCTAssertTrue(model.history.entries.isEmpty)
    XCTAssertEqual(model.overlayModel.transcript, "keep current")

    var emptySession = DictationSession(readiness: .ready)
    _ = emptySession.transition(.pressed)
    let emptyID = try XCTUnwrap(emptySession.listening?.id)
    let emptyModel = try makeModel(initialSession: emptySession)
    emptyModel.testingRejectEngineCommand(id: emptyID, message: "Engine closed")
    XCTAssertTrue(emptyModel.history.entries.isEmpty)
    XCTAssertEqual(emptyModel.overlayModel.transcript, "")
    XCTAssertEqual(emptyModel.overlayModel.message, "Engine closed")
  }

  func testMissingLocalModelSetsFailedLoadState() throws {
    let suite = "HubrisVoice.AppModelCoordinationTest.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(TranscriptionEngineSelection.fluidAudio.rawValue, forKey: TranscriptionPreferences.Key.engine)
    let model = AppModel(defaults: defaults)
    model.localModels.load()
    XCTAssertEqual(model.localModels.loadState, .failed("The local model is not installed."))
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

  func testRejectedBeginSuppressesStaleStartCaptureEffect() {
    var session = DictationSession(readiness: .ready)
    let effects = session.transition(.pressed)
    let sink = RejectingEngineCommandSink()
    var captures: [TranscriptionInvocation] = []

    for effect in effects {
      switch effect {
      case .beginTranscription(let invocation):
        XCTAssertFalse(AppModelCoordinationPolicy.submitEngineCommand(
          .begin(invocation),
          submit: sink.submit,
          handleRejection: { _ = session.transition($0) }
        ))
      case .startCapture(let invocation):
        if AppModelCoordinationPolicy.shouldStartCapture(invocation, session: session) {
          captures.append(invocation)
        }
      default:
        break
      }
    }

    XCTAssertNil(session.listening)
    XCTAssertEqual(captures, [])
  }

  func testAcceptedBeginAllowsCurrentInvocationCapture() throws {
    var session = DictationSession(readiness: .ready)
    let effects = session.transition(.pressed)
    var captures: [TranscriptionInvocation] = []

    for effect in effects {
      switch effect {
      case .beginTranscription(let invocation):
        XCTAssertTrue(AppModelCoordinationPolicy.submitEngineCommand(
          .begin(invocation),
          submit: { _ in true },
          handleRejection: { _ = session.transition($0) }
        ))
      case .startCapture(let invocation):
        if AppModelCoordinationPolicy.shouldStartCapture(invocation, session: session) {
          captures.append(invocation)
        }
      default:
        break
      }
    }

    let listeningID = try XCTUnwrap(session.listening?.id)
    XCTAssertEqual(captures.map(\.id), [listeningID])
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

  private func makeModel(initialSession: DictationSession) throws -> AppModel {
    let suite = "HubrisVoice.AppModelCoordinationTest.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    addTeardownBlock {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
    return AppModel(defaults: defaults, initialSession: initialSession)
  }
}

private func assertConfigurationUpdateCancellation(
  updateResult: Bool,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  let gate = ConfigurationUpdateGate()
  let task = Task {
    try await AppModelCoordinationPolicy.applyLocalConfiguration(maximumAttempts: 1) {
      await gate.suspend()
      return updateResult
    }
  }
  guard await gate.waitUntilSuspended() else {
    task.cancel()
    await gate.cancelAndResume()
    XCTFail("Configuration update did not suspend before the deadline", file: file, line: line)
    return
  }
  task.cancel()
  await gate.cancelAndResume()

  do {
    _ = try await task.value
    XCTFail("Cancellation during the update must escape the retry policy", file: file, line: line)
  } catch is CancellationError {
  } catch {
    XCTFail("Unexpected error: \(error)", file: file, line: line)
  }
}

private actor ConfigurationUpdateGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isCancelled = false

  func suspend() async {
    guard !isCancelled else { return }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func waitUntilSuspended(timeout: Duration = .seconds(1)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while continuation == nil, clock.now < deadline {
      await Task.yield()
    }
    return continuation != nil
  }

  func cancelAndResume() {
    isCancelled = true
    continuation?.resume()
    continuation = nil
  }
}

private final class RejectingEngineCommandSink {
  private(set) var commands: [TranscriptionEngineCommand] = []

  func submit(_ command: TranscriptionEngineCommand) -> Bool {
    commands.append(command)
    return false
  }
}
