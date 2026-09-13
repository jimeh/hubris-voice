@testable import HubrisVoiceApp
import XCTest

@MainActor
final class InsertionQueueTests: XCTestCase {
  func testNextInsertionWaitsUntilPasteConsumptionFinishes() async {
    let queue = InsertionQueue()
    let (started, continuation) = AsyncStream<Void>.makeStream()
    var release: CheckedContinuation<Void, Never>?
    var events: [String] = []
    let first = queue.enqueue {
      events.append("first write")
      await withCheckedContinuation {
        release = $0
        continuation.yield(())
      }
      events.append("first consumed")
    }
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    let second = queue.enqueue { events.append("second write") }
    let third = queue.enqueue { events.append("third write") }
    await Task { @MainActor in }.value
    XCTAssertEqual(events, ["first write"])
    release?.resume()
    await first.value
    await second.value
    await third.value
    XCTAssertEqual(events, ["first write", "first consumed", "second write", "third write"])
    continuation.finish()
  }
}
