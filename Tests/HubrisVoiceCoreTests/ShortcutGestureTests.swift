@testable import HubrisVoiceCore
import XCTest

final class ShortcutGestureTests: XCTestCase {
  func testChordPressRepeatAndRelease() {
    var gesture = ShortcutGesture(binding: .chord(.pushToTalkDefault))

    XCTAssertEqual(key(&gesture, down: true), .pressed)
    XCTAssertTrue(gesture.isHeld)
    XCTAssertEqual(key(&gesture, down: true, repeat: true), .consumed)
    XCTAssertEqual(key(&gesture, down: false, modifiers: []), .released)
    XCTAssertFalse(gesture.isHeld)
  }

  func testModifierPressesWhenFlagIsSetAndReleasesWhenCleared() {
    var gesture = ShortcutGesture(binding: .modifier(.fn))

    XCTAssertEqual(gesture.handleFlagsChanged(keyCode: 63, modifiers: [.fn]), .pressed)
    XCTAssertEqual(gesture.handleFlagsChanged(keyCode: 63, modifiers: [.fn]), .ignored)
    XCTAssertEqual(gesture.handleFlagsChanged(keyCode: 63, modifiers: []), .released)
  }

  func testLeftCommandChangesDoNotReleaseRightCommand() {
    var gesture = ShortcutGesture(binding: .modifier(.rightCommand))

    XCTAssertEqual(gesture.handleFlagsChanged(keyCode: 54, modifiers: [.command]), .pressed)
    XCTAssertEqual(gesture.handleFlagsChanged(keyCode: 55, modifiers: [.command]), .ignored)
    XCTAssertEqual(gesture.handleFlagsChanged(keyCode: 55, modifiers: [.command]), .ignored)
    XCTAssertTrue(gesture.isHeld)
    XCTAssertEqual(gesture.handleFlagsChanged(keyCode: 54, modifiers: []), .released)
  }

  func testRightCommandReleaseWhileLeftCommandRemainsHeldDoesNotStick() {
    var gesture = ShortcutGesture(binding: .modifier(.rightCommand))
    _ = gesture.handleFlagsChanged(keyCode: 54, modifiers: [.command])
    _ = gesture.handleFlagsChanged(keyCode: 55, modifiers: [.command])

    XCTAssertEqual(
      gesture.handleFlagsChanged(keyCode: 54, modifiers: [.command]),
      .released
    )
    XCTAssertFalse(gesture.isHeld)
    XCTAssertEqual(gesture.handleFlagsChanged(keyCode: 55, modifiers: []), .ignored)
  }

  func testOtherKeyCancelsHeldModifierWithoutOwningTheKeyEvent() {
    var gesture = ShortcutGesture(binding: .modifier(.rightCommand))
    _ = gesture.handleFlagsChanged(keyCode: 54, modifiers: [.command])

    XCTAssertEqual(
      gesture.handleKey(
        isKeyDown: true,
        keyCode: 0,
        modifiers: [.command],
        isRepeat: false
      ),
      .cancelled
    )
    XCTAssertFalse(gesture.isHeld)
    XCTAssertEqual(gesture.handleFlagsChanged(keyCode: 54, modifiers: []), .ignored)
  }

  func testCancelWhenNotHeldIsIgnored() {
    var gesture = ShortcutGesture(binding: .modifier(.fn))

    XCTAssertEqual(gesture.cancel(), .ignored)
  }

  func testFlagsChangedOnChordIsIgnored() {
    var gesture = ShortcutGesture(binding: .chord(.pushToTalkDefault))

    XCTAssertEqual(
      gesture.handleFlagsChanged(keyCode: 59, modifiers: [.control]),
      .ignored
    )
  }

  func testChordIgnoresUnrelatedEventsAndCanBeCancelled() {
    var gesture = ShortcutGesture(binding: .chord(.pushToTalkDefault))

    XCTAssertEqual(key(&gesture, down: true, keyCode: 36), .ignored)
    XCTAssertEqual(key(&gesture, down: false), .ignored)
    XCTAssertEqual(key(&gesture, down: true), .pressed)
    XCTAssertEqual(gesture.cancel(), .cancelled)
  }

  private func key(
    _ gesture: inout ShortcutGesture,
    down: Bool,
    keyCode: UInt16 = 49,
    modifiers: KeyModifiers = [.control, .shift],
    repeat isRepeat: Bool = false
  ) -> ShortcutGesture.Action {
    gesture.handleKey(
      isKeyDown: down,
      keyCode: keyCode,
      modifiers: modifiers,
      isRepeat: isRepeat
    )
  }
}
