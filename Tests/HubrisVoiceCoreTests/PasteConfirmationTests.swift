@testable import HubrisVoiceCore
import XCTest

final class PasteConfirmationTests: XCTestCase {
  func testExactInsertionAtCaretConfirms() {
    XCTAssertEqual(
      outcome(before: state("Hello", location: 5), after: state("Hello world", location: 11), expected: " world"),
      .confirmed
    )
  }

  func testCaretMoveWithoutTextChangeIsAttempted() {
    XCTAssertEqual(
      outcome(before: state("Hello", location: 1), after: state("Hello", location: 4), expected: "ell"),
      .attempted
    )
  }

  func testTextInsertedElsewhereIsAttempted() {
    XCTAssertEqual(
      outcome(before: state("Hello", location: 5), after: state(" worldHello", location: 11), expected: " world"),
      .attempted
    )
  }

  func testMissingStatesAreAttempted() {
    let known = state("Hello", location: 5)
    XCTAssertEqual(PasteConfirmation.outcome(before: nil, after: known, expected: " world"), .attempted)
    XCTAssertEqual(PasteConfirmation.outcome(before: known, after: nil, expected: " world"), .attempted)
    XCTAssertEqual(
      PasteConfirmation.outcome(
        before: AccessibleTextState(value: nil, selectionLocation: 5, selectionLength: 0),
        after: known,
        expected: " world"
      ),
      .attempted
    )
  }

  func testUnknownLocationRequiresExactGrowthAndContainment() {
    let before = state("Hello", location: nil)
    XCTAssertEqual(
      outcome(before: before, after: state("Hello world", location: nil), expected: " world"),
      .confirmed
    )
    XCTAssertEqual(
      outcome(before: before, after: state("Hello world!", location: nil), expected: " world"),
      .attempted
    )
    XCTAssertEqual(
      outcome(before: before, after: state("Hello there", location: nil), expected: " world"),
      .attempted
    )
  }

  func testSelectionReplacementConfirms() {
    XCTAssertEqual(
      outcome(
        before: state("Hello earth", location: 6, length: 5),
        after: state("Hello world", location: 11),
        expected: "world"
      ),
      .confirmed
    )
  }

  private func state(
    _ value: String,
    location: Int?,
    length: Int? = 0
  ) -> AccessibleTextState {
    AccessibleTextState(
      value: value,
      selectionLocation: location,
      selectionLength: length
    )
  }

  private func outcome(
    before: AccessibleTextState,
    after: AccessibleTextState,
    expected: String
  ) -> PasteOutcome {
    PasteConfirmation.outcome(before: before, after: after, expected: expected)
  }
}
