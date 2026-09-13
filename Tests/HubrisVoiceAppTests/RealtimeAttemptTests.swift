@testable import HubrisVoiceApp
import XCTest

final class RealtimeAttemptTests: XCTestCase {
  func testRetiredReceiverAndFailureCannotAffectReplacement() async {
    let client = RealtimeTranscriptionClient()
    await client.beginAttempt("old")
    await client.beginAttempt("new")
    let acceptedOld = await client.receive(.sessionReady, attemptID: "old")
    XCTAssertFalse(acceptedOld)
    await client.reportConnectionLost(attemptID: "old", message: "obsolete error")
    let acceptedNew = await client.receive(.sessionReady, attemptID: "new")
    XCTAssertTrue(acceptedNew)
    var events = client.events.makeAsyncIterator()
    let event = await events.next()
    XCTAssertEqual(event, RealtimeTransportEvent(attemptID: "new", payload: .server(.sessionReady)))
    await client.disconnect()
    let acceptedAfterDisconnect = await client.receive(.sessionReady, attemptID: "new")
    XCTAssertFalse(acceptedAfterDisconnect)
  }

  func testAlreadyBufferedEventIsRejectedByTheModelGate() async {
    let client = RealtimeTranscriptionClient()
    await client.beginAttempt("old")
    _ = await client.receive(.inputCommitted(itemID: "old transcript"), attemptID: "old")
    await client.beginAttempt("new")
    var events = client.events.makeAsyncIterator()
    let event = await events.next()
    XCTAssertEqual(event?.belongsTo("new"), false)
    XCTAssertEqual(event?.belongsTo(nil), false)
    XCTAssertEqual(event?.belongsTo("old"), true)
  }
}
