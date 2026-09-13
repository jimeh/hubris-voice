import AppKit
import ApplicationServices
import Foundation
import HubrisVoiceCore

struct CapturedFocus {
  let snapshot: FocusSnapshot
  let applicationElement: AXUIElement
  let element: AXUIElement?
}

struct PasteResult {
  let outcome: PasteOutcome
  let reason: DictationSession.RejectionReason?
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
      applicationElement: applicationElement,
      element: focusedElement
    )
  }

  func captureAnchor(for focus: CapturedFocus?) -> OverlayAnchor? {
    guard
      let focus,
      let primaryScreenHeight = NSScreen.screens.first?.frame.height
    else {
      return nil
    }

    if
      let element = focus.element,
      let range = rangeAttribute(
        kAXSelectedTextRangeAttribute,
        from: element
      ),
      let rect = parameterizedRectAttribute(
        kAXBoundsForRangeParameterizedAttribute,
        parameter: range,
        from: element,
        primaryScreenHeight: primaryScreenHeight
      ),
      rect.size.height > 0,
      rect.size.width >= 0,
      containsCenterOnScreen(rect)
    {
      return OverlayAnchor(kind: .caret, rect: rect)
    }

    if
      let element = focus.element,
      let rect = rect(
        for: element,
        primaryScreenHeight: primaryScreenHeight
      ),
      containsCenterOnScreen(rect)
    {
      return OverlayAnchor(kind: .element, rect: rect)
    }

    if
      let window = copyAXElement(
        attribute: kAXFocusedWindowAttribute,
        from: focus.applicationElement
      ),
      let rect = rect(
        for: window,
        primaryScreenHeight: primaryScreenHeight
      ),
      containsCenterOnScreen(rect)
    {
      return OverlayAnchor(kind: .window, rect: rect)
    }

    return nil
  }

  func currentTextContext(
    for focus: CapturedFocus
  ) -> InsertionFormatter.Context {
    guard
      let element = focus.element,
      let state = accessibleTextState(for: element),
      let value = state.value,
      let location = state.selectionLocation
    else {
      return .init(textBeforeCaret: nil, textAfterCaret: nil)
    }
    let selectionLength = state.selectionLength ?? 0
    guard
      location >= 0,
      selectionLength >= 0,
      location <= value.utf16.count,
      selectionLength <= value.utf16.count - location,
      let caretIndex = stringIndex(utf16Offset: location, in: value),
      let selectionEndIndex = stringIndex(
        utf16Offset: location + selectionLength,
        in: value
      )
    else {
      return .init(textBeforeCaret: nil, textAfterCaret: nil)
    }
    return .init(
      textBeforeCaret: String(value[..<caretIndex]),
      textAfterCaret: String(value[selectionEndIndex...])
    )
  }

  func paste(
    _ text: String,
    into target: CapturedFocus,
    expected: String
  ) async -> PasteResult {
    guard let current = captureFocusedTarget() else {
      return PasteResult(
        outcome: .rejected,
        reason: target.snapshot.isSecure ? .secureField : .focusChanged
      )
    }
    return await pasteUsingClipboard(
      text,
      target: target,
      current: current,
      expected: expected
    )
  }

  func pasteAtCurrentFocus(_ text: String) async -> PasteResult {
    guard let current = captureFocusedTarget() else {
      return PasteResult(outcome: .rejected, reason: .noTarget)
    }
    guard !current.snapshot.isSecure else {
      return PasteResult(outcome: .rejected, reason: .secureField)
    }
    return await pasteUsingClipboard(
      text,
      target: current,
      current: current,
      expected: text
    )
  }

  private func pasteUsingClipboard(
    _ text: String,
    target: CapturedFocus,
    current: CapturedFocus,
    expected: String
  ) async -> PasteResult {
    let decision = PasteSafety.decision(
      captured: target.snapshot,
      current: current.snapshot
    )
    guard decision != .rejected else {
      let reason: DictationSession.RejectionReason =
        target.snapshot.isSecure || current.snapshot.isSecure
          ? .secureField
          : .focusChanged
      return PasteResult(outcome: .rejected, reason: reason)
    }
    if decision == .exactElement {
      guard
        let targetElement = target.element,
        let currentElement = current.element,
        CFEqual(targetElement, currentElement)
      else {
        return PasteResult(outcome: .rejected, reason: .focusChanged)
      }
    }

    let beforeState = current.element.flatMap(accessibleTextState)
    let pasteboard = NSPasteboard.general
    let previousContents = PasteboardSnapshot(pasteboard: pasteboard)
    pasteboard.clearContents()
    guard pasteboard.setString(text, forType: .string) else {
      previousContents.restore(to: pasteboard)
      return PasteResult(outcome: .rejected, reason: .focusChanged)
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
      return PasteResult(outcome: .rejected, reason: .focusChanged)
    }
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)

    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(1_500))
      if pasteboard.changeCount == dictatedChangeCount {
        previousContents.restore(to: pasteboard)
      }
    }

    try? await Task.sleep(for: .milliseconds(200))
    let afterState = current.element.flatMap(accessibleTextState)
    return PasteResult(
      outcome: PasteConfirmation.outcome(
        before: beforeState,
        after: afterState,
        expected: expected
      ),
      reason: nil
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

  private func parameterizedRectAttribute(
    _ attribute: String,
    parameter: CFRange,
    from element: AXUIElement,
    primaryScreenHeight: CGFloat
  ) -> LayoutRect? {
    var parameter = parameter
    guard let rangeValue = AXValueCreate(.cfRange, &parameter) else {
      return nil
    }
    var value: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element,
        attribute as CFString,
        rangeValue,
        &value
      ) == .success,
      let rect = cgRect(from: value)
    else {
      return nil
    }
    return LayoutRect.fromTopLeft(
      x: rect.origin.x,
      y: rect.origin.y,
      width: rect.size.width,
      height: rect.size.height,
      primaryScreenHeight: primaryScreenHeight
    )
  }

  private func rect(
    for element: AXUIElement,
    primaryScreenHeight: CGFloat
  ) -> LayoutRect? {
    guard
      let position = cgPointAttribute(
        kAXPositionAttribute,
        from: element
      ),
      let size = cgSizeAttribute(
        kAXSizeAttribute,
        from: element
      ),
      size.width > 0,
      size.height > 0
    else {
      return nil
    }
    return LayoutRect.fromTopLeft(
      x: position.x,
      y: position.y,
      width: size.width,
      height: size.height,
      primaryScreenHeight: primaryScreenHeight
    )
  }

  private func cgPointAttribute(
    _ attribute: String,
    from element: AXUIElement
  ) -> CGPoint? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
      ) == .success,
      let value,
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }
    let pointValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(pointValue) == .cgPoint else {
      return nil
    }
    var point = CGPoint.zero
    return AXValueGetValue(pointValue, .cgPoint, &point) ? point : nil
  }

  private func cgSizeAttribute(
    _ attribute: String,
    from element: AXUIElement
  ) -> CGSize? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
      ) == .success,
      let value,
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }
    let sizeValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(sizeValue) == .cgSize else {
      return nil
    }
    var size = CGSize.zero
    return AXValueGetValue(sizeValue, .cgSize, &size) ? size : nil
  }

  private func cgRect(from value: CFTypeRef?) -> CGRect? {
    guard
      let value,
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }
    let rectValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(rectValue) == .cgRect else {
      return nil
    }
    var rect = CGRect.zero
    return AXValueGetValue(rectValue, .cgRect, &rect) ? rect : nil
  }

  private func containsCenterOnScreen(_ rect: LayoutRect) -> Bool {
    let center = NSPoint(x: rect.midX, y: rect.midY)
    return NSScreen.screens.contains { $0.frame.contains(center) }
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

  private func stringIndex(
    utf16Offset: Int,
    in value: String
  ) -> String.Index? {
    let utf16Index = value.utf16.index(
      value.utf16.startIndex,
      offsetBy: utf16Offset
    )
    return String.Index(utf16Index, within: value)
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
