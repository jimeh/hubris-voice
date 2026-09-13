@testable import HubrisVoiceCore
import XCTest

final class ReconnectPolicyTests: XCTestCase {
  func testFirstAttemptUsesInitialDelay() {
    let policy = ReconnectPolicy(initialDelay: .milliseconds(750))

    XCTAssertEqual(policy.delay(forAttempt: 1), .milliseconds(750))
  }

  func testLaterAttemptsGrowByMultiplier() {
    let policy = ReconnectPolicy(
      initialDelay: .milliseconds(500),
      multiplier: 3,
      maximumDelay: .seconds(30)
    )

    XCTAssertEqual(policy.delay(forAttempt: 2), .milliseconds(1_500))
    XCTAssertEqual(policy.delay(forAttempt: 3), .milliseconds(4_500))
  }

  func testDelayIsCappedAtMaximum() {
    let policy = ReconnectPolicy(
      initialDelay: .seconds(1),
      multiplier: 2,
      maximumDelay: .seconds(5)
    )

    XCTAssertEqual(policy.delay(forAttempt: 5), .seconds(5))
  }
}
