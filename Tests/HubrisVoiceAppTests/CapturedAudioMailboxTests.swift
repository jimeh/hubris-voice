import Foundation
@testable import HubrisVoiceApp
import XCTest

final class CapturedAudioMailboxTests: XCTestCase {
  func testTransitionDrainsOldGenerationBeforeTaggingNewAudio() {
    let mailbox = CapturedAudioMailbox(capacity: 4)
    XCTAssertTrue(mailbox.transition(to: 1).isEmpty)
    XCTAssertEqual(mailbox.enqueue(Data([1])), .scheduled(generation: 1))

    XCTAssertEqual(mailbox.transition(to: 2).map(\.generation), [1])
    XCTAssertEqual(mailbox.enqueue(Data([2])), .scheduled(generation: 2))
    XCTAssertEqual(mailbox.drain().map(\.generation), [2])
  }

  func testSynchronousTailCanBeDrainedBeforeFinish() {
    let mailbox = CapturedAudioMailbox(capacity: 4)
    _ = mailbox.transition(to: 3)
    XCTAssertEqual(mailbox.enqueue(Data([1])), .scheduled(generation: 3))
    XCTAssertEqual(mailbox.enqueue(Data([2])), .queued)
    let tail = mailbox.drain()
    mailbox.deactivate(generation: 3)

    XCTAssertEqual(tail.map(\.data), [Data([1]), Data([2])])
    XCTAssertEqual(mailbox.enqueue(Data([3])), .inactive)
  }

  func testMailboxIsBounded() {
    let mailbox = CapturedAudioMailbox(capacity: 1)
    _ = mailbox.transition(to: 4)
    XCTAssertEqual(mailbox.enqueue(Data([1])), .scheduled(generation: 4))
    XCTAssertEqual(mailbox.enqueue(Data([2])), .full(generation: 4))
  }
}
