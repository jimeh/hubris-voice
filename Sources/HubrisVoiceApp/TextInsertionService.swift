import AppKit
import ApplicationServices
import Foundation
import HubrisVoiceCore

struct CapturedFocus {
  let snapshot: FocusSnapshot
  let element: AXUIElement
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
    guard
      let focusedElement = copyAXElement(
        attribute: kAXFocusedUIElementAttribute,
        from: applicationElement
      )
    else {
      return nil
    }

    return CapturedFocus(
      snapshot: FocusSnapshot(
        processID: processID,
        elementToken: token(for: focusedElement, processID: processID),
        isSecure: isSecure(element: focusedElement)
      ),
      element: focusedElement
    )
  }

  func paste(_ text: String, into target: CapturedFocus) -> Bool {
    guard
      let current = captureFocusedTarget(),
      PasteSafety.canPaste(
        captured: target.snapshot,
        current: current.snapshot
      ),
      CFEqual(target.element, current.element)
    else {
      return false
    }

    let pasteboard = NSPasteboard.general
    let previousContents = PasteboardSnapshot(pasteboard: pasteboard)
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      previousContents.restore(to: pasteboard)
      return false
    }
    let dictatedChangeCount = pasteboard.changeCount

    guard let eventSource = CGEventSource(stateID: .combinedSessionState) else {
      previousContents.restore(to: pasteboard)
      return false
    }
    let keyDown = CGEvent(
      keyboardEventSource: eventSource,
      virtualKey: 9,
      keyDown: true
    )
    let keyUp = CGEvent(
      keyboardEventSource: eventSource,
      virtualKey: 9,
      keyDown: false
    )
    keyDown?.flags = .maskCommand
    keyUp?.flags = .maskCommand
    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)

    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(700))
      if pasteboard.changeCount == dictatedChangeCount {
        previousContents.restore(to: pasteboard)
      }
    }
    return true
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
