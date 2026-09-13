import Foundation
@testable import HubrisVoiceCore
import XCTest

final class AudioSnippetBufferTests: XCTestCase {
  func testAppendBelowCapacityStoresChunk() {
    var buffer = AudioSnippetBuffer(capacityBytes: 5)
    let chunk = Data([1, 2, 3])

    XCTAssertEqual(buffer.append(chunk), .stored)
    XCTAssertEqual(buffer.chunks, [chunk])
    XCTAssertFalse(buffer.isFull)
  }

  func testAppendBeyondCapacityReturnsFullAndDropsChunk() {
    var buffer = AudioSnippetBuffer(capacityBytes: 3)
    let stored = Data([1, 2])

    XCTAssertEqual(buffer.append(stored), .stored)
    XCTAssertEqual(buffer.append(Data([3, 4])), .full)
    XCTAssertEqual(buffer.chunks, [stored])
    XCTAssertEqual(buffer.byteCount, 2)
  }

  func testAppendAtCapacityReturnsFullAndDropsChunk() {
    var buffer = AudioSnippetBuffer(capacityBytes: 3)

    XCTAssertEqual(buffer.append(Data([1, 2, 3])), .full)
    XCTAssertTrue(buffer.chunks.isEmpty)
    XCTAssertEqual(buffer.byteCount, 0)
    XCTAssertTrue(buffer.isFull)
  }

  func testByteCountTracksStoredChunks() {
    var buffer = AudioSnippetBuffer(capacityBytes: 4)

    XCTAssertEqual(buffer.append(Data([1])), .stored)
    XCTAssertEqual(buffer.append(Data([2, 3])), .stored)
    XCTAssertEqual(buffer.byteCount, 3)
    XCTAssertFalse(buffer.isFull)
  }
}
