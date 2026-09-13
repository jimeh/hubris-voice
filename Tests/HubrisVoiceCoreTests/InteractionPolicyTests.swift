@testable import HubrisVoiceCore
import XCTest

final class InteractionPolicyTests: XCTestCase {
  func testDefaultShortcutRequiresControlShiftSpace() {
    let shortcut = GlobalShortcut.pushToTalkDefault

    XCTAssertTrue(
      shortcut.matches(
        keyCode: 49,
        modifiers: [.control, .shift]
      )
    )
    XCTAssertFalse(
      shortcut.matches(
        keyCode: 49,
        modifiers: [.control]
      )
    )
    XCTAssertFalse(
      shortcut.matches(
        keyCode: 49,
        modifiers: [.control, .shift, .command]
      )
    )
    XCTAssertFalse(
      shortcut.matches(
        keyCode: 36,
        modifiers: [.control, .shift]
      )
    )
  }

  func testSnippetPolicyRejectsAccidentalTapAtBoundary() {
    let policy = SnippetPolicy(minimumDuration: 0.2)

    XCTAssertFalse(policy.shouldCommit(duration: 0.199))
    XCTAssertTrue(policy.shouldCommit(duration: 0.2))
  }

  func testPasteSafetyAllowsNonSecureFocusInAnotherProcess() {
    let current = FocusSnapshot(processID: 200, isSecure: false)

    XCTAssertTrue(PasteSafety.canPaste(current: current))
  }

  func testPasteSafetyRejectsSecureFocus() {
    let current = FocusSnapshot(processID: 200, isSecure: true)

    XCTAssertFalse(PasteSafety.canPaste(current: current))
  }

  func testSingleInstancePolicyRejectsAnotherRunningProcess() {
    XCTAssertFalse(
      SingleInstancePolicy.shouldTerminate(
        currentProcessID: 100,
        runningProcessIDs: []
      )
    )
    XCTAssertFalse(
      SingleInstancePolicy.shouldTerminate(
        currentProcessID: 100,
        runningProcessIDs: [100]
      )
    )
    XCTAssertTrue(
      SingleInstancePolicy.shouldTerminate(
        currentProcessID: 100,
        runningProcessIDs: [100, 200]
      )
    )
  }
}
