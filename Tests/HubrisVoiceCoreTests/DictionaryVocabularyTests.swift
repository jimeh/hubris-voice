@testable import HubrisVoiceCore
import XCTest

final class DictionaryVocabularyTests: XCTestCase {
  func testNormalizeTrimsDropsEmptyAndDeduplicatesCaseInsensitively() throws {
    let result = try DictionaryVocabulary.normalize([
      "  Hucode  ",
      "",
      "Treeboot",
      "hucode",
      "OpenAI Realtime",
    ])

    XCTAssertEqual(result, ["Hucode", "Treeboot", "OpenAI Realtime"])
  }

  func testNormalizeRejectsProtocolControlCharacters() {
    for invalid in ["bad\nword", "bad\rword", "<script", "word>"] {
      XCTAssertThrowsError(try DictionaryVocabulary.normalize([invalid])) { error in
        XCTAssertEqual(
          error as? DictionaryVocabulary.ValidationError,
          .invalidCharacters(invalid)
        )
      }
    }
  }

  func testNormalizeRejectsEntriesOverTheLimit() {
    let oversized = String(repeating: "a", count: 81)

    XCTAssertThrowsError(try DictionaryVocabulary.normalize([oversized])) { error in
      XCTAssertEqual(
        error as? DictionaryVocabulary.ValidationError,
        .entryTooLong(oversized)
      )
    }
  }
}
