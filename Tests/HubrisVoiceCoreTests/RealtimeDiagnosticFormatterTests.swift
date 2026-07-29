import Foundation
import XCTest

@testable import HubrisVoiceCore

final class RealtimeDiagnosticFormatterTests: XCTestCase {
  func testErrorSummaryIncludesDomainCodeAndSingleLineMessage() {
    let error = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorNetworkConnectionLost,
      userInfo: [
        NSLocalizedDescriptionKey: "Socket disconnected\nwhile sending"
      ]
    )

    XCTAssertEqual(
      RealtimeDiagnosticFormatter.errorSummary(error),
      "NSURLErrorDomain(-1005): Socket disconnected while sending"
    )
  }

  func testSanitizeRemovesControlCharactersAndBoundsLength() {
    let value = "opened\u{0000}\twith\r\nprotocol " + String(repeating: "x", count: 5000)
    let sanitized = RealtimeDiagnosticFormatter.sanitize(value)

    XCTAssertFalse(sanitized.contains("\u{0000}"))
    XCTAssertFalse(sanitized.contains("\t"))
    XCTAssertFalse(sanitized.contains("\r"))
    XCTAssertFalse(sanitized.contains("\n"))
    XCTAssertLessThanOrEqual(sanitized.count, 2000)
    XCTAssertTrue(sanitized.hasPrefix("opened with protocol "))
  }

  func testSanitizeRedactsAPIKeyAndBearerTokens() {
    XCTAssertEqual(
      RealtimeDiagnosticFormatter.sanitize(
        "Authorization: Bearer sk-proj-abcdefghijklmnopqrstuvwxyz"
      ),
      "Authorization: Bearer <redacted>"
    )
    XCTAssertEqual(
      RealtimeDiagnosticFormatter.sanitize(
        "unexpected token sk-abcdefghijklmnopqrstuvwxyz"
      ),
      "unexpected token <redacted-api-key>"
    )
  }
}
