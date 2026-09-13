@testable import HubrisVoiceCore
import XCTest

final class ConfigurationUpdatePolicyTests: XCTestCase {
  private let policy = ConfigurationUpdatePolicy()

  func testAPIKeyChangeRequiresReconnect() {
    XCTAssertEqual(
      policy.decision(from: .init(), to: .init(prompt: "Changed"), apiKeyChanged: true),
      .reconnect
    )
  }

  func testPromptChangeRequiresSessionUpdate() {
    XCTAssertEqual(
      policy.decision(from: .init(), to: .init(prompt: "Changed"), apiKeyChanged: false),
      .sessionUpdate
    )
  }

  func testPlacementChangeRequiresNothing() {
    XCTAssertEqual(
      policy.decision(
        from: .init(),
        to: .init(overlayPlacement: .topOfScreen),
        apiKeyChanged: false
      ),
      .nothing
    )
  }

  func testNoChangeRequiresNothing() {
    XCTAssertEqual(policy.decision(from: .init(), to: .init(), apiKeyChanged: false), .nothing)
  }
}
