import CoreGraphics
import Foundation
import HubrisVoiceCore

private func pushToTalkEventCallback(
  proxy _: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else {
    return Unmanaged.passUnretained(event)
  }
  let monitor = Unmanaged<PushToTalkMonitor>
    .fromOpaque(userInfo)
    .takeUnretainedValue()
  return monitor.process(type: type, event: event)
    ? nil
    : Unmanaged.passUnretained(event)
}

final class PushToTalkMonitor: @unchecked Sendable {
  enum MonitorError: Error, LocalizedError {
    case eventTapUnavailable

    var errorDescription: String? {
      "The global shortcut could not start. Allow Accessibility and Input Monitoring for Hubris Voice."
    }
  }

  var onPress: (@Sendable () -> Void)?
  var onRelease: (@Sendable () -> Void)?

  private let shortcut: GlobalShortcut
  private let lock = NSLock()
  private var gesture: PushToTalkGesture
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  init(shortcut: GlobalShortcut = .pushToTalkDefault) {
    self.shortcut = shortcut
    gesture = PushToTalkGesture(shortcut: shortcut)
  }

  func start() throws {
    guard eventTap == nil else {
      return
    }

    let eventMask =
      (CGEventMask(1) << CGEventType.keyDown.rawValue)
      | (CGEventMask(1) << CGEventType.keyUp.rawValue)
    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: pushToTalkEventCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      throw MonitorError.eventTapUnavailable
    }

    let source = CFMachPortCreateRunLoopSource(
      kCFAllocatorDefault,
      eventTap,
      0
    )
    self.eventTap = eventTap
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
  }

  func stop() {
    guard let eventTap else {
      return
    }
    if let runLoopSource {
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(),
        runLoopSource,
        .commonModes
      )
    }
    CFMachPortInvalidate(eventTap)
    self.eventTap = nil
    runLoopSource = nil
    handle(action: withLockedGesture { $0.cancel() })
  }

  fileprivate func process(type: CGEventType, event: CGEvent) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      handle(action: withLockedGesture { $0.cancel() })
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return false
    }

    guard type == .keyDown || type == .keyUp else {
      return false
    }

    let keyCode = UInt16(
      event.getIntegerValueField(.keyboardEventKeycode)
    )
    let modifiers = KeyModifiers(eventFlags: event.flags)
    let isRepeat =
      event.getIntegerValueField(
        .keyboardEventAutorepeat
      ) != 0
    let action = withLockedGesture {
      $0.handle(
        isKeyDown: type == .keyDown,
        keyCode: keyCode,
        modifiers: modifiers,
        isRepeat: isRepeat
      )
    }
    handle(action: action)
    return action != .ignored
  }

  private func handle(action: PushToTalkGesture.Action) {
    switch action {
    case .pressed:
      onPress?()
    case .released:
      onRelease?()
    case .ignored, .consumed:
      break
    }
  }

  private func withLockedGesture<T>(
    _ body: (inout PushToTalkGesture) -> T
  ) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&gesture)
  }
}

extension KeyModifiers {
  fileprivate init(eventFlags: CGEventFlags) {
    var modifiers: KeyModifiers = []
    if eventFlags.contains(.maskControl) {
      modifiers.insert(.control)
    }
    if eventFlags.contains(.maskShift) {
      modifiers.insert(.shift)
    }
    if eventFlags.contains(.maskCommand) {
      modifiers.insert(.command)
    }
    if eventFlags.contains(.maskAlternate) {
      modifiers.insert(.option)
    }
    self = modifiers
  }
}
