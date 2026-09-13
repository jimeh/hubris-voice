@testable import ReleaseToolCore
import XCTest

final class ReleaseVersionTests: XCTestCase {
  func testAcceptsThreeNumericComponents() {
    XCTAssertEqual(ReleaseVersion("1.23.456")?.value, "1.23.456")
  }

  func testRejectsMalformedVersions() {
    for value in ["", "1", "1.2", "v1.2.3", "1.2.3-beta", "1.a.3"] {
      XCTAssertNil(ReleaseVersion(value), "accepted \(value)")
    }
  }
}
