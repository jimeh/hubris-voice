import XCTest

@testable import HubrisVoiceCore

final class TranscriptAssemblerTests: XCTestCase {
  func testDeltaBuildsPreviewAndCompletedUsesAuthoritativeTranscript() {
    var assembler = TranscriptAssembler()

    assembler.apply(.transcriptDelta(itemID: "item-1", delta: "Hello"))
    assembler.apply(.transcriptDelta(itemID: "item-1", delta: " worl"))

    XCTAssertEqual(assembler.preview(for: "item-1"), "Hello worl")

    let completion = assembler.apply(
      .transcriptCompleted(itemID: "item-1", transcript: "Hello world.")
    )

    XCTAssertEqual(
      completion,
      CompletedTranscript(itemID: "item-1", text: "Hello world.")
    )
    XCTAssertEqual(assembler.preview(for: "item-1"), "Hello world.")
  }

  func testItemsRemainIndependentWhenCompletionsArriveOutOfOrder() {
    var assembler = TranscriptAssembler()

    assembler.apply(.transcriptDelta(itemID: "first", delta: "one"))
    assembler.apply(.transcriptDelta(itemID: "second", delta: "two"))

    let second = assembler.apply(
      .transcriptCompleted(itemID: "second", transcript: "two.")
    )
    let first = assembler.apply(
      .transcriptCompleted(itemID: "first", transcript: "one.")
    )

    XCTAssertEqual(second?.itemID, "second")
    XCTAssertEqual(first?.itemID, "first")
    XCTAssertEqual(assembler.preview(for: "first"), "one.")
    XCTAssertEqual(assembler.preview(for: "second"), "two.")
  }

  func testRemoveClearsOnlySpecifiedItem() {
    var assembler = TranscriptAssembler()
    assembler.apply(.transcriptDelta(itemID: "first", delta: "one"))
    assembler.apply(.transcriptDelta(itemID: "second", delta: "two"))

    assembler.remove(itemID: "first")

    XCTAssertNil(assembler.preview(for: "first"))
    XCTAssertEqual(assembler.preview(for: "second"), "two")
  }
}
