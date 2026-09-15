import AppKit
@testable import HubrisVoiceApp
import XCTest

@MainActor
final class WindowTermClassifierTests: XCTestCase {
  func testClassificationWorkIsBoundedBeforeSpellChecking() {
    let terms = (0 ..< WindowTermClassifier.maximumTerms + 10).map {
      "Identifier\($0)Value"
    }

    let evidence = WindowTermClassifier().evidence(for: terms)

    XCTAssertEqual(evidence.count, WindowTermClassifier.maximumTerms)
    XCTAssertEqual(evidence.map(\.term), Array(terms.prefix(WindowTermClassifier.maximumTerms)))
    XCTAssertTrue(evidence.allSatisfy(\.isCorrectionRepresentable))
  }

  func testLateIdentifierIsPrioritizedAheadOfOrdinaryTerms() {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
    let ordinaryTerms = (0 ..< WindowTermClassifier.maximumTerms).map {
      "ordinary\(alphabet[$0 / alphabet.count])\(alphabet[$0 % alphabet.count])"
    }
    let evidence = WindowTermClassifier().evidence(
      for: ordinaryTerms + ["AXManualAccessibility"]
    )

    XCTAssertEqual(evidence.count, WindowTermClassifier.maximumTerms)
    XCTAssertTrue(evidence.contains { $0.term == "AXManualAccessibility" })
  }
}
