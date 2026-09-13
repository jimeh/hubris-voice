import CoreGraphics
import Foundation
import HubrisVoiceCore

private func shortcutEventCallback(
  proxy _: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else {
    return Unmanaged.passUnretained(event)
  }
  let monitor = Unmanaged<ShortcutMonitor>
    .fromOpaque(userInfo)
    .takeUnretainedValue()
  return monitor.process(type: type, event: event)
    ? nil
    : Unmanaged.passUnretained(event)
}

final class ShortcutMonitor: @unchecked Sendable {
  enum MonitorError: Error, LocalizedError {
    case eventTapUnavailable

    var errorDescription: String? {
      "The global shortcut could not start. Allow Accessibility and Input Monitoring for Hubris Voice."
    }
  }

  var onAction: (@Sendable (ShortcutRole, ShortcutGesture.Action) -> Void)?
  var onEscape: (@Sendable () -> Void)?
  var onTapDisabled: (@Sendable () -> Void)?

  var capturesEscape: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return isCapturingEscape
    }
    set {
      lock.lock()
      isCapturingEscape = newValue
      lock.unlock()
    }
  }

  private let lock = NSLock()
  private var gestures: [ShortcutRole: ShortcutGesture]
  private var isCapturingEscape = false
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  init(shortcuts: ShortcutSet = .init()) {
    gestures = Self.makeGestures(shortcuts)
  }

  func apply(_ shortcuts: ShortcutSet) {
    let cancelled = withLockedGestures { gestures in
      let cancelled = ShortcutRole.allCases.filter { role in
        gestures[role]?.cancel() == .cancelled
      }
      gestures = Self.makeGestures(shortcuts)
      return cancelled
    }
    for role in cancelled {
      onAction?(role, .cancelled)
    }
  }

  func cancelAll() {
    let cancelled = withLockedGestures { gestures in
      ShortcutRole.allCases.filter { role in
        gestures[role]?.cancel() == .cancelled
      }
    }
    for role in cancelled {
      onAction?(role, .cancelled)
    }
  }

  func start() throws {
    guard eventTap == nil else {
      return
    }

    let eventMask =
      (CGEventMask(1) << CGEventType.keyDown.rawValue)
        | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: shortcutEventCallback,
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
    cancelAll()
  }

  fileprivate func process(type: CGEventType, event: CGEvent) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      cancelAll()
      onTapDisabled?()
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return false
    }

    guard type == .keyDown || type == .keyUp || type == .flagsChanged else {
      return false
    }

    let keyCode = UInt16(
      event.getIntegerValueField(.keyboardEventKeycode)
    )
    let isRepeat =
      event.getIntegerValueField(
        .keyboardEventAutorepeat
      ) != 0
    if type == .keyDown, keyCode == 53, capturesEscape {
      cancelHeldModifiers(forKeyCode: keyCode, modifiers: KeyModifiers(eventFlags: event.flags))
      onEscape?()
      return true
    }
    let modifiers = KeyModifiers(eventFlags: event.flags)
    let actions = withLockedGestures { gestures in
      ShortcutRole.allCases.compactMap { role -> RoleAction? in
        guard var gesture = gestures[role] else { return nil }
        let action = if type == .flagsChanged {
          gesture.handleFlagsChanged(keyCode: keyCode, modifiers: modifiers)
        } else {
          gesture.handleKey(
            isKeyDown: type == .keyDown,
            keyCode: keyCode,
            modifiers: modifiers,
            isRepeat: isRepeat
          )
        }
        gestures[role] = gesture
        return RoleAction(role: role, binding: gesture.binding, action: action)
      }
    }
    for action in actions where action.action != .ignored && action.action != .consumed {
      onAction?(action.role, action.action)
    }
    guard type != .flagsChanged else { return false }
    return actions.contains { action in
      if case .chord = action.binding {
        return action.action != .ignored && action.action != .cancelled
      }
      return false
    }
  }

  private static func makeGestures(
    _ shortcuts: ShortcutSet
  ) -> [ShortcutRole: ShortcutGesture] {
    var gestures = [
      ShortcutRole.pushToTalk: ShortcutGesture(binding: shortcuts.pushToTalk),
    ]
    if let pasteLastTranscript = shortcuts.pasteLastTranscript {
      gestures[.pasteLastTranscript] = ShortcutGesture(binding: pasteLastTranscript)
    }
    return gestures
  }

  private func cancelHeldModifiers(
    forKeyCode keyCode: UInt16,
    modifiers: KeyModifiers
  ) {
    let actions = withLockedGestures { gestures in
      ShortcutRole.allCases.compactMap { role -> RoleAction? in
        guard var gesture = gestures[role], case .modifier = gesture.binding else {
          return nil
        }
        let action = gesture.handleKey(
          isKeyDown: true,
          keyCode: keyCode,
          modifiers: modifiers,
          isRepeat: false
        )
        gestures[role] = gesture
        return RoleAction(role: role, binding: gesture.binding, action: action)
      }
    }
    for action in actions where action.action == .cancelled {
      onAction?(action.role, .cancelled)
    }
  }

  private func withLockedGestures<T>(
    _ body: (inout [ShortcutRole: ShortcutGesture]) -> T
  ) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&gestures)
  }
}

private extension KeyModifiers {
  init(eventFlags: CGEventFlags) {
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
    if eventFlags.contains(.maskSecondaryFn) {
      modifiers.insert(.fn)
    }
    self = modifiers
  }
}

private struct RoleAction {
  let role: ShortcutRole
  let binding: ShortcutBinding
  let action: ShortcutGesture.Action
}
