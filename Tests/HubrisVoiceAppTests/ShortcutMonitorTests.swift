import CoreGraphics
@testable import HubrisVoiceApp
import XCTest

final class ShortcutMonitorTests: XCTestCase {
  func testSuspensionPassesThroughChordsAndClearsHeldState() throws {
    let monitor = ShortcutMonitor()
    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
    event.flags = [.maskControl, .maskShift]
    XCTAssertTrue(monitor.process(type: .keyDown, event: event))
    monitor.isSuspended = true
    XCTAssertFalse(monitor.process(type: .keyDown, event: event))
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    XCTAssertFalse(monitor.process(type: .keyDown, event: event))
    XCTAssertFalse(monitor.process(type: .keyUp, event: event))
    monitor.isSuspended = false
    XCTAssertFalse(monitor.process(type: .keyUp, event: event))
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    XCTAssertTrue(monitor.process(type: .keyDown, event: event))
  }
}
