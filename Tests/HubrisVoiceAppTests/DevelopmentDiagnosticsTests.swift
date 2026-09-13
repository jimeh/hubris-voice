@testable import HubrisVoiceApp
import XCTest

final class DevelopmentDiagnosticsTests: XCTestCase {
  func testDisabledWithoutExplicitFlag() {
    XCTAssertFalse(DevelopmentDiagnostics.enabled("--development-trace", arguments: ["HubrisVoice"]))
  }

  func testFlagMustMatchExactly() {
    XCTAssertFalse(DevelopmentDiagnostics.enabled(
      "--development-trace", arguments: ["HubrisVoice", "--unrelated-option"]
    ))
    XCTAssertFalse(DevelopmentDiagnostics.enabled(
      "--development-trace", arguments: ["HubrisVoice", "--development-trace=true"]
    ))
  }

  func testExplicitFlagOnlyWorksInDebugBuilds() {
    let enabled = DevelopmentDiagnostics.enabled(
      "--development-trace", arguments: ["HubrisVoice", "--development-trace"]
    )
    #if DEBUG
      XCTAssertTrue(enabled)
    #else
      XCTAssertFalse(enabled)
    #endif
  }
}
