@testable import HubrisVoiceApp
import HubrisVoiceCore
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

  func testCancelledQueuedInsertionDoesNotRunAfterEarlierPasteFinishes() async throws {
    let queue = InsertionQueue()
    let (started, continuation) = AsyncStream<Void>.makeStream()
    var release: CheckedContinuation<Void, Never>?
    var inserted: [Int] = []
    var session = DictationSession(readiness: .ready)

    let first = queue.enqueue {
      await withCheckedContinuation {
        release = $0
        continuation.yield(())
      }
    }
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()

    _ = session.transition(.pasteLastRequested(text: "queued"))
    let generation = try XCTUnwrap(session.inserting.first?.generation)
    let second = queue.enqueue {
      guard session.inserting.contains(where: { $0.generation == generation }) else { return }
      _ = session.transition(.insertionStarted(generation: generation))
      inserted.append(generation)
    }

    _ = session.transition(.cancelRequested)
    release?.resume()
    await first.value
    await second.value

    XCTAssertEqual(inserted, [])
    XCTAssertTrue(session.inserting.isEmpty)
    continuation.finish()
  }
}
