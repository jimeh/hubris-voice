@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

final class RealtimeAttemptTests: XCTestCase {
  func testReplayUsesOneBoundedActionWithOrderedAudioAndFinalCommit() async throws {
    let pair = AsyncStream.makeStream(
      of: RealtimeOutboundAction.self,
      bufferingPolicy: .bufferingOldest(1)
    )
    let pipe = RealtimeOutboundPipe(continuation: pair.continuation)
    pipe.setAttempt("replay")
    let chunks = (0 ..< 600).map { Data("chunk-\($0)".utf8) }

    let receipt = try XCTUnwrap(pipe.replay(chunks, commit: true))
    var iterator = pair.stream.makeAsyncIterator()
    let maybeAction = await iterator.next()
    let action = try XCTUnwrap(maybeAction)
    let commitEventID = try XCTUnwrap(receipt.commitEventID)

    XCTAssertEqual(action.attemptID, "replay")
    XCTAssertEqual(
      action.clientEvents,
      chunks.map(RealtimeClientEvent.appendAudio)
        + [.commitAudio(eventID: commitEventID)]
    )
  }

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

  func testPreviewBurstCannotEvictControlOrTerminalEvents() async {
    let client = RealtimeTranscriptionClient()
    await client.beginAttempt("burst")
    _ = await client.receive(.sessionReady, attemptID: "burst")
    for index in 0 ..< 150 {
      _ = await client.receive(
        .transcriptDelta(itemID: "item", delta: "\(index)"),
        attemptID: "burst"
      )
    }
    _ = await client.receive(.inputCommitted(itemID: "item"), attemptID: "burst")
    _ = await client.receive(
      .transcriptCompleted(itemID: "item", transcript: "complete"),
      attemptID: "burst"
    )

    let received = await collect(153, from: client.events)
    XCTAssertEqual(received?.first, .init(attemptID: "burst", payload: .server(.sessionReady)))
    XCTAssertEqual(
      received?.suffix(2),
      [
        .init(attemptID: "burst", payload: .server(.inputCommitted(itemID: "item"))),
        .init(
          attemptID: "burst",
          payload: .server(.transcriptCompleted(itemID: "item", transcript: "complete"))
        ),
      ]
    )
  }

  private func collect(
    _ count: Int,
    from events: AsyncStream<RealtimeTransportEvent>
  ) async -> [RealtimeTransportEvent]? {
    await withTaskGroup(of: [RealtimeTransportEvent]?.self) { group in
      group.addTask {
        var iterator = events.makeAsyncIterator()
        var received: [RealtimeTransportEvent] = []
        for _ in 0 ..< count {
          guard let event = await iterator.next() else { return nil }
          received.append(event)
        }
        return received
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(1))
        return nil
      }
      guard let result = await group.next() else {
        group.cancelAll()
        return nil
      }
      group.cancelAll()
      return result
    }
  }
}
