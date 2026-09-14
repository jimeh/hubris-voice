@testable import HubrisVoiceCore
import XCTest

// `id` consistently means a transcription invocation identity in these tests.
// swiftlint:disable identifier_name

final class DictationSessionTests: XCTestCase {
  func testPressBeginsGenerationAddressedInvocationAtCloudFormat() {
    var session = readySession()
    let id = TranscriptionInvocationID(epoch: .init(7), generation: 0)
    let invocation = TranscriptionInvocation(id: id, format: .openAI)

    XCTAssertEqual(
      session.transition(.pressed),
      [.cancelDismiss, .beginTranscription(invocation), .startCapture(invocation)]
    )
    XCTAssertEqual(session.listening?.id, id)
  }

  func testUnavailableEngineExplainsWhyCaptureCannotStart() {
    var session = DictationSession(
      readiness: .unavailable(reason: "Model is missing.", action: "Download it in Settings.")
    )
    XCTAssertEqual(session.transition(.pressed), [.scheduleDismiss(after: .seconds(4))])
    XCTAssertEqual(
      session.presented,
      .error(message: "Model is missing. Download it in Settings.", text: "")
    )
  }

  func testPreparingAndRecoveringEnginesPermitBoundedCapture() {
    for readiness in [
      TranscriptionEngineReadiness.preparing(message: "Preparing…"),
      .recovering(message: "Recovering…"),
    ] {
      var session = DictationSession(readiness: readiness)
      XCTAssertTrue(session.transition(.pressed).contains { effect in
        if case .startCapture = effect {
          return true
        }
        return false
      })
    }
  }

  func testReleasePreservesEightSecondDeadlineAndFinishesAfterStop() throws {
    var session = readySession()
    _ = session.transition(.pressed)
    let id = try XCTUnwrap(session.listening?.id)
    XCTAssertEqual(
      session.transition(.released(heldDuration: 0.2)),
      [
        .stopCapture(generation: 0),
        .finishTranscription(id: id),
        .scheduleFinalizingTimeout(generation: 0, after: .seconds(8)),
      ]
    )
  }

  func testAccidentalTapAndCancellationRetireInvocation() throws {
    var session = readySession()
    _ = session.transition(.pressed)
    let id = try XCTUnwrap(session.listening?.id)
    XCTAssertEqual(
      session.transition(.released(heldDuration: 0.199)),
      [
        .stopCapture(generation: 0),
        .cancelTranscription(id: id),
        .discardSnippet(generation: 0),
      ]
    )
  }

  func testTapToLockFinishesOnNextPress() {
    var session = readySession(configuration: .init(tapToLock: true))
    _ = session.transition(.pressed)
    _ = session.transition(.released(heldDuration: 0.1))
    XCTAssertTrue(session.isLocked)
    XCTAssertTrue(session.transition(.pressed).contains { effect in
      if case .finishTranscription = effect {
        return true
      }
      return false
    })
  }

  func testPreviewIsAReplacementForListeningAndPendingText() throws {
    var session = readySession()
    _ = session.transition(.pressed)
    let id = try XCTUnwrap(session.listening?.id)
    _ = session.transition(.engine(.preview(id: id, text: "first")))
    _ = session.transition(.engine(.preview(id: id, text: "replacement")))
    XCTAssertEqual(session.listening?.transcript, "replacement")
    _ = session.transition(.released(heldDuration: 1))
    _ = session.transition(.engine(.preview(id: id, text: "pending replacement")))
    XCTAssertEqual(session.pending.first?.transcript, "pending replacement")
  }

  func testFinalRecordsBeforeInsertionAndDuplicateIsIgnored() throws {
    var session = try pendingSession()
    let id = try XCTUnwrap(session.pending.first?.id)
    let event = TranscriptionEngineEvent.final(
      id: id,
      result: .init(text: " hello ", correction: .disabled)
    )
    XCTAssertEqual(
      session.transition(.engine(event)),
      [
        .cancelFinalizingTimeout(generation: 0),
        .recordTranscript(generation: 0, text: "hello"),
        .insert(generation: 0, text: "hello"),
      ]
    )
    XCTAssertEqual(session.transition(.engine(event)), [])
  }

  func testPendingSnippetsCanCompleteOutOfOrder() throws {
    var session = readySession()
    _ = try makePending(in: &session)
    _ = try makePending(in: &session)
    let ids = session.pending.map(\.id)
    XCTAssertEqual(final(&session, id: ids[1], text: "two").last, .insert(generation: 1, text: "two"))
    XCTAssertEqual(final(&session, id: ids[0], text: "one").last, .insert(generation: 0, text: "one"))
  }

  func testPendingLimitRemainsFourByDefault() throws {
    var session = readySession()
    for _ in 0 ..< 4 {
      _ = try makePending(in: &session)
    }
    XCTAssertEqual(session.transition(.pressed), [.scheduleDismiss(after: .seconds(4))])
  }

  func testTimeoutRetiresGenerationAndKeepsPreviewForRecovery() throws {
    var session = try pendingSession()
    let id = try XCTUnwrap(session.pending.first?.id)
    _ = session.transition(.engine(.preview(id: id, text: "partial")))
    XCTAssertEqual(
      session.transition(.finalizingTimedOut(generation: 0)),
      [
        .cancelTranscription(id: id),
        .discardSnippet(generation: 0),
        .scheduleDismiss(after: .seconds(4)),
      ]
    )
    XCTAssertEqual(session.presented, .timedOut(text: "partial"))
    XCTAssertEqual(final(&session, id: id, text: "late"), [])
  }

  func testStaleEpochEventsCannotMutateOrInsert() throws {
    var session = try pendingSession(epoch: .init(9))
    let stale = TranscriptionInvocationID(epoch: .init(8), generation: 0)
    XCTAssertEqual(session.transition(.engine(.preview(id: stale, text: "stale"))), [])
    XCTAssertEqual(final(&session, id: stale, text: "stale"), [])
    XCTAssertEqual(session.pending.first?.transcript, "")
  }

  func testTargetedFailureKeepsPreviewAndRetiresOnlyItsGeneration() throws {
    var session = try pendingSession()
    let id = try XCTUnwrap(session.pending.first?.id)
    _ = session.transition(.engine(.preview(id: id, text: "recover me")))
    XCTAssertEqual(
      session.transition(.engine(.failure(
        epoch: id.epoch,
        id: id,
        failure: .init(kind: .transcription, message: "Rejected", isRecoverable: false)
      ))),
      [
        .cancelFinalizingTimeout(generation: 0),
        .discardSnippet(generation: 0),
        .scheduleDismiss(after: .seconds(4)),
      ]
    )
    XCTAssertEqual(session.presented, .error(message: "Rejected", text: "recover me"))
  }

  func testEngineReplacementRequiresQuiescenceAndNewerEpoch() {
    var session = readySession(epoch: .init(3))
    _ = session.transition(.pressed)
    _ = session.transition(.engineReplaced(epoch: .init(4), readiness: .ready))
    XCTAssertEqual(session.epoch, .init(3))
    _ = session.transition(.cancelRequested)
    _ = session.transition(.engineReplaced(epoch: .init(4), readiness: .ready))
    XCTAssertEqual(session.epoch, .init(4))
  }

  func testPCMFormatChangesOnlyAtQuiescentBoundary() {
    var session = readySession()
    XCTAssertTrue(session.setFormat(.local))
    let pressEffects = session.transition(.pressed)
    XCTAssertEqual(session.listening?.id.generation, 0)
    XCTAssertTrue(pressEffects.contains { effect in
      guard case .beginTranscription(let invocation) = effect else { return false }
      return invocation.format == .local
    })
    XCTAssertFalse(session.setFormat(.openAI))
    let effects = session.transition(.released(heldDuration: 1))
    XCTAssertTrue(effects.contains(.finishTranscription(id: session.pending[0].id)))
  }

  func testInsertionOutcomeAndPasteLastBehaviorRemainShared() {
    var session = readySession()
    _ = session.transition(.pasteLastRequested(text: "hello"))
    XCTAssertEqual(session.inserting.first?.transcript, "hello")
    XCTAssertEqual(
      session.transition(.insertionFinished(generation: 0, outcome: .rejected, reason: .secureField)),
      [.discardSnippet(generation: 0), .cancelDismiss, .scheduleDismiss(after: .seconds(4))]
    )
    XCTAssertEqual(session.presentation?.message, "Secure field")
  }

  func testCancellationRetiresPendingAndQueuedInsertionsButKeepsStartedInsertion() throws {
    var session = readySession()

    let startedID = try makePending(in: &session)
    _ = final(&session, id: startedID, text: "already started")
    _ = session.transition(.insertionStarted(generation: startedID.generation))

    let queuedID = try makePending(in: &session)
    _ = final(&session, id: queuedID, text: "queued")
    let pendingID = try makePending(in: &session)

    XCTAssertEqual(
      session.transition(.cancelRequested),
      [
        .cancelFinalizingTimeout(generation: pendingID.generation),
        .cancelTranscription(id: pendingID),
        .discardSnippet(generation: pendingID.generation),
        .cancelTranscription(id: queuedID),
        .discardSnippet(generation: queuedID.generation),
      ]
    )
    XCTAssertTrue(session.pending.isEmpty)
    XCTAssertEqual(session.inserting.map(\.id), [startedID])
    XCTAssertTrue(try XCTUnwrap(session.inserting.first).isInsertionStarted)
  }

  func testInsertionStartedIgnoresMissingOrRepeatedGeneration() throws {
    var session = readySession()
    let id = try makePending(in: &session)
    _ = final(&session, id: id, text: "queued")

    XCTAssertEqual(session.transition(.insertionStarted(generation: 99)), [])
    XCTAssertFalse(try XCTUnwrap(session.inserting.first).isInsertionStarted)
    XCTAssertEqual(session.transition(.insertionStarted(generation: id.generation)), [])
    XCTAssertTrue(try XCTUnwrap(session.inserting.first).isInsertionStarted)
    XCTAssertEqual(session.transition(.insertionStarted(generation: id.generation)), [])
  }
}

private extension DictationSessionTests {
  func readySession(
    configuration: DictationSession.Configuration = .init(),
    epoch: TranscriptionBackendEpoch = .init(7)
  ) -> DictationSession {
    DictationSession(configuration: configuration, epoch: epoch, readiness: .ready)
  }

  func pendingSession(epoch: TranscriptionBackendEpoch = .init(7)) throws -> DictationSession {
    var session = readySession(epoch: epoch)
    _ = try makePending(in: &session)
    return session
  }

  @discardableResult
  func makePending(in session: inout DictationSession) throws -> TranscriptionInvocationID {
    _ = session.transition(.pressed)
    let id = try XCTUnwrap(session.listening?.id)
    _ = session.transition(.released(heldDuration: 1))
    return id
  }

  func final(
    _ session: inout DictationSession,
    id: TranscriptionInvocationID,
    text: String
  ) -> [DictationSession.Effect] {
    session.transition(.engine(.final(
      id: id,
      result: .init(text: text, correction: .disabled)
    )))
  }
}

// swiftlint:enable identifier_name
