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

  func testPushToTalkGestureConsumesRepeatAndReleasesAfterModifiersLift() {
    var gesture = PushToTalkGesture(shortcut: .pushToTalkDefault)

    XCTAssertEqual(
      gesture.handle(
        isKeyDown: true,
        keyCode: 49,
        modifiers: [.control, .shift],
        isRepeat: false
      ),
      .pressed
    )
    XCTAssertEqual(
      gesture.handle(
        isKeyDown: true,
        keyCode: 49,
        modifiers: [.control, .shift],
        isRepeat: true
      ),
      .consumed
    )
    XCTAssertEqual(
      gesture.handle(
        isKeyDown: false,
        keyCode: 49,
        modifiers: [],
        isRepeat: false
      ),
      .released
    )
  }

  func testPushToTalkGestureIgnoresUnrelatedEvents() {
    var gesture = PushToTalkGesture(shortcut: .pushToTalkDefault)

    XCTAssertEqual(
      gesture.handle(
        isKeyDown: true,
        keyCode: 36,
        modifiers: [.control, .shift],
        isRepeat: false
      ),
      .ignored
    )
    XCTAssertEqual(
      gesture.handle(
        isKeyDown: false,
        keyCode: 49,
        modifiers: [],
        isRepeat: false
      ),
      .ignored
    )
  }

  func testPushToTalkGestureCancelWhileHeldReturnsCancelled() {
    var gesture = PushToTalkGesture(shortcut: .pushToTalkDefault)
    _ = gesture.handle(
      isKeyDown: true,
      keyCode: 49,
      modifiers: [.control, .shift],
      isRepeat: false
    )

    XCTAssertEqual(gesture.cancel(), .cancelled)
  }

  func testPushToTalkGestureCancelWhenNotHeldIsIgnored() {
    var gesture = PushToTalkGesture(shortcut: .pushToTalkDefault)

    XCTAssertEqual(gesture.cancel(), .ignored)
  }

  func testSnippetPolicyRejectsAccidentalTapAtBoundary() {
    let policy = SnippetPolicy(minimumDuration: 0.2)

    XCTAssertFalse(policy.shouldCommit(duration: 0.199))
    XCTAssertTrue(policy.shouldCommit(duration: 0.2))
  }

  func testPasteSafetyRequiresSameNonSecureFocusedElement() {
    let target = FocusSnapshot(
      processID: 100,
      elementToken: "editor-1",
      isSecure: false
    )

    XCTAssertTrue(PasteSafety.canPaste(captured: target, current: target))
    XCTAssertFalse(
      PasteSafety.canPaste(
        captured: target,
        current: FocusSnapshot(
          processID: 200,
          elementToken: "editor-1",
          isSecure: false
        )
      )
    )
    XCTAssertFalse(
      PasteSafety.canPaste(
        captured: target,
        current: FocusSnapshot(
          processID: 100,
          elementToken: "editor-2",
          isSecure: false
        )
      )
    )
    XCTAssertFalse(
      PasteSafety.canPaste(
        captured: target,
        current: FocusSnapshot(
          processID: 100,
          elementToken: "editor-1",
          isSecure: true
        )
      )
    )
  }

  func testPasteSafetyAllowsApplicationFallbackOnlyForWeakCapture() {
    let weakTarget = FocusSnapshot(
      processID: 100,
      elementToken: nil,
      isSecure: false
    )

    XCTAssertEqual(
      PasteSafety.decision(captured: weakTarget, current: weakTarget),
      .sameApplication
    )
    XCTAssertEqual(
      PasteSafety.decision(
        captured: weakTarget,
        current: FocusSnapshot(
          processID: 100,
          elementToken: "editor-1",
          isSecure: false
        )
      ),
      .sameApplication
    )
    XCTAssertEqual(
      PasteSafety.decision(
        captured: weakTarget,
        current: FocusSnapshot(
          processID: 200,
          elementToken: nil,
          isSecure: false
        )
      ),
      .rejected
    )
  }

  func testPasteSafetyRejectsChangedOrSecureStrongTargets() {
    let target = FocusSnapshot(
      processID: 100,
      elementToken: "editor-1",
      isSecure: false
    )

    XCTAssertEqual(
      PasteSafety.decision(
        captured: target,
        current: FocusSnapshot(
          processID: 100,
          elementToken: nil,
          isSecure: false
        )
      ),
      .rejected
    )
    XCTAssertEqual(
      PasteSafety.decision(
        captured: target,
        current: FocusSnapshot(
          processID: 100,
          elementToken: "editor-1",
          isSecure: true
        )
      ),
      .rejected
    )
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
