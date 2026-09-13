import Foundation
@testable import HubrisVoiceCore
import XCTest

final class ShortcutSetTests: XCTestCase {
  func testSameBindingConflictsAcrossRoles() {
    let binding = ShortcutBinding.modifier(.rightCommand)
    let shortcuts = ShortcutSet(
      pushToTalk: binding,
      pasteLastTranscript: binding
    )

    XCTAssertEqual(shortcuts.conflicts().count, 1)
    XCTAssertEqual(shortcuts.conflicts().first?.0, .pushToTalk)
    XCTAssertEqual(shortcuts.conflicts().first?.1, .pasteLastTranscript)
  }

  func testMissingPasteLastBindingDoesNotConflict() {
    XCTAssertTrue(ShortcutSet().conflicts().isEmpty)
  }

  func testCodableRoundTrip() throws {
    let expected = ShortcutSet(
      pushToTalk: .modifier(.fn),
      pasteLastTranscript: .chord(
        GlobalShortcut(keyCode: 8, modifiers: [.control, .option, .command])
      )
    )

    let data = try JSONEncoder().encode(expected)

    XCTAssertEqual(try JSONDecoder().decode(ShortcutSet.self, from: data), expected)
  }

  func testDisplayNames() {
    XCTAssertEqual(GlobalShortcut.pushToTalkDefault.displayName, "⌃⇧Space")
    XCTAssertEqual(ShortcutBinding.modifier(.fn).displayName, "Fn")
    XCTAssertEqual(ShortcutBinding.modifier(.rightCommand).displayName, "Right ⌘")
    XCTAssertEqual(
      GlobalShortcut(keyCode: 8, modifiers: [.shift, .command, .option, .control]).displayName,
      "⌃⌥⇧⌘C"
    )
    XCTAssertEqual(GlobalShortcut(keyCode: 0xab, modifiers: []).displayName, "Key 0xAB")
  }
}
