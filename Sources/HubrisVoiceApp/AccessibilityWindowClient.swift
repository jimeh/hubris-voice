import AppKit
import ApplicationServices
import Foundation

struct AccessibilityWindowTextCollector: Sendable {
  var limits = WindowTextCollectionLimits()

  @MainActor
  func collectActiveWindow() async -> WindowTextCollection? {
    guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
    return await collect(processID: application.processIdentifier)
  }

  func collect(processID: pid_t) async -> WindowTextCollection? {
    let limits = limits
    return await Task.detached(priority: .userInitiated) {
      let clock = ContinuousClock()
      let started = clock.now
      guard let client = AXWindowClient(
        processID: processID,
        messagingTimeout: limits.messagingTimeout,
        overallTimeout: limits.overallTimeout
      )
      else { return nil }
      var result = WindowTextTraversal.collect(
        from: client,
        limits: limits,
        deadlineReached: { client.deadlineReached }
      )
      result.diagnostics.elapsed = started.duration(to: clock.now)
      return result
    }.value
  }

  @MainActor
  func revalidateActiveWindow(_ target: AccessibilityWindowTarget) async -> Bool {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID else {
      return false
    }
    let limits = limits
    return await Task.detached(priority: .userInitiated) {
      guard let client = AXWindowClient(
        processID: target.processID,
        messagingTimeout: limits.messagingTimeout,
        overallTimeout: limits.overallTimeout
      ) else { return false }
      return client.target.identifiesSameWindow(as: target)
        && !client.focusedElementIsSecure
    }.value
  }
}

private struct AXNode: Hashable, @unchecked Sendable {
  let element: AXUIElement

  static func == (lhs: Self, rhs: Self) -> Bool {
    CFEqual(lhs.element, rhs.element)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(CFHash(element))
  }
}

private struct AXWindowClient: AccessibilityWindowReading, @unchecked Sendable {
  let target: AccessibilityWindowTarget
  let window: AXNode
  let focusedElement: AXNode?

  private let readDeadline: AXReadDeadline

  var deadlineReached: Bool {
    readDeadline.expired
  }

  init?(
    processID: pid_t,
    messagingTimeout: TimeInterval,
    overallTimeout: Duration
  ) {
    let readDeadline = AXReadDeadline(timeout: overallTimeout)
    let application = AXUIElementCreateApplication(processID)
    AXUIElementSetMessagingTimeout(application, Float(messagingTimeout))
    guard let window = Self.element(
      kAXFocusedWindowAttribute,
      from: application,
      deadline: readDeadline
    ) else { return nil }
    self.readDeadline = readDeadline
    self.window = AXNode(element: window)
    focusedElement = Self.element(
      kAXFocusedUIElementAttribute,
      from: application,
      deadline: readDeadline
    )
    .map { AXNode(element: $0) }
    let windowNumber = Self.number("AXWindowNumber", from: window, deadline: readDeadline)
    target = AccessibilityWindowTarget(
      processID: processID,
      windowNumber: windowNumber,
      windowFingerprint: windowNumber == nil
        ? Self.fingerprint(for: window, deadline: readDeadline)
        : nil
    )
  }

  var focusedElementIsSecure: Bool {
    guard let focusedElement else { return false }
    return Self.string(
      kAXSubroleAttribute,
      from: focusedElement.element,
      deadline: readDeadline
    ) == (kAXSecureTextFieldSubrole as String)
  }

  func metadata(for node: AXNode) -> AccessibilityNodeMetadata<AXNode> {
    let attributes = [
      kAXRoleAttribute,
      kAXSubroleAttribute,
      kAXHiddenAttribute,
      kAXSelectedAttribute,
      kAXPositionAttribute,
      kAXSizeAttribute,
      "AXNumberOfCharacters",
      kAXParentAttribute,
      kAXChildrenAttribute,
      kAXVisibleChildrenAttribute,
      kAXVisibleCharacterRangeAttribute,
    ]
    if let values = Self.values(attributes, from: node.element, deadline: readDeadline) {
      return AccessibilityNodeMetadata(
        role: Self.string(values[kAXRoleAttribute]),
        subrole: Self.string(values[kAXSubroleAttribute]),
        isHidden: Self.boolean(values[kAXHiddenAttribute]),
        isSelected: Self.boolean(values[kAXSelectedAttribute]),
        frame: Self.frame(
          position: values[kAXPositionAttribute],
          size: values[kAXSizeAttribute]
        ),
        valueCharacterCount: Self.number(values["AXNumberOfCharacters"]),
        parent: Self.element(values[kAXParentAttribute]).map(AXNode.init),
        children: Self.elements(values[kAXChildrenAttribute])?.map(AXNode.init),
        visibleChildren: Self.elements(values[kAXVisibleChildrenAttribute])?.map(AXNode.init),
        visibleCharacterRange: Self.range(values[kAXVisibleCharacterRangeAttribute])
      )
    }
    return AccessibilityNodeMetadata(
      role: Self.string(kAXRoleAttribute, from: node.element, deadline: readDeadline),
      subrole: Self.string(kAXSubroleAttribute, from: node.element, deadline: readDeadline),
      isHidden: Self.boolean(kAXHiddenAttribute, from: node.element, deadline: readDeadline),
      isSelected: Self.boolean(kAXSelectedAttribute, from: node.element, deadline: readDeadline),
      frame: Self.frame(from: node.element, deadline: readDeadline),
      valueCharacterCount: Self.number(
        "AXNumberOfCharacters",
        from: node.element,
        deadline: readDeadline
      ),
      parent: Self.element(
        kAXParentAttribute,
        from: node.element,
        deadline: readDeadline
      ).map(AXNode.init),
      children: Self.elements(
        kAXChildrenAttribute,
        from: node.element,
        deadline: readDeadline
      )?.map(AXNode.init),
      visibleChildren: Self.elements(
        kAXVisibleChildrenAttribute,
        from: node.element,
        deadline: readDeadline
      )?.map(AXNode.init),
      visibleCharacterRange: Self.range(
        kAXVisibleCharacterRangeAttribute,
        from: node.element,
        deadline: readDeadline
      )
    )
  }

  func string(_ attribute: AccessibilityStringAttribute, from node: AXNode) -> String? {
    let name: String = switch attribute {
    case .value: kAXValueAttribute
    case .selectedText: kAXSelectedTextAttribute
    case .title: kAXTitleAttribute
    case .description: kAXDescriptionAttribute
    }
    return Self.string(name, from: node.element, deadline: readDeadline)
  }

  func string(for range: CFRange, from node: AXNode) -> String? {
    guard !readDeadline.expired else { return nil }
    var range = range
    guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
      node.element,
      kAXStringForRangeParameterizedAttribute as CFString,
      parameter,
      &value
    ) == .success else { return nil }
    return value as? String
  }

  private static func value(
    _ attribute: String,
    from element: AXUIElement,
    deadline: AXReadDeadline
  ) -> CFTypeRef? {
    guard !deadline.expired else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    else { return nil }
    return value
  }

  private static func values(
    _ attributes: [String],
    from element: AXUIElement,
    deadline: AXReadDeadline
  ) -> [String: CFTypeRef]? {
    guard !deadline.expired else { return nil }
    var copiedValues: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(
      element,
      attributes as CFArray,
      AXCopyMultipleAttributeOptions(rawValue: 0),
      &copiedValues
    ) == .success,
      let rawValues = copiedValues as? [AnyObject],
      rawValues.count == attributes.count
    else { return nil }

    var result: [String: CFTypeRef] = [:]
    for (attribute, rawValue) in zip(attributes, rawValues) {
      let value = rawValue as CFTypeRef
      if CFGetTypeID(value) != CFNullGetTypeID() {
        result[attribute] = value
      }
    }
    return result
  }

  private static func string(_ value: CFTypeRef?) -> String? {
    value as? String
  }

  private static func boolean(_ value: CFTypeRef?) -> Bool? {
    value as? Bool
  }

  private static func number(_ value: CFTypeRef?) -> Int? {
    (value as? NSNumber)?.intValue
  }

  private static func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private static func elements(_ value: CFTypeRef?) -> [AXUIElement]? {
    value as? [AXUIElement]
  }

  private static func range(_ value: CFTypeRef?) -> CFRange? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let rangeValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(rangeValue) == .cfRange else { return nil }
    var range = CFRange()
    return AXValueGetValue(rangeValue, .cfRange, &range) ? range : nil
  }

  private static func frame(position: CFTypeRef?, size sizeValue: CFTypeRef?) -> CGRect? {
    guard let position = point(position),
          let size = size(sizeValue),
          size.width > 0,
          size.height > 0
    else { return nil }
    return CGRect(origin: position, size: size)
  }

  private static func point(_ value: CFTypeRef?) -> CGPoint? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let pointValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(pointValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(pointValue, .cgPoint, &point) ? point : nil
  }

  private static func size(_ value: CFTypeRef?) -> CGSize? {
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let sizeValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(sizeValue) == .cgSize else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(sizeValue, .cgSize, &size) ? size : nil
  }

  private static func string(
    _ attribute: String,
    from element: AXUIElement,
    deadline: AXReadDeadline
  ) -> String? {
    value(attribute, from: element, deadline: deadline) as? String
  }

  private static func boolean(
    _ attribute: String,
    from element: AXUIElement,
    deadline: AXReadDeadline
  ) -> Bool? {
    value(attribute, from: element, deadline: deadline) as? Bool
  }

  private static func number(
    _ attribute: String,
    from element: AXUIElement,
    deadline: AXReadDeadline
  ) -> Int? {
    (value(attribute, from: element, deadline: deadline) as? NSNumber)?.intValue
  }

  private static func element(
    _ attribute: String,
    from element: AXUIElement,
    deadline: AXReadDeadline
  ) -> AXUIElement? {
    guard let value = value(attribute, from: element, deadline: deadline),
          CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return unsafeDowncast(value, to: AXUIElement.self)
  }

  private static func elements(
    _ attribute: String,
    from element: AXUIElement,
    deadline: AXReadDeadline
  ) -> [AXUIElement]? {
    value(attribute, from: element, deadline: deadline) as? [AXUIElement]
  }

  private static func range(
    _ attribute: String,
    from element: AXUIElement,
    deadline: AXReadDeadline
  ) -> CFRange? {
    guard let value = value(attribute, from: element, deadline: deadline),
          CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    let rangeValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(rangeValue) == .cfRange else { return nil }
    var range = CFRange()
    return AXValueGetValue(rangeValue, .cfRange, &range) ? range : nil
  }

  private static func frame(
    from element: AXUIElement,
    deadline: AXReadDeadline
  ) -> CGRect? {
    guard
      let position = point(kAXPositionAttribute, from: element, deadline: deadline),
      let size = size(kAXSizeAttribute, from: element, deadline: deadline),
      size.width > 0,
      size.height > 0
    else { return nil }
    return CGRect(origin: position, size: size)
  }

  private static func point(
    _ attribute: String,
    from element: AXUIElement,
    deadline: AXReadDeadline
  ) -> CGPoint? {
    guard let value = value(attribute, from: element, deadline: deadline),
          CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    let pointValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(pointValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(pointValue, .cgPoint, &point) ? point : nil
  }

  private static func size(
    _ attribute: String,
    from element: AXUIElement,
    deadline: AXReadDeadline
  ) -> CGSize? {
    guard let value = value(attribute, from: element, deadline: deadline),
          CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    let sizeValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(sizeValue) == .cgSize else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(sizeValue, .cgSize, &size) ? size : nil
  }

  private static func fingerprint(
    for window: AXUIElement,
    deadline: AXReadDeadline
  ) -> Int? {
    guard
      let title = string(kAXTitleAttribute, from: window, deadline: deadline),
      let frame = frame(from: window, deadline: deadline)
    else { return nil }
    var hasher = Hasher()
    hasher.combine(title)
    hasher.combine(frame.origin.x)
    hasher.combine(frame.origin.y)
    hasher.combine(frame.size.width)
    hasher.combine(frame.size.height)
    return hasher.finalize()
  }
}

private final class AXReadDeadline: @unchecked Sendable {
  private let clock = ContinuousClock()
  private let deadline: ContinuousClock.Instant

  init(timeout: Duration) {
    deadline = clock.now.advanced(by: timeout)
  }

  var expired: Bool {
    clock.now >= deadline
  }
}
