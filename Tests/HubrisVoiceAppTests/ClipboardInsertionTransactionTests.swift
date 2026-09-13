import AppKit
@testable import HubrisVoiceApp
import XCTest

@MainActor
final class ClipboardInsertionTransactionTests: XCTestCase {
  func testOverlappingInsertionsRestoreTheOriginalClipboard() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("Original", forType: .string)
    let transaction = ClipboardInsertionTransaction(pasteboard: pasteboard)
    let first = try XCTUnwrap(transaction.write("First transcript"))
    let second = try XCTUnwrap(transaction.write("Second transcript"))
    XCTAssertFalse(transaction.restore(ifUnchangedSince: first))
    XCTAssertEqual(pasteboard.string(forType: .string), "Second transcript")
    XCTAssertTrue(transaction.restore(ifUnchangedSince: second))
    XCTAssertEqual(pasteboard.string(forType: .string), "Original")
  }

  func testExternalCopyBecomesTheNextOriginalAndIsNeverOverwritten() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("Original", forType: .string)
    let transaction = ClipboardInsertionTransaction(pasteboard: pasteboard)
    let first = try XCTUnwrap(transaction.write("First transcript"))
    pasteboard.clearContents()
    pasteboard.setString("User copy", forType: .string)
    let second = try XCTUnwrap(transaction.write("Second transcript"))
    XCTAssertFalse(transaction.restore(ifUnchangedSince: first))
    XCTAssertTrue(transaction.restore(ifUnchangedSince: second))
    XCTAssertEqual(pasteboard.string(forType: .string), "User copy")
    let third = try XCTUnwrap(transaction.write("Third transcript"))
    pasteboard.clearContents()
    pasteboard.setString("Latest user copy", forType: .string)
    XCTAssertFalse(transaction.restore(ifUnchangedSince: third))
    XCTAssertEqual(pasteboard.string(forType: .string), "Latest user copy")
  }
}
