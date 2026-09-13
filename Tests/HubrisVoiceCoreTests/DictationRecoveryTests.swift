@testable import HubrisVoiceCore
import XCTest

// `id` consistently means a transcription invocation identity in these tests.
// swiftlint:disable identifier_name

final class DictationRecoveryTests: XCTestCase {
  func testCancelledAndTimedOutResultsCannotInsertIntoLaterRecording() throws {
    for cancel in [true, false] {
      var session = DictationSession(epoch: .init(2), readiness: .ready)
      _ = session.transition(.pressed)
      let oldID = try XCTUnwrap(session.listening?.id)
      _ = session.transition(.released(heldDuration: 1))
      _ = session.transition(cancel ? .cancelRequested : .finalizingTimedOut(generation: 0))
      _ = session.transition(.pressed)
      let newID = try XCTUnwrap(session.listening?.id)
      _ = session.transition(.released(heldDuration: 1))

      XCTAssertEqual(final(&session, id: oldID, text: "Old text"), [])
      XCTAssertTrue(final(&session, id: newID, text: "New text").contains(
        .insert(generation: 1, text: "New text")
      ))
    }
  }

  func testGlobalFailureFromRetiredEpochIsIgnored() {
    var session = DictationSession(epoch: .init(4), readiness: .ready)
    _ = session.transition(.engine(.failure(
      epoch: .init(3),
      id: nil,
      failure: .init(kind: .transport, message: "old", isRecoverable: true)
    )))
    XCTAssertNil(session.presented)
  }

  func testDeliveryFailureKeepsTranscriptForRecovery() {
    var session = DictationSession(readiness: .ready)
    _ = session.transition(.pasteLastRequested(text: "Recover me"))
    _ = session.transition(.insertionFinished(
      generation: 0,
      outcome: .rejected,
      reason: .deliveryFailed
    ))
    XCTAssertEqual(session.presentation?.transcript, "Recover me")
    XCTAssertEqual(session.presentation?.message, "Could not send paste")
  }

  private func final(
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
