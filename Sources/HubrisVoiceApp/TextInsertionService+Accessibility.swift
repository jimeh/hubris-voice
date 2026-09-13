import AppKit
import ApplicationServices
import Foundation
import HubrisVoiceCore

/// Accessibility attribute readers shared by focus capture, anchor
/// resolution, and insertion confirmation.
extension TextInsertionService {
  func copyAXElement(
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

  func stringAttribute(
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

  func rangeAttribute(
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

  func parameterizedRectAttribute(
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

  func rect(
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

  func cgPointAttribute(
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

  func cgSizeAttribute(
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

  func cgRect(from value: CFTypeRef?) -> CGRect? {
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

  func containsCenterOnScreen(_ rect: LayoutRect) -> Bool {
    let center = NSPoint(x: rect.midX, y: rect.midY)
    return NSScreen.screens.contains { $0.frame.contains(center) }
  }

  func accessibleTextState(
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

  func stringIndex(
    utf16Offset: Int,
    in value: String
  ) -> String.Index? {
    let utf16Index = value.utf16.index(
      value.utf16.startIndex,
      offsetBy: utf16Offset
    )
    return String.Index(utf16Index, within: value)
  }

  func token(
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

  func isSecure(element: AXUIElement) -> Bool {
    let subrole = stringAttribute(kAXSubroleAttribute, from: element)
    return subrole == (kAXSecureTextFieldSubrole as String)
  }
}
