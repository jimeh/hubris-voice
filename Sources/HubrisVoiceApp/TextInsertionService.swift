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
  private let clipboard = ClipboardInsertionTransaction(pasteboard: .general)

  func captureFocusedTarget(
    allowManualAccessibility: Bool = true
  ) -> CapturedFocus? {
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
    if focusedElement == nil, allowManualAccessibility {
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

  /// Resolves the target at call time. A frontmost app that exposes no
  /// focused element is still attempted through the clipboard, because some
  /// Electron windows hide the focused field from Accessibility while it
  /// accepts a paste. Only a missing frontmost app or a secure field rejects.
  func insert(_ text: String, expected: String) async -> PasteResult {
    guard let current = captureFocusedTarget() else {
      return PasteResult(outcome: .rejected, reason: .noTarget)
    }
    guard PasteSafety.canPaste(current: current.snapshot) else {
      return PasteResult(outcome: .rejected, reason: .secureField)
    }

    DevelopmentTrace.shared.record(
      "insert target=\(current.targetBundleID ?? "unknown") pid=\(current.snapshot.processID) "
        + "path=clipboard text=\(String(reflecting: text))"
    )

    return await pasteUsingClipboard(
      text,
      current: current,
      expected: expected
    )
  }

  private func pasteUsingClipboard(
    _ text: String,
    current: CapturedFocus,
    expected: String
  ) async -> PasteResult {
    let beforeState = current.element.flatMap(accessibleTextState)
    DevelopmentTrace.shared.record("clipboard before=\(String(reflecting: beforeState))")
    guard let dictatedChangeCount = clipboard.write(text) else {
      DevelopmentTrace.shared.record("clipboard transient write failed")
      return PasteResult(outcome: .rejected, reason: .deliveryFailed)
    }
    DevelopmentTrace.shared.record("clipboard published with transient and autogenerated markers")

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
      DevelopmentTrace.shared.record("clipboard event creation failed")
      clipboard.restore(ifUnchangedSince: dictatedChangeCount)
      return PasteResult(outcome: .rejected, reason: .deliveryFailed)
    }
    DevelopmentTrace.shared.record(
      "clipboard posting Cmd+V physicalFlags=\(CGEventSource.flagsState(.combinedSessionState).rawValue)"
    )
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)

    Task { @MainActor [clipboard] in
      try? await Task.sleep(for: .milliseconds(1_500))
      if clipboard.restore(ifUnchangedSince: dictatedChangeCount) {
        DevelopmentTrace.shared.record("clipboard restored")
      } else {
        DevelopmentTrace.shared.record("clipboard restore skipped: contents changed")
      }
    }

    try? await Task.sleep(for: .milliseconds(200))
    let afterState = current.element.flatMap(accessibleTextState)
    DevelopmentTrace.shared.record("clipboard after=\(String(reflecting: afterState))")
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
