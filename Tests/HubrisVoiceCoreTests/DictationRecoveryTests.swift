@testable import HubrisVoiceCore
import XCTest

final class DictationRecoveryTests: XCTestCase {
  func testRetiredItemsCannotBeAdoptedByAnotherRecording() {
    for shouldCancel in [true, false] {
      var session = readySession()
      _ = session.transition(.pressed)
      _ = session.transition(.released(heldDuration: 1))
      _ = session.transition(.server(.inputCommitted(itemID: "old")))
      _ = session.transition(shouldCancel ? .cancelRequested : .finalizingTimedOut(generation: 0))
      _ = session.transition(.pressed)
      _ = session.transition(.server(.transcriptDelta(itemID: "old", delta: "Old")))
      XCTAssertNil(session.listening?.itemID)
      _ = session.transition(.server(.transcriptDelta(itemID: "new", delta: "New")))
      XCTAssertEqual(session.listening?.transcript, "New")
      _ = session.transition(.released(heldDuration: 1))
      XCTAssertEqual(session.transition(.server(.transcriptCompleted(itemID: "old", transcript: "Old text"))), [])
      _ = session.transition(.server(.inputCommitted(itemID: "new")))
      XCTAssertTrue(session.transition(.server(.transcriptCompleted(itemID: "new", transcript: "New text")))
        .contains(.insert(generation: 1, text: "New text")))
    }
  }

  func testDeliveryFailureKeepsTranscriptForRecovery() {
    var session = readySession()
    _ = session.transition(.pasteLastRequested(text: "Recover me"))
    _ = session.transition(.insertionFinished(generation: 0, outcome: .rejected, reason: .deliveryFailed))
    XCTAssertEqual(session.presentation?.transcript, "Recover me")
    XCTAssertEqual(session.presentation?.message, "Could not send paste")
    XCTAssertEqual(session.presentation?.mode, .attention)
  }

  func testLateAcknowledgementCannotInsertCancelledOrTimedOutText() {
    for shouldCancel in [true, false] {
      var session = readySession()
      _ = session.transition(.pressed)
      _ = session.transition(.released(heldDuration: 1))
      _ = session.transition(shouldCancel ? .cancelRequested : .finalizingTimedOut(generation: 0))
      _ = session.transition(.pressed)
      _ = session.transition(.released(heldDuration: 1))
      _ = session.transition(.server(.inputCommitted(itemID: "old")))
      XCTAssertEqual(session.transition(.server(.transcriptCompleted(itemID: "old", transcript: "Old text"))), [])
      XCTAssertEqual(session.pending.map(\.generation), [1])
      _ = session.transition(.server(.inputCommitted(itemID: "new")))
      XCTAssertTrue(session.transition(.server(.transcriptCompleted(itemID: "new", transcript: "New text")))
        .contains(.insert(generation: 1, text: "New text")))
    }
  }

  private func readySession() -> DictationSession {
    var session = DictationSession(hasKey: true)
    _ = session.transition(.connectRequested(force: false))
    _ = session.transition(.sessionReady)
    return session
  }
}
