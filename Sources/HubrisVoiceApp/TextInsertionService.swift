import AppKit
import ApplicationServices
import Foundation
import HubrisVoiceCore

struct CapturedFocus {
  let snapshot: FocusSnapshot
  let targetBundleID: String?
  let applicationElement: AXUIElement
  let element: AXUIElement?
}

struct PasteResult {
  let outcome: PasteOutcome
  let reason: DictationSession.RejectionReason?
}

@MainActor
final class TextInsertionService {
  /// Direct Accessibility writes avoid the clipboard and give a real
  /// confirmation, but not every field honors them. Settings can force the
  /// clipboard path for targets where the direct write misbehaves.
  var allowsDirectInsertion = true

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
      targetBundleID: application.bundleIdentifier,
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
    return await insert(
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
    return await insert(
      text,
      target: current,
      current: current,
      expected: text
    )
  }

  /// Applies the focus guard, then tries direct Accessibility insertion
  /// before falling back to a clipboard paste. An ambiguous direct write is
  /// final: it is never followed by a clipboard paste, so one snippet can
  /// never be inserted twice.
  private func insert(
    _ text: String,
    target: CapturedFocus,
    current: CapturedFocus,
    expected: String
  ) async -> PasteResult {
    if let rejection = focusRejection(target: target, current: current) {
      return rejection
    }

    if
      allowsDirectInsertion,
      let element = current.element,
      let direct = await insertDirectly(text, into: element, expected: expected)
    {
      return direct
    }

    return await pasteUsingClipboard(
      text,
      current: current,
      expected: expected
    )
  }

  private func focusRejection(
    target: CapturedFocus,
    current: CapturedFocus
  ) -> PasteResult? {
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
    return nil
  }

  /// Returns nil only when the element cannot take a direct write at all
  /// (attribute not settable, no readable value, or the write failed
  /// without changing anything), which is the only case where the clipboard
  /// fallback is safe.
  private func insertDirectly(
    _ text: String,
    into element: AXUIElement,
    expected: String
  ) async -> PasteResult? {
    var settable = DarwinBoolean(false)
    guard
      AXUIElementIsAttributeSettable(
        element,
        kAXSelectedTextAttribute as CFString,
        &settable
      ) == .success,
      settable.boolValue,
      let before = accessibleTextState(for: element),
      before.value != nil
    else {
      return nil
    }

    let status = AXUIElementSetAttributeValue(
      element,
      kAXSelectedTextAttribute as CFString,
      text as CFTypeRef
    )
    try? await Task.sleep(for: .milliseconds(50))
    let after = accessibleTextState(for: element)
    if status != .success, after == before {
      Task {
        await DiagnosticLog.shared.record(
          "insert path=direct status=\(status.rawValue) unchanged; falling back to clipboard"
        )
      }
      return nil
    }

    let outcome = PasteConfirmation.outcome(
      before: before,
      after: after,
      expected: expected
    )
    Task {
      await DiagnosticLog.shared.record(
        "insert path=direct status=\(status.rawValue) outcome=\(outcome)"
      )
    }
    return PasteResult(outcome: outcome, reason: nil)
  }

  private func pasteUsingClipboard(
    _ text: String,
    current: CapturedFocus,
    expected: String
  ) async -> PasteResult {
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
    let outcome = PasteConfirmation.outcome(
      before: beforeState,
      after: afterState,
      expected: expected
    )
    Task {
      await DiagnosticLog.shared.record("insert path=clipboard outcome=\(outcome)")
    }
    return PasteResult(outcome: outcome, reason: nil)
  }

  func copy(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
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
