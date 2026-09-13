@testable import HubrisVoiceCore
import XCTest

// The transition tests stay together for review against the design contracts.
// swiftlint:disable file_length

final class DictationSessionTests: XCTestCase {
  func testConnectionLossSchedulesFirstReconnectAttempt() {
    var session = readySession()

    XCTAssertEqual(
      session.transition(.connectionLost(message: "lost")),
      [.scheduleReconnect(after: .milliseconds(500), attempt: 1)]
    )
    XCTAssertEqual(session.connection, .disconnected(attempt: 1))
  }

  func testRepeatedConnectionFailuresGrowAndCapReconnectDelay() {
    let configuration = DictationSession.Configuration(
      reconnect: ReconnectPolicy(maximumDelay: .seconds(1))
    )
    var session = DictationSession(configuration: configuration, hasKey: true)
    _ = session.transition(.connectRequested(force: false))

    XCTAssertEqual(
      session.transition(.connectionFailed(message: "one")),
      [.scheduleReconnect(after: .milliseconds(500), attempt: 1)]
    )
    _ = session.transition(.reconnectDelayElapsed(attempt: 1))
    XCTAssertEqual(
      session.transition(.connectionFailed(message: "two")),
      [.scheduleReconnect(after: .seconds(1), attempt: 2)]
    )
    _ = session.transition(.reconnectDelayElapsed(attempt: 2))
    XCTAssertEqual(
      session.transition(.connectionFailed(message: "three")),
      [.scheduleReconnect(after: .seconds(1), attempt: 3)]
    )
  }

  func testStaleReconnectTimerCannotStartAConnection() {
    var session = DictationSession(hasKey: true)

    XCTAssertEqual(session.transition(.reconnectDelayElapsed(attempt: 1)), [])
    XCTAssertEqual(session.connection, .disconnected(attempt: 0))
  }

  func testManualConnectDoesNotDuplicateAnAttemptAndSupersedesAReconnectTimer() {
    var session = DictationSession(hasKey: true)
    XCTAssertEqual(
      session.transition(.connectRequested(force: false)),
      [.cancelReconnect, .connect(attempt: 0)]
    )
    XCTAssertEqual(session.transition(.connectRequested(force: false)), [])
  }

  func testForcedReconnectClearsOldItemIdentityBeforeReplay() {
    var session = readySession()
    _ = makePending(in: &session, itemID: "old-item")

    XCTAssertEqual(
      session.transition(.connectRequested(force: true)),
      [.disconnect, .cancelReconnect, .connect(attempt: 0)]
    )
    XCTAssertNil(session.pending.first?.itemID)
    XCTAssertEqual(
      session.transition(.sessionReady),
      [.replayAudio(generation: 0), .commitAudio(generation: 0)]
    )
  }

  func testRemovingCredentialsDisconnectsAndPressShowsAPIKeyError() {
    var session = readySession()

    XCTAssertEqual(
      session.transition(.credentialsChanged(hasKey: false)),
      [.disconnect, .cancelReconnect]
    )
    XCTAssertEqual(session.connection, .unconfigured)
    XCTAssertEqual(
      session.transition(.pressed),
      [.scheduleDismiss(after: .seconds(4))]
    )
    XCTAssertEqual(
      session.presented,
      .error(message: "Add an OpenAI API key before dictating.", text: "")
    )
  }

  func testReleaseAfterMinimumCommitsAndSchedulesTimeout() {
    var session = readySession()
    XCTAssertEqual(session.transition(.pressed), [.cancelDismiss, .startCapture(generation: 0)])

    XCTAssertEqual(
      session.transition(.released(heldDuration: 0.2)),
      [
        .stopCapture,
        .commitAudio(generation: 0),
        .scheduleFinalizingTimeout(generation: 0, after: .seconds(8)),
      ]
    )
    XCTAssertEqual(session.pending.map(\.generation), [0])
  }

  func testAccidentalTapClearsAndDiscardsWithoutCommit() {
    var session = readySession()
    _ = session.transition(.pressed)

    XCTAssertEqual(
      session.transition(.released(heldDuration: 0.199)),
      [.stopCapture, .clearAudio(generation: 0), .discardSnippet(generation: 0)]
    )
    XCTAssertTrue(session.pending.isEmpty)
  }

  func testTapToLockKeepsListeningUntilTheNextPress() {
    let configuration = DictationSession.Configuration(tapToLock: true)
    var session = readySession(configuration: configuration)
    _ = session.transition(.pressed)

    XCTAssertEqual(session.transition(.released(heldDuration: 0.1)), [])
    XCTAssertTrue(session.isLocked)
    XCTAssertEqual(session.listening?.generation, 0)
    XCTAssertEqual(session.presentation?.message, "Locked · tap to finish")
    XCTAssertEqual(session.presentation?.isLocked, true)

    XCTAssertEqual(
      session.transition(.pressed),
      [
        .stopCapture,
        .commitAudio(generation: 0),
        .scheduleFinalizingTimeout(generation: 0, after: .seconds(8)),
      ]
    )
    XCTAssertFalse(session.isLocked)
    XCTAssertNil(session.listening)
    XCTAssertEqual(session.transition(.released(heldDuration: 0.1)), [])
  }

  func testCancelWhileLockedClearsTheLock() {
    let configuration = DictationSession.Configuration(tapToLock: true)
    var session = readySession(configuration: configuration)
    _ = session.transition(.pressed)
    _ = session.transition(.released(heldDuration: 0.1))

    XCTAssertEqual(
      session.transition(.cancelRequested),
      [.stopCapture, .clearAudio(generation: 0), .discardSnippet(generation: 0)]
    )
    XCTAssertFalse(session.isLocked)
    XCTAssertNil(session.listening)
  }

  func testPressWhileDisconnectedCapturesImmediatelyThenReplaysWhenReady() {
    var session = DictationSession(hasKey: true)

    XCTAssertEqual(
      session.transition(.pressed),
      [
        .cancelDismiss,
        .cancelReconnect,
        .connect(attempt: 0),
        .startCapture(generation: 0),
      ]
    )
    XCTAssertEqual(session.transition(.sessionReady), [.replayAudio(generation: 0)])
  }

  func testReleaseWhileConnectingReplaysThenCommitsWhenReady() {
    var session = DictationSession(hasKey: true)
    _ = session.transition(.pressed)

    XCTAssertEqual(
      session.transition(.released(heldDuration: 1)),
      [.stopCapture, .scheduleFinalizingTimeout(generation: 0, after: .seconds(8))]
    )
    XCTAssertEqual(
      session.transition(.sessionReady),
      [.replayAudio(generation: 0), .commitAudio(generation: 0)]
    )
  }

  func testConnectionLossDuringFinalizingReassignsCommitBeforeCompletion() {
    var session = readySession()
    _ = makePending(in: &session, itemID: "old")

    _ = session.transition(.connectionLost(message: "lost"))
    XCTAssertNil(session.pending.first?.itemID)
    _ = session.transition(.reconnectDelayElapsed(attempt: 1))
    XCTAssertEqual(
      session.transition(.sessionReady),
      [.replayAudio(generation: 0), .commitAudio(generation: 0)]
    )
    _ = session.transition(.server(.inputCommitted(itemID: "new")))
    XCTAssertEqual(
      session.transition(.server(.transcriptCompleted(itemID: "new", transcript: "text"))),
      [
        .cancelFinalizingTimeout(generation: 0),
        .clearAudio(generation: 0),
        .recordTranscript(generation: 0, text: "text"),
        .insert(generation: 0, text: "text"),
      ]
    )
  }

  func testTranscriptEventsRouteByCommittedItemID() {
    var session = readySession()
    _ = makePending(in: &session, itemID: "item")

    XCTAssertEqual(session.transition(.server(.transcriptDelta(itemID: "unknown", delta: "bad"))), [])
    XCTAssertEqual(session.transition(.server(.transcriptDelta(itemID: "item", delta: "hel"))), [])
    XCTAssertEqual(session.pending.first?.transcript, "hel")
    XCTAssertEqual(
      session.transition(.server(.transcriptCompleted(itemID: "item", transcript: "hello"))),
      [
        .cancelFinalizingTimeout(generation: 0),
        .clearAudio(generation: 0),
        .recordTranscript(generation: 0, text: "hello"),
        .insert(generation: 0, text: "hello"),
      ]
    )
  }

  func testCompletedTranscriptRecordsBeforeInsertion() {
    var session = readySession()
    _ = makePending(in: &session, itemID: "item")

    let effects = session.transition(
      .server(.transcriptCompleted(itemID: "item", transcript: "hello"))
    )

    XCTAssertEqual(
      effects,
      [
        .cancelFinalizingTimeout(generation: 0),
        .clearAudio(generation: 0),
        .recordTranscript(generation: 0, text: "hello"),
        .insert(generation: 0, text: "hello"),
      ]
    )
  }

  func testEmptyCompletedTranscriptIsNotRecorded() {
    var session = readySession()
    _ = makePending(in: &session, itemID: "item")

    let effects = session.transition(
      .server(.transcriptCompleted(itemID: "item", transcript: "  \n"))
    )

    XCTAssertFalse(effects.contains { effect in
      if case .recordTranscript = effect {
        return true
      }
      return false
    })
  }

  func testTwoPendingSnippetsCompleteOutOfOrderWithIndependentText() {
    var session = readySession()
    _ = makePending(in: &session, itemID: "first")
    _ = makePending(in: &session, itemID: "second")

    XCTAssertEqual(session.pending.map(\.itemID), ["first", "second"])
    XCTAssertEqual(
      session.transition(.server(.transcriptCompleted(itemID: "second", transcript: "two"))).last,
      .insert(generation: 1, text: "two")
    )
    XCTAssertEqual(
      session.transition(.server(.transcriptCompleted(itemID: "first", transcript: "one"))).last,
      .insert(generation: 0, text: "one")
    )
  }

  func testPendingLimitRefusesAnotherCapture() {
    let configuration = DictationSession.Configuration(maximumPendingSnippets: 1)
    var session = readySession(configuration: configuration)
    _ = makePending(in: &session)

    XCTAssertEqual(session.transition(.pressed), [.scheduleDismiss(after: .seconds(4))])
    XCTAssertNil(session.listening)
    XCTAssertEqual(session.presented, .error(message: "Waiting for previous transcripts.", text: ""))
  }

  func testFinalizingTimeoutKeepsPartialTextAndStaleTimeoutIsIgnored() {
    var session = readySession()
    _ = makePending(in: &session, itemID: "item")
    _ = session.transition(.server(.transcriptDelta(itemID: "item", delta: "partial")))

    XCTAssertEqual(
      session.transition(.finalizingTimedOut(generation: 0)),
      [.clearAudio(generation: 0), .discardSnippet(generation: 0)]
    )
    XCTAssertEqual(session.presented, .timedOut(text: "partial"))
    XCTAssertEqual(session.transition(.finalizingTimedOut(generation: 0)), [])
  }

  func testBufferCapFinalizesTheListeningSnippet() {
    var session = readySession()
    _ = session.transition(.pressed)

    XCTAssertEqual(
      session.transition(.bufferFull(generation: 0)),
      [
        .stopCapture,
        .commitAudio(generation: 0),
        .scheduleFinalizingTimeout(generation: 0, after: .seconds(8)),
      ]
    )
  }

  func testCancelWhileListeningStopsClearsAndDiscardsWithoutPresentation() {
    var session = readySession()
    _ = session.transition(.pressed)

    XCTAssertEqual(
      session.transition(.cancelRequested),
      [.stopCapture, .clearAudio(generation: 0), .discardSnippet(generation: 0)]
    )
    XCTAssertNil(session.presentation)
  }

  func testCancelWithPendingSnippetsDiscardsEverySnippet() {
    var session = readySession()
    _ = makePending(in: &session)
    _ = makePending(in: &session)

    XCTAssertEqual(
      session.transition(.cancelRequested),
      [
        .cancelFinalizingTimeout(generation: 0), .discardSnippet(generation: 0),
        .cancelFinalizingTimeout(generation: 1), .discardSnippet(generation: 1),
      ]
    )
  }

  func testLocalCaptureErrorCancelsListeningAndDismissesWhenNoTextExists() {
    var session = readySession()
    _ = session.transition(.pressed)

    XCTAssertEqual(
      session.transition(.localError(message: "capture failed")),
      [
        .stopCapture,
        .clearAudio(generation: 0),
        .discardSnippet(generation: 0),
        .scheduleDismiss(after: .seconds(4)),
      ]
    )
    XCTAssertEqual(session.presented, .error(message: "capture failed", text: ""))
  }

  func testEveryPresentedResultCanBeDismissed() {
    for result in presentedResults {
      var session = sessionPresenting(result)
      XCTAssertEqual(session.presentation?.canDismiss, true)
      XCTAssertEqual(session.transition(.dismissRequested), [.cancelDismiss])
      XCTAssertNil(session.presented)
    }
  }

  func testUnconfirmedInsertionOutcomesPresentCorrectMessagesAndLinger() {
    let cases = [
      InsertionCase(
        outcome: .attempted,
        reason: nil,
        mode: .attention,
        message: "Paste attempted · copy if needed",
        effects: [.discardSnippet(generation: 0), .cancelDismiss, .scheduleDismiss(after: .seconds(4))]
      ),
      InsertionCase(
        outcome: .rejected,
        reason: .noTarget,
        mode: .attention,
        message: "No target app was captured · copy instead",
        effects: [.discardSnippet(generation: 0), .cancelDismiss]
      ),
      InsertionCase(
        outcome: .rejected,
        reason: .focusChanged,
        mode: .attention,
        message: "Focus or app changed · copy instead",
        effects: [.discardSnippet(generation: 0), .cancelDismiss]
      ),
      InsertionCase(
        outcome: .rejected,
        reason: .secureField,
        mode: .attention,
        message: "Secure field · copy instead",
        effects: [.discardSnippet(generation: 0), .cancelDismiss]
      ),
    ]

    for testCase in cases {
      var session = insertingSession(text: "hello")
      XCTAssertEqual(
        session.transition(
          .insertionFinished(generation: 0, outcome: testCase.outcome, reason: testCase.reason)
        ),
        testCase.effects
      )
      XCTAssertEqual(session.presentation?.mode, testCase.mode)
      XCTAssertEqual(session.presentation?.message, testCase.message)
    }
  }

  func testConfirmedInsertionClearsPresentationWithoutLinger() {
    var session = insertingSession(text: "hello")

    XCTAssertEqual(
      session.transition(.insertionFinished(generation: 0, outcome: .confirmed, reason: nil)),
      [.discardSnippet(generation: 0), .cancelDismiss]
    )
    XCTAssertNil(session.presented)
    XCTAssertNil(session.presentation)
  }

  func testPasteHereFromRejectedStartsFreshInsertionAndClearsPresentation() {
    var session = sessionPresenting(.rejected(text: "hello", reason: .focusChanged))

    XCTAssertEqual(
      session.transition(.pasteHereRequested),
      [.cancelDismiss, .insertAtCurrentFocus(generation: 1, text: "hello")]
    )
    XCTAssertEqual(session.inserting, [.init(generation: 1, transcript: "hello")])
    XCTAssertNil(session.presented)
    XCTAssertEqual(session.transition(.pasteHereRequested), [])
  }

  func testPasteHereWhileListeningIsIgnored() {
    var session = readySession()
    _ = session.transition(.pressed)

    XCTAssertEqual(session.transition(.pasteHereRequested), [])
    XCTAssertEqual(session.listening?.generation, 0)
    XCTAssertTrue(session.inserting.isEmpty)
  }

  func testPasteLastAllocatesGenerationAndInsertsAtCurrentFocus() {
    var session = readySession()

    XCTAssertEqual(
      session.transition(.pasteLastRequested(text: "hello")),
      [.cancelDismiss, .insertAtCurrentFocus(generation: 0, text: "hello")]
    )
    XCTAssertEqual(session.inserting, [.init(generation: 0, transcript: "hello")])
    XCTAssertEqual(session.nextGeneration, 1)
  }

  func testPasteLastWhileListeningIsIgnored() {
    var session = readySession()
    _ = session.transition(.pressed)

    XCTAssertEqual(session.transition(.pasteLastRequested(text: "hello")), [])
    XCTAssertEqual(session.listening?.generation, 0)
    XCTAssertTrue(session.inserting.isEmpty)
  }

  func testAttentionPresentationWithTextCanPasteHere() {
    let session = sessionPresenting(.rejected(text: "hello", reason: .focusChanged))

    XCTAssertEqual(session.presentation?.mode, .attention)
    XCTAssertEqual(session.presentation?.canPasteHere, true)
  }

  func testRecoveryGenerationCanOnlyFinishOnce() {
    var session = sessionPresenting(.attempted(text: "hello"))
    _ = session.transition(.pasteHereRequested)

    XCTAssertEqual(
      session.transition(.insertionFinished(generation: 1, outcome: .confirmed, reason: nil)),
      [.discardSnippet(generation: 1), .cancelDismiss]
    )
    XCTAssertEqual(
      session.transition(.insertionFinished(generation: 1, outcome: .confirmed, reason: nil)),
      []
    )
  }

  func testStaleInsertionCompletionCannotReplacePresentation() {
    var session = insertingSession(text: "hello")

    XCTAssertEqual(
      session.transition(.insertionFinished(generation: 99, outcome: .confirmed, reason: nil)),
      []
    )
    XCTAssertNil(session.presented)
  }

  func testListeningPresentationShowsQueuedCountAndConnectionMessage() {
    var session = readySession()
    _ = makePending(in: &session)
    _ = session.transition(.pressed)

    XCTAssertEqual(session.presentation?.pendingCount, 1)
    XCTAssertEqual(session.presentation?.message, "Release to insert")
    _ = session.transition(.connectionLost(message: "lost"))
    XCTAssertEqual(session.presentation?.message, "Reconnecting…")
  }
}

private struct InsertionCase {
  let outcome: PasteOutcome
  let reason: DictationSession.RejectionReason?
  let mode: OverlayPresentation.Mode
  let message: String
  let effects: [DictationSession.Effect]
}

private extension DictationSessionTests {
  var presentedResults: [DictationSession.PresentedResult] {
    [
      .attempted(text: "text"),
      .rejected(text: "text", reason: .noTarget),
      .timedOut(text: "text"),
      .error(message: "error", text: "text"),
    ]
  }

  func readySession(
    configuration: DictationSession.Configuration = .init()
  ) -> DictationSession {
    var session = DictationSession(configuration: configuration, hasKey: true)
    _ = session.transition(.connectRequested(force: false))
    _ = session.transition(.sessionReady)
    return session
  }

  @discardableResult
  func makePending(
    in session: inout DictationSession,
    itemID: String? = nil
  ) -> Int {
    let generation = session.nextGeneration
    _ = session.transition(.pressed)
    _ = session.transition(.released(heldDuration: 1))
    if let itemID {
      _ = session.transition(.server(.inputCommitted(itemID: itemID)))
    }
    return generation
  }

  func insertingSession(text: String) -> DictationSession {
    var session = readySession()
    _ = makePending(in: &session, itemID: "item")
    _ = session.transition(.server(.transcriptCompleted(itemID: "item", transcript: text)))
    return session
  }

  func sessionPresenting(_ result: DictationSession.PresentedResult) -> DictationSession {
    var session: DictationSession
    switch result {
    case .confirmed:
      session = insertingSession(text: resultText(result))
      _ = session.transition(.insertionFinished(generation: 0, outcome: .confirmed, reason: nil))
    case .attempted:
      session = insertingSession(text: resultText(result))
      _ = session.transition(.insertionFinished(generation: 0, outcome: .attempted, reason: nil))
    case .rejected(_, let reason):
      session = insertingSession(text: resultText(result))
      _ = session.transition(.insertionFinished(generation: 0, outcome: .rejected, reason: reason))
    case .timedOut:
      session = readySession()
      _ = makePending(in: &session, itemID: "item")
      _ = session.transition(.server(.transcriptDelta(itemID: "item", delta: resultText(result))))
      _ = session.transition(.finalizingTimedOut(generation: 0))
    case .error(let message, _):
      session = readySession()
      _ = session.transition(.localError(message: message))
    }
    return session
  }

  func resultText(_ result: DictationSession.PresentedResult) -> String {
    switch result {
    case .confirmed(let text), .attempted(let text), .timedOut(let text): text
    case .rejected(let text, _), .error(_, let text): text
    }
  }
}

extension DictationSessionTests {
  func testDeltasWhileListeningPreviewLiveAndCarryTheItemIntoPending() {
    var session = readySession()
    _ = session.transition(.pressed)

    XCTAssertEqual(
      session.transition(.server(.transcriptDelta(itemID: "live", delta: "Ship the "))),
      []
    )
    XCTAssertEqual(session.listening?.transcript, "Ship the ")
    XCTAssertEqual(session.presentation?.transcript, "Ship the ")

    _ = session.transition(.server(.transcriptDelta(itemID: "other", delta: "noise")))
    XCTAssertEqual(session.listening?.transcript, "Ship the ")

    _ = session.transition(.released(heldDuration: 1))
    XCTAssertEqual(session.pending.first?.itemID, "live")
    _ = session.transition(.server(.inputCommitted(itemID: "live")))
    _ = session.transition(.server(.transcriptDelta(itemID: "live", delta: "release")))
    XCTAssertEqual(session.pending.first?.transcript, "Ship the release")
    XCTAssertEqual(
      session.transition(.server(.transcriptCompleted(itemID: "live", transcript: "Ship the release."))).last,
      .insert(generation: 0, text: "Ship the release.")
    )
  }

  func testConnectionLossWhileListeningResetsTheLiveItemAndPartialText() {
    var session = readySession()
    _ = session.transition(.pressed)
    _ = session.transition(.server(.transcriptDelta(itemID: "live", delta: "hello")))

    _ = session.transition(.connectionLost(message: "lost"))
    XCTAssertNil(session.listening?.itemID)
    XCTAssertEqual(session.listening?.transcript, "")

    _ = session.transition(.reconnectDelayElapsed(attempt: 1))
    _ = session.transition(.sessionReady)
    _ = session.transition(.server(.transcriptDelta(itemID: "replayed", delta: "hello again")))
    XCTAssertEqual(session.listening?.itemID, "replayed")
    XCTAssertEqual(session.listening?.transcript, "hello again")
  }
}
