import Foundation
import HubrisVoiceCore

struct AccessibilityWindowTarget: Equatable, Sendable {
  let processID: pid_t
  let windowNumber: Int?
  let windowFingerprint: Int?

  init(processID: pid_t, windowNumber: Int?, windowFingerprint: Int? = nil) {
    self.processID = processID
    self.windowNumber = windowNumber
    self.windowFingerprint = windowFingerprint
  }

  func identifiesSameWindow(as other: Self) -> Bool {
    guard processID == other.processID else { return false }
    if let windowNumber, let otherWindowNumber = other.windowNumber {
      return windowNumber == otherWindowNumber
    }
    guard let windowFingerprint, let otherFingerprint = other.windowFingerprint else {
      return false
    }
    return windowFingerprint == otherFingerprint
  }
}

struct WindowTextCollectionDiagnostics: Equatable, Sendable {
  var visitedElements = 0
  var collectedCharacters = 0
  var elapsed: Duration = .zero
  var reachedElementLimit = false
  var reachedDepthLimit = false
  var reachedCharacterLimit = false
  var reachedDeadline = false
  var rangeDecisions: [WindowTextRangeDecision] = []
}

struct WindowTextCollection: Equatable, Sendable {
  let target: AccessibilityWindowTarget
  let fragments: [WindowTextFragment]
  var diagnostics: WindowTextCollectionDiagnostics
}

struct WindowTextCollectionLimits: Sendable {
  var overallTimeout: Duration = .milliseconds(300)
  var messagingTimeout: TimeInterval = 0.1
  var maximumElements = 2_000
  var maximumDepth = 24
  var maximumCharacters = 32_000
  var maximumControlCharacters = 4_096
}

struct AccessibilityNodeMetadata<Node: Hashable> {
  let role: String?
  let subrole: String?
  let isHidden: Bool?
  let isSelected: Bool?
  let frame: CGRect?
  let valueCharacterCount: Int?
  let parent: Node?
  let children: [Node]?
  let visibleChildren: [Node]?
  let visibleCharacterRange: CFRange?
}

protocol AccessibilityWindowReading {
  associatedtype Node: Hashable

  var target: AccessibilityWindowTarget { get }
  var applicationIdentifier: String? { get }
  var window: Node { get }
  var focusedElement: Node? { get }

  func metadata(for node: Node) -> AccessibilityNodeMetadata<Node>
  func string(_ attribute: AccessibilityStringAttribute, from node: Node) -> String?
  func string(for range: CFRange, from node: Node) -> String?
  func range(at position: CGPoint, from node: Node) -> CFRange?
  func line(forCharacterAt index: Int, from node: Node) -> Int?
  func range(forLine line: Int, from node: Node) -> CFRange?
}

extension AccessibilityWindowReading {
  var applicationIdentifier: String? {
    nil
  }

  func range(at _: CGPoint, from _: Node) -> CFRange? {
    nil
  }

  func line(forCharacterAt _: Int, from _: Node) -> Int? {
    nil
  }

  func range(forLine _: Int, from _: Node) -> CFRange? {
    nil
  }
}

enum AccessibilityStringAttribute {
  case value
  case selectedText
  case title
  case description
}

enum WindowTextTraversal {
  private struct Pending<Node> {
    let node: Node
    let depth: Int
    let visibility: WindowTextVisibility?
    let clippingRects: [CGRect]
    let editorLocal: Bool
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  static func collect<Reader: AccessibilityWindowReading>(
    from reader: Reader,
    limits: WindowTextCollectionLimits = .init(),
    deadlineReached: () -> Bool = { false }
  ) -> WindowTextCollection {
    var diagnostics = WindowTextCollectionDiagnostics()
    var fragments: [WindowTextFragment] = []
    var seen: Set<Reader.Node> = []
    let focused = reader.focusedElement

    if let focused,
       reader.metadata(for: focused).subrole == "AXSecureTextField"
    {
      return WindowTextCollection(target: reader.target, fragments: [], diagnostics: diagnostics)
    }

    let windowMetadata = reader.metadata(for: reader.window)
    let windowFrame = windowMetadata.frame
    let initialClips = windowFrame.map { [$0] } ?? []
    var queue = [Pending(
      node: reader.window,
      depth: 0,
      visibility: .title,
      clippingRects: initialClips,
      editorLocal: false
    )]
    if let focused, focused != reader.window {
      var focusedClips = initialClips
      var containingEditor: Pending<Reader.Node>?
      var ancestor = reader.metadata(for: focused).parent
      var ancestorDepth = 0
      var ancestorSeen: Set<Reader.Node> = [focused]
      while let node = ancestor,
            node != reader.window,
            ancestorDepth < limits.maximumDepth,
            ancestorSeen.insert(node).inserted
      {
        let metadata = reader.metadata(for: node)
        if isClippingRole(metadata.role) || isScrollableText(metadata.role) {
          containingEditor = Pending(
            node: node,
            depth: 0,
            visibility: visibility(
              metadata: metadata,
              windowFrame: windowFrame,
              clippingRects: initialClips
            ),
            clippingRects: initialClips,
            editorLocal: true
          )
          if isClippingRole(metadata.role), let frame = metadata.frame {
            focusedClips.append(frame)
          }
          break
        }
        ancestor = metadata.parent
        ancestorDepth += 1
      }
      var priorityNodes = [Pending(
        node: focused,
        depth: 0,
        visibility: visibility(
          metadata: reader.metadata(for: focused),
          windowFrame: windowFrame,
          clippingRects: focusedClips
        ),
        clippingRects: focusedClips,
        editorLocal: true
      )]
      if let containingEditor {
        priorityNodes.append(containingEditor)
      }
      queue.insert(contentsOf: priorityNodes, at: 0)
    }

    var index = 0
    while index < queue.count {
      if deadlineReached() {
        diagnostics.reachedDeadline = true
        break
      }
      guard diagnostics.visitedElements < limits.maximumElements else {
        diagnostics.reachedElementLimit = true
        break
      }

      let pending = queue[index]
      index += 1
      guard seen.insert(pending.node).inserted else { continue }
      diagnostics.visitedElements += 1

      let metadata = reader.metadata(for: pending.node)
      let isFocused = pending.node == focused
      if let source = titleSource(
        for: metadata.role,
        isWindow: pending.node == reader.window,
        isSelected: metadata.isSelected
      ) {
        append(
          reader.string(.title, from: pending.node),
          source: source,
          relevance: titleRelevance(source),
          visibility: .title,
          fragments: &fragments,
          diagnostics: &diagnostics,
          limits: limits
        )
      }

      if let visibility = pending.visibility, metadata.isHidden != true {
        if isFocused {
          append(
            reader.string(.selectedText, from: pending.node),
            source: .selectedText,
            relevance: .primary,
            visibility: visibility,
            fragments: &fragments,
            diagnostics: &diagnostics,
            limits: limits
          )
        }

        let source: WindowTextSource = isFocused
          ? .focusedElement
          : (pending.editorLocal ? .focusedEditor : .generalWindow)
        let relevance: WindowTextRelevance = isFocused
          ? .primary
          : (pending.editorLocal ? .nearby : .general)
        if let visibleRange = metadata.visibleCharacterRange, visibleRange.length > 0 {
          let decision = WindowTextRangeResolver.resolve(
            visibleRange,
            metadata: metadata,
            node: pending.node,
            clippingRects: pending.clippingRects,
            reader: reader
          )
          diagnostics.rangeDecisions.append(decision)
          let remaining = max(0, limits.maximumCharacters - diagnostics.collectedCharacters)
          let boundedRange = CFRange(
            location: decision.effectiveRange.location,
            length: min(decision.effectiveRange.length, remaining)
          )
          append(
            reader.string(for: boundedRange, from: pending.node),
            source: source,
            relevance: relevance,
            visibility: .visibleCharacterRange,
            fragments: &fragments,
            diagnostics: &diagnostics,
            limits: limits
          )
        } else if !isScrollableText(metadata.role),
                  let count = metadata.valueCharacterCount,
                  count <= limits.maximumControlCharacters
        {
          append(
            reader.string(.value, from: pending.node),
            source: source,
            relevance: relevance,
            visibility: visibility,
            fragments: &fragments,
            diagnostics: &diagnostics,
            limits: limits
          )
        } else if metadata.role == "AXStaticText" {
          append(
            reader.string(.value, from: pending.node),
            source: source,
            relevance: relevance,
            visibility: visibility,
            fragments: &fragments,
            diagnostics: &diagnostics,
            limits: limits,
            maximumFragmentCharacters: limits.maximumControlCharacters
          )
        }
        append(
          reader.string(.description, from: pending.node),
          source: source,
          relevance: relevance,
          visibility: visibility,
          fragments: &fragments,
          diagnostics: &diagnostics,
          limits: limits
        )
      }

      guard pending.depth < limits.maximumDepth else {
        if !(metadata.visibleChildren ?? metadata.children ?? []).isEmpty {
          diagnostics.reachedDepthLimit = true
        }
        continue
      }

      let isClip = isClippingRole(metadata.role)
      var childClipRects = pending.clippingRects
      if isClip {
        guard let frame = metadata.frame else { continue }
        childClipRects.append(frame)
      }

      if let visibleChildren = metadata.visibleChildren {
        queue.insert(contentsOf: visibleChildren.map { child in
          Pending(
            node: child,
            depth: pending.depth + 1,
            visibility: .visibleChildren,
            clippingRects: childClipRects,
            editorLocal: pending.editorLocal || isClip
          )
        }, at: index)
      } else if let children = metadata.children {
        queue.insert(contentsOf: children.map { child in
          Pending(
            node: child,
            depth: pending.depth + 1,
            visibility: visibility(
              metadata: reader.metadata(for: child),
              windowFrame: windowFrame,
              clippingRects: childClipRects
            ),
            clippingRects: childClipRects,
            editorLocal: pending.editorLocal || isClip
          )
        }, at: index)
      }
    }

    return WindowTextCollection(
      target: reader.target,
      fragments: fragments,
      diagnostics: diagnostics
    )
  }

  private static func visibility(
    metadata: AccessibilityNodeMetadata<some Hashable>,
    windowFrame: CGRect?,
    clippingRects: [CGRect]
  ) -> WindowTextVisibility? {
    guard metadata.isHidden != true,
          let frame = metadata.frame,
          let windowFrame,
          frame.intersects(windowFrame),
          clippingRects.allSatisfy({ frame.intersects($0) })
    else { return nil }
    return .boundsIntersection
  }

  // swiftlint:disable:next function_parameter_count
  private static func append(
    _ text: String?,
    source: WindowTextSource,
    relevance: WindowTextRelevance,
    visibility: WindowTextVisibility,
    fragments: inout [WindowTextFragment],
    diagnostics: inout WindowTextCollectionDiagnostics,
    limits: WindowTextCollectionLimits,
    maximumFragmentCharacters: Int = .max
  ) {
    guard let text, !text.isEmpty else { return }
    let remaining = limits.maximumCharacters - diagnostics.collectedCharacters
    guard remaining > 0 else {
      diagnostics.reachedCharacterLimit = true
      return
    }
    let retained = String(text.prefix(min(remaining, maximumFragmentCharacters)))
    fragments.append(WindowTextFragment(
      text: retained,
      source: source,
      relevance: relevance,
      visibility: visibility
    ))
    diagnostics.collectedCharacters += retained.count
    if retained.count < text.count || diagnostics.collectedCharacters == limits.maximumCharacters {
      diagnostics.reachedCharacterLimit = true
    }
  }

  private static func isScrollableText(_ role: String?) -> Bool {
    role == "AXTextArea" || role == "AXDocument" || role == "AXWebArea"
  }

  private static func isClippingRole(_ role: String?) -> Bool {
    role == "AXScrollArea"
  }

  private static func titleSource(
    for role: String?,
    isWindow: Bool,
    isSelected: Bool?
  ) -> WindowTextSource? {
    if isWindow || role == "AXWindow" {
      return .windowTitle
    }
    if role == "AXDocument" || role == "AXWebArea" {
      return .documentTitle
    }
    if role == "AXTab", isSelected == true {
      return .selectedTabTitle
    }
    return nil
  }

  private static func titleRelevance(_ source: WindowTextSource) -> WindowTextRelevance {
    source == .windowTitle ? .supporting : .nearby
  }
}
