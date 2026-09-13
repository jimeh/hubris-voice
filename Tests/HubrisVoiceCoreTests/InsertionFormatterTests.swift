@testable import HubrisVoiceCore
import XCTest

final class InsertionFormatterTests: XCTestCase {
  private let options = InsertionFormatter.Options()

  func testLeadingSpaceAfterWord() {
    XCTAssertEqual(format("world", before: "Hello", after: ""), " world ")
  }

  func testNoLeadingSpaceAfterWhitespaceOrOpeningCharacter() {
    for textBeforeCaret in ["Hello ", "Hello\n", "(", "[", "{", "\"", "'", "“", "‘"] {
      XCTAssertEqual(format("world", before: textBeforeCaret, after: ","), "world")
    }
  }

  func testNoLeadingSpaceWithoutContext() {
    XCTAssertEqual(format("Hello", before: nil, after: nil), "Hello ")
  }

  func testTrailingSpaceAtEndAndBeforeText() {
    XCTAssertEqual(format("Hello", before: "", after: ""), "Hello ")
    XCTAssertEqual(format("Hello", before: "", after: "world"), "Hello ")
  }

  func testNoTrailingSpaceBeforeWhitespaceOrClosingPunctuation() {
    for textAfterCaret in [" world", "\nworld", ".", ",", ";", ":", "!", "?", ")", "]", "}"] {
      XCTAssertEqual(format("Hello", before: "", after: textAfterCaret), "Hello")
    }
  }

  func testCaseAdjustmentIsOffByDefault() {
    XCTAssertEqual(format("Hello", before: "Earlier,", after: "."), " Hello")
  }

  func testCaseAdjustmentLowercasesAfterComma() {
    let adjusted = InsertionFormatter.Options(adjustCaseAfterComma: true)
    XCTAssertEqual(format("Hello there", before: "Earlier,  ", after: ".", options: adjusted), "hello there")
  }

  func testCaseAdjustmentPreservesIProtectedTermsAndInternalUppercase() {
    let adjusted = InsertionFormatter.Options(
      adjustCaseAfterComma: true,
      protectedTerms: ["Hubris"]
    )
    XCTAssertEqual(format("I agree", before: "Earlier,", after: ".", options: adjusted), " I agree")
    XCTAssertEqual(format("hubris works", before: "Earlier,", after: ".", options: adjusted), " hubris works")
    XCTAssertEqual(format("OpenAI works", before: "Earlier,", after: ".", options: adjusted), " OpenAI works")
  }

  func testEmptyTranscriptStaysEmpty() {
    XCTAssertEqual(format(" \n ", before: "Hello", after: ""), "")
  }

  func testNonLatinTextPassesThroughUnchanged() {
    XCTAssertEqual(format("こんにちは", before: nil, after: "."), "こんにちは")
  }

  private func format(
    _ transcript: String,
    before: String?,
    after: String?,
    options: InsertionFormatter.Options? = nil
  ) -> String {
    InsertionFormatter.format(
      transcript,
      context: .init(textBeforeCaret: before, textAfterCaret: after),
      options: options ?? self.options
    )
  }
}
