import Foundation
@testable import HubrisVoiceCore
import XCTest

final class TranscriptHistoryTests: XCTestCase {
  func testRecordKeepsNewestEntryFirst() {
    var history = TranscriptHistory()
    let first = entry(text: "first")
    let second = entry(text: "second")

    history.record(first)
    history.record(second)

    XCTAssertEqual(history.entries, [second, first])
    XCTAssertEqual(history.latest, second)
  }

  func testRecordTrimsOldestEntriesAtLimit() {
    var history = TranscriptHistory(limit: 2)
    let first = entry(text: "first")
    let second = entry(text: "second")
    let third = entry(text: "third")

    history.record(first)
    history.record(second)
    history.record(third)

    XCTAssertEqual(history.entries, [third, second])
  }

  func testUpdateChangesKnownOutcome() {
    var history = TranscriptHistory()
    let original = entry(text: "hello", outcome: .attempted)
    history.record(original)

    history.update(id: original.id, outcome: .pasted)

    XCTAssertEqual(history.latest?.outcome, .pasted)
  }

  func testUpdateWithUnknownIDDoesNothing() {
    var history = TranscriptHistory()
    let original = entry(text: "hello")
    history.record(original)

    history.update(id: UUID(), outcome: .rejected)

    XCTAssertEqual(history.entries, [original])
  }

  func testRemoveDeletesMatchingEntry() {
    var history = TranscriptHistory()
    let retained = entry(text: "retained")
    let removed = entry(text: "removed")
    history.record(retained)
    history.record(removed)

    history.remove(id: removed.id)

    XCTAssertEqual(history.entries, [retained])
  }

  func testClearDeletesEveryEntry() {
    var history = TranscriptHistory()
    history.record(entry(text: "one"))
    history.record(entry(text: "two"))

    history.clear()

    XCTAssertTrue(history.entries.isEmpty)
  }

  func testSearchIsCaseAndDiacriticInsensitive() {
    var history = TranscriptHistory()
    let other = entry(text: "Something else")
    let matching = entry(text: "Résumé ready")
    history.record(other)
    history.record(matching)

    XCTAssertEqual(history.search("RESUME"), [matching])
    XCTAssertEqual(history.search(""), [matching, other])
  }

  func testCodableRoundTrip() throws {
    var expected = TranscriptHistory(limit: 3)
    expected.record(entry(text: "hello", outcome: .rejected))

    let data = try JSONEncoder().encode(expected)

    XCTAssertEqual(try JSONDecoder().decode(TranscriptHistory.self, from: data), expected)
  }

  private func entry(
    text: String,
    outcome: TranscriptEntry.Outcome = .attempted
  ) -> TranscriptEntry {
    TranscriptEntry(
      id: UUID(),
      text: text,
      recordedAt: Date(timeIntervalSince1970: 1_000),
      targetBundleID: "com.example.Target",
      outcome: outcome
    )
  }
}
