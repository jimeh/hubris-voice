import AppKit
import ApplicationServices
import Foundation
import HubrisVoiceCore

struct CapturedFocus {
  let snapshot: FocusSnapshot
  let element: AXUIElement?
}

@MainActor
final class TextInsertionService {
  func captureFocusedTarget() -> CapturedFocus? {
    guard
      let application = NSWorkspace.shared.frontmostApplication
    else {
      return nil
    }

    let processID = application.processIdentifier
    let applicationElement = AXUIElementCreateApplication(processID)
    var focusedElement = copyAXElement(
      attribute: kAXFocusedUIElementAttribute,
      from: applicationElement
    )
    if focusedElement == nil {
      AXUIElementSetAttributeValue(
        applicationElement,
        "AXManualAccessibility" as CFString,
        kCFBooleanTrue
      )
      focusedElement = copyAXElement(
        attribute: kAXFocusedUIElementAttribute,
        from: applicationElement
      )
    }

    return CapturedFocus(
      snapshot: FocusSnapshot(
        processID: processID,
        elementToken: focusedElement.map {
          token(for: $0, processID: processID)
        },
        isSecure: focusedElement.map(isSecure) ?? false
      ),
      element: focusedElement
    )
  }

  func paste(_ text: String, into target: CapturedFocus) async
    -> PasteOutcome
  {
    guard
      let current = captureFocusedTarget()
    else {
      return .rejected
    }

    let decision = PasteSafety.decision(
      captured: target.snapshot,
      current: current.snapshot
    )
    guard decision != .rejected else {
      return .rejected
    }
    if decision == .exactElement {
      guard
        let targetElement = target.element,
        let currentElement = current.element,
        CFEqual(targetElement, currentElement)
      else {
        return .rejected
      }
    }

    let beforeState = current.element.flatMap(accessibleTextState)
    let pasteboard = NSPasteboard.general
    let previousContents = PasteboardSnapshot(pasteboard: pasteboard)
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      previousContents.restore(to: pasteboard)
      return .rejected
    }
    let dictatedChangeCount = pasteboard.changeCount

    guard
      let eventSource = CGEventSource(stateID: .combinedSessionState),
      let keyDown = CGEvent(
        keyboardEventSource: eventSource,
        virtualKey: 9,
        keyDown: true
      ),
      let keyUp = CGEvent(
        keyboardEventSource: eventSource,
        virtualKey: 9,
        keyDown: false
      )
    else {
      previousContents.restore(to: pasteboard)
      return .rejected
    }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)

    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(700))
      if pasteboard.changeCount == dictatedChangeCount {
        previousContents.restore(to: pasteboard)
      }
    }

    try? await Task.sleep(for: .milliseconds(200))
    let afterState = current.element.flatMap(accessibleTextState)
    return PasteConfirmation.outcome(
      before: beforeState,
      after: afterState
    )
  }

  func copy(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  private func copyAXElement(
    attribute: String,
    from element: AXUIElement
  ) -> AXUIElement? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
      )
      == .success,
      let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private func stringAttribute(
    _ attribute: String,
    from element: AXUIElement
  ) -> String? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
      )
      == .success
    else {
      return nil
    }
    return value as? String
  }

  private func rangeAttribute(
    _ attribute: String,
    from element: AXUIElement
  ) -> CFRange? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
      )
      == .success,
      let value,
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }

    let rangeValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(rangeValue) == .cfRange else {
      return nil
    }
    var range = CFRange()
    guard AXValueGetValue(rangeValue, .cfRange, &range) else {
      return nil
    }
    return range
  }

  private func accessibleTextState(
    for element: AXUIElement
  ) -> AccessibleTextState? {
    let value = stringAttribute(kAXValueAttribute, from: element)
    let selection = rangeAttribute(
      kAXSelectedTextRangeAttribute,
      from: element
    )
    guard value != nil || selection != nil else {
      return nil
    }
    return AccessibleTextState(
      value: value,
      selectionLocation: selection?.location,
      selectionLength: selection?.length
    )
  }

  private func token(
    for element: AXUIElement,
    processID: pid_t
  ) -> String {
    if let identifier = stringAttribute(
      kAXIdentifierAttribute,
      from: element
    ), !identifier.isEmpty {
      return "\(processID):\(identifier)"
    }
    return "\(processID):\(CFHash(element))"
  }

  private func isSecure(element: AXUIElement) -> Bool {
    let subrole = stringAttribute(kAXSubroleAttribute, from: element)
    return subrole == (kAXSecureTextFieldSubrole as String)
  }
}

private struct PasteboardSnapshot: Sendable {
  private let items: [[String: Data]]

  init(pasteboard: NSPasteboard) {
    items = (pasteboard.pasteboardItems ?? []).map { item in
      Dictionary(
        uniqueKeysWithValues: item.types.compactMap { type in
          item.data(forType: type).map { (type.rawValue, $0) }
        }
      )
    }
  }

  @MainActor
  func restore(to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    let restoredItems: [NSPasteboardItem] = items.map { itemData in
      let item = NSPasteboardItem()
      for (rawType, data) in itemData {
        item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
      }
      return item
    }
    if !restoredItems.isEmpty {
      pasteboard.writeObjects(restoredItems)
    }
  }
}
