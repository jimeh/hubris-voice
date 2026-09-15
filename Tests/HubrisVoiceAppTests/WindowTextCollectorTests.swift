import Foundation
@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

// swiftlint:disable file_length

// swiftlint:disable:next type_body_length
final class WindowTextCollectorTests: XCTestCase {
  func testTargetIdentityRequiresWindowEvidence() {
    let numbered = AccessibilityWindowTarget(processID: 42, windowNumber: 7)
    XCTAssertTrue(numbered.identifiesSameWindow(as: numbered))
    XCTAssertFalse(numbered.identifiesSameWindow(
      as: AccessibilityWindowTarget(processID: 43, windowNumber: 7)
    ))
    XCTAssertFalse(AccessibilityWindowTarget(
      processID: 42,
      windowNumber: nil
    ).identifiesSameWindow(as: AccessibilityWindowTarget(
      processID: 42,
      windowNumber: nil
    )))
    XCTAssertTrue(AccessibilityWindowTarget(
      processID: 42,
      windowNumber: nil,
      windowFingerprint: 99
    ).identifiesSameWindow(as: AccessibilityWindowTarget(
      processID: 42,
      windowNumber: nil,
      windowFingerprint: 99
    )))
  }

  func testVisibleChildrenArePreferredOverUnverifiedChildren() {
    let reader = FakeReader(
      nodes: [
        0: node(
          role: "AXWindow",
          frame: rect(0, 0, 500, 500),
          children: [1, 2],
          visibleChildren: [1]
        ),
        1: node(
          role: "AXStaticText",
          hidden: false,
          frame: rect(10, 10, 100, 20),
          valueCount: 10,
          value: "VisibleTerm"
        ),
        2: node(
          role: "AXStaticText",
          hidden: false,
          frame: rect(10, 40, 100, 20),
          valueCount: 10,
          value: "ChildOnly"
        ),
      ]
    )

    let result = WindowTextTraversal.collect(from: reader)

    XCTAssertEqual(result.fragments.map(\.text), ["VisibleTerm"])
    XCTAssertEqual(result.fragments.first?.visibility, .visibleChildren)
  }

  func testWindowDocumentAndSelectedTabTitlesAreCollected() {
    let reader = FakeReader(
      nodes: [
        0: node(
          role: "AXWindow",
          frame: rect(0, 0, 500, 500),
          title: "Project Window",
          visibleChildren: [1, 2, 3]
        ),
        1: node(role: "AXDocument", title: "Source File"),
        2: node(role: "AXTab", selected: true, title: "Selected Tab"),
        3: node(role: "AXTab", selected: false, title: "Hidden Tab"),
      ]
    )

    let result = WindowTextTraversal.collect(from: reader)

    XCTAssertEqual(result.fragments.map(\.text), [
      "Project Window",
      "Source File",
      "Selected Tab",
    ])
    XCTAssertEqual(result.fragments.map(\.source), [
      .windowTitle,
      .documentTitle,
      .selectedTabTitle,
    ])
    XCTAssertTrue(result.fragments.allSatisfy { $0.visibility == .title })
  }

  func testFocusedSelectionAndContainingEditorArePrioritized() {
    let reader = FakeReader(
      focused: 2,
      nodes: [
        0: node(role: "AXWindow", frame: rect(0, 0, 500, 500), children: [1]),
        1: node(
          role: "AXScrollArea",
          hidden: false,
          frame: rect(0, 0, 300, 300),
          parent: 0,
          children: [2, 3]
        ),
        2: node(
          role: "AXTextField",
          hidden: false,
          frame: rect(10, 10, 100, 20),
          valueCount: 11,
          value: "FocusedTerm",
          parent: 1,
          selectedText: "Selection"
        ),
        3: node(
          role: "AXStaticText",
          hidden: false,
          frame: rect(10, 40, 100, 20),
          valueCount: 10,
          value: "NearbyTerm",
          parent: 1
        ),
      ]
    )

    let result = WindowTextTraversal.collect(from: reader)

    XCTAssertEqual(result.fragments.map(\.text), [
      "Selection",
      "FocusedTerm",
      "NearbyTerm",
    ])
    XCTAssertEqual(result.fragments.map(\.source), [
      .selectedText,
      .focusedElement,
      .focusedEditor,
    ])
  }

  func testUnsupportedVisibleChildrenUsesStrictWindowAndClippingGeometry() {
    let reader = FakeReader(
      nodes: [
        0: node(role: "AXWindow", frame: rect(0, 0, 500, 500), children: [1]),
        1: node(
          role: "AXScrollArea",
          hidden: false,
          frame: rect(0, 0, 100, 100),
          children: [2, 3, 4]
        ),
        2: node(
          role: "AXStaticText",
          hidden: false,
          frame: rect(10, 10, 50, 20),
          valueCount: 6,
          value: "Inside"
        ),
        3: node(
          role: "AXStaticText",
          hidden: false,
          frame: rect(300, 300, 50, 20),
          valueCount: 9,
          value: "Offscreen"
        ),
        4: node(
          role: "AXStaticText",
          hidden: true,
          frame: rect(10, 40, 50, 20),
          valueCount: 6,
          value: "Hidden"
        ),
      ]
    )

    let result = WindowTextTraversal.collect(from: reader)

    XCTAssertEqual(result.fragments.map(\.text), ["Inside"])
    XCTAssertEqual(result.fragments.first?.visibility, .boundsIntersection)
    XCTAssertEqual(result.fragments.first?.source, .focusedEditor)
  }

  func testNonClippingGroupDoesNotNeedItsOwnGeometry() {
    let reader = FakeReader(
      nodes: [
        0: node(role: "AXWindow", frame: rect(0, 0, 500, 500), children: [1]),
        1: node(role: "AXGroup", hidden: false, children: [2]),
        2: node(
          role: "AXStaticText",
          hidden: false,
          frame: rect(10, 10, 100, 20),
          valueCount: 16,
          value: "GroupedIdentifier"
        ),
      ]
    )

    let result = WindowTextTraversal.collect(from: reader)

    XCTAssertEqual(result.fragments.map(\.text), ["GroupedIdentifier"])
    XCTAssertEqual(result.fragments.first?.visibility, .boundsIntersection)
  }

  func testScrollableTextUsesOnlyBoundedVisibleRange() {
    let reader = FakeReader(
      nodes: [
        0: node(role: "AXWindow", frame: rect(0, 0, 500, 500), visibleChildren: [1, 2]),
        1: node(
          role: "AXTextArea",
          hidden: false,
          frame: rect(0, 0, 100, 100),
          valueCount: 20_000,
          value: "CompleteDocument",
          visibleRange: CFRange(location: 50, length: 1_000),
          rangeValue: "VisibleEditorText"
        ),
        2: node(
          role: "AXDocument",
          hidden: false,
          frame: rect(0, 0, 100, 100),
          valueCount: 12,
          value: "SkippedValue"
        ),
      ]
    )
    var limits = WindowTextCollectionLimits()
    limits.maximumCharacters = 8

    let result = WindowTextTraversal.collect(from: reader, limits: limits)

    XCTAssertEqual(result.fragments.map(\.text), ["VisibleE"])
    XCTAssertEqual(reader.requestedRanges.count, 1)
    XCTAssertEqual(reader.requestedRanges.first?.location, 50)
    XCTAssertEqual(reader.requestedRanges.first?.length, 8)
    XCTAssertFalse(reader.requestedStrings.contains(.init(node: 1, attribute: .value)))
    XCTAssertFalse(reader.requestedStrings.contains(.init(node: 2, attribute: .value)))
    XCTAssertTrue(result.diagnostics.reachedCharacterLimit)
  }

  func testTerminalTextWithoutHiddenAttributeUsesOnlyVisibleRange() {
    let reader = FakeReader(
      focused: 2,
      nodes: [
        0: node(role: "AXWindow", frame: rect(0, 0, 500, 500), children: [1]),
        1: node(
          role: "AXScrollArea",
          frame: rect(0, 0, 500, 500),
          parent: 0,
          children: [2]
        ),
        2: node(
          role: "AXTextArea",
          frame: rect(0, 0, 500, 500),
          valueCount: 50_000,
          value: "out of view",
          parent: 1,
          visibleRange: CFRange(location: 49_950, length: 50),
          rangeValue: "in view\nAppModelExample"
        ),
      ]
    )

    let result = WindowTextTraversal.collect(from: reader)

    XCTAssertEqual(result.fragments.map(\.text), ["in view\nAppModelExample"])
    XCTAssertEqual(result.fragments.map(\.visibility), [.visibleCharacterRange])
    XCTAssertFalse(reader.requestedStrings.contains(.init(node: 2, attribute: .value)))
    XCTAssertEqual(reader.requestedRanges.count, 1)
    XCTAssertEqual(reader.requestedRanges.first?.location, 49_950)
    XCTAssertEqual(reader.requestedRanges.first?.length, 50)
  }

  func testSecureFocusedElementRejectsAllWindowText() {
    let reader = FakeReader(
      focused: 1,
      nodes: [
        0: node(
          role: "AXWindow",
          frame: rect(0, 0, 500, 500),
          title: "Secret Project"
        ),
        1: node(
          role: "AXTextField",
          subrole: "AXSecureTextField",
          hidden: false,
          frame: rect(10, 10, 100, 20),
          valueCount: 8,
          value: "password"
        ),
      ]
    )

    let result = WindowTextTraversal.collect(from: reader)

    XCTAssertTrue(result.fragments.isEmpty)
    XCTAssertTrue(reader.requestedStrings.isEmpty)
  }

  func testCycleAndElementLimitReturnUsefulPartialResult() {
    let reader = FakeReader(
      nodes: [
        0: node(role: "AXWindow", frame: rect(0, 0, 500, 500), visibleChildren: [1]),
        1: node(
          role: "AXStaticText",
          hidden: false,
          frame: rect(10, 10, 100, 20),
          valueCount: 5,
          value: "First",
          visibleChildren: [0, 2]
        ),
        2: node(
          role: "AXStaticText",
          hidden: false,
          frame: rect(10, 40, 100, 20),
          valueCount: 6,
          value: "Second"
        ),
      ]
    )
    var limits = WindowTextCollectionLimits()
    limits.maximumElements = 2

    let result = WindowTextTraversal.collect(from: reader, limits: limits)

    XCTAssertEqual(result.fragments.map(\.text), ["First"])
    XCTAssertEqual(result.diagnostics.visitedElements, 2)
    XCTAssertTrue(result.diagnostics.reachedElementLimit)
  }

  func testDepthAndDeadlineBudgetsReturnPartialResults() {
    let reader = FakeReader(
      nodes: [
        0: node(role: "AXWindow", frame: rect(0, 0, 500, 500), visibleChildren: [1]),
        1: node(
          role: "AXStaticText",
          hidden: false,
          frame: rect(10, 10, 100, 20),
          valueCount: 5,
          value: "First",
          visibleChildren: [2]
        ),
        2: node(
          role: "AXStaticText",
          hidden: false,
          frame: rect(10, 40, 100, 20),
          valueCount: 6,
          value: "Second"
        ),
      ]
    )
    var depthLimits = WindowTextCollectionLimits()
    depthLimits.maximumDepth = 1
    let depthResult = WindowTextTraversal.collect(from: reader, limits: depthLimits)
    XCTAssertEqual(depthResult.fragments.map(\.text), ["First"])
    XCTAssertTrue(depthResult.diagnostics.reachedDepthLimit)

    var checks = 0
    let deadlineResult = WindowTextTraversal.collect(from: reader) {
      defer { checks += 1 }
      return checks >= 2
    }
    XCTAssertEqual(deadlineResult.fragments.map(\.text), ["First"])
    XCTAssertTrue(deadlineResult.diagnostics.reachedDeadline)
  }

  func testDefaultBudgetsReachDeepVisibleWebContent() {
    var nodes: [Int: FakeNode] = [:]
    nodes[0] = node(
      role: "AXWindow",
      frame: rect(0, 0, 500, 500),
      visibleChildren: [1]
    )
    for depth in 1 ... 18 {
      nodes[depth] = node(
        role: depth == 7 ? "AXWebArea" : "AXGroup",
        hidden: false,
        frame: rect(0, 0, 500, 500),
        visibleChildren: depth == 18 ? Array(100 ... 1_699) + [1_700] : [depth + 1]
      )
    }
    for identifier in 100 ... 1_699 {
      nodes[identifier] = node(
        role: "AXGroup",
        hidden: false,
        frame: rect(0, 0, 1, 1),
        visibleChildren: []
      )
    }
    nodes[1_700] = node(
      role: "AXStaticText",
      hidden: false,
      frame: rect(10, 10, 165, 15),
      valueCount: 21,
      value: "AXManualAccessibility",
      visibleChildren: []
    )

    let result = WindowTextTraversal.collect(from: FakeReader(nodes: nodes))

    XCTAssertTrue(result.fragments.contains { $0.text == "AXManualAccessibility" })
    XCTAssertFalse(result.diagnostics.reachedElementLimit)
    XCTAssertFalse(result.diagnostics.reachedDepthLimit)
  }

  func testDeepVisibleBranchIsTraversedBeforeWideShallowSiblings() {
    var nodes: [Int: FakeNode] = [
      0: node(
        role: "AXWindow",
        frame: rect(0, 0, 500, 500),
        visibleChildren: Array(1 ... 100)
      ),
    ]
    for identifier in 2 ... 100 {
      nodes[identifier] = node(
        role: "AXGroup",
        hidden: false,
        frame: rect(0, 0, 1, 1),
        visibleChildren: Array((identifier * 100) ..< (identifier * 100 + 100))
      )
      for child in (identifier * 100) ..< (identifier * 100 + 100) {
        nodes[child] = node(role: "AXGroup", visibleChildren: [])
      }
    }
    nodes[1] = node(
      role: "AXGroup",
      hidden: false,
      frame: rect(0, 0, 500, 500),
      visibleChildren: [101]
    )
    nodes[101] = node(
      role: "AXStaticText",
      hidden: false,
      frame: rect(10, 10, 165, 15),
      value: "AXManualAccessibility"
    )
    var limits = WindowTextCollectionLimits()
    limits.maximumElements = 10

    let result = WindowTextTraversal.collect(from: FakeReader(nodes: nodes), limits: limits)

    XCTAssertTrue(result.fragments.contains { $0.text == "AXManualAccessibility" })
  }

  func testVisibleStaticTextWithoutCharacterCountUsesBoundedValue() {
    let reader = FakeReader(
      nodes: [
        0: node(role: "AXWindow", frame: rect(0, 0, 500, 500), visibleChildren: [1]),
        1: node(
          role: "AXStaticText",
          hidden: false,
          frame: rect(10, 10, 100, 20),
          value: "AXManualAccessibility"
        ),
      ]
    )
    var limits = WindowTextCollectionLimits()
    limits.maximumControlCharacters = 8

    let result = WindowTextTraversal.collect(from: reader, limits: limits)

    XCTAssertEqual(result.fragments.map(\.text), ["AXManual"])
    XCTAssertTrue(result.diagnostics.reachedCharacterLimit)
  }

  func testVisibleStaticTextWithEmptyVisibleRangeUsesValue() {
    let reader = FakeReader(
      nodes: [
        0: node(role: "AXWindow", frame: rect(0, 0, 500, 500), visibleChildren: [1]),
        1: node(
          role: "AXStaticText",
          hidden: false,
          frame: rect(10, 10, 165, 15),
          valueCount: 0,
          value: "AXManualAccessibility",
          visibleRange: CFRange(location: 0, length: 0)
        ),
      ]
    )

    let result = WindowTextTraversal.collect(from: reader)

    XCTAssertEqual(result.fragments.map(\.text), ["AXManualAccessibility"])
    XCTAssertTrue(reader.requestedRanges.isEmpty)
  }

  func testOversizedControlValueIsNeverRead() {
    let reader = FakeReader(
      nodes: [
        0: node(role: "AXWindow", frame: rect(0, 0, 500, 500), visibleChildren: [1]),
        1: node(
          role: "AXTextField",
          hidden: false,
          frame: rect(10, 10, 100, 20),
          valueCount: 4_097,
          value: String(repeating: "x", count: 4_097)
        ),
      ]
    )

    let result = WindowTextTraversal.collect(from: reader)

    XCTAssertTrue(result.fragments.isEmpty)
    XCTAssertFalse(reader.requestedStrings.contains(.init(node: 1, attribute: .value)))
  }
}

private struct FakeNode {
  var role: String?
  var subrole: String?
  var hidden: Bool?
  var selected: Bool?
  var frame: CGRect?
  var valueCount: Int?
  var value: String?
  var parent: Int?
  var selectedText: String?
  var title: String?
  var description: String?
  var children: [Int]?
  var visibleChildren: [Int]?
  var visibleRange: CFRange?
  var rangeValue: String?
}

private final class FakeReader: AccessibilityWindowReading {
  struct StringRequest: Equatable {
    let node: Int
    let attribute: AccessibilityStringAttribute
  }

  let target = AccessibilityWindowTarget(processID: 42, windowNumber: 7)
  let window = 0
  let focusedElement: Int?
  private let nodes: [Int: FakeNode]
  private(set) var requestedStrings: [StringRequest] = []
  private(set) var requestedRanges: [CFRange] = []

  init(focused: Int? = nil, nodes: [Int: FakeNode]) {
    focusedElement = focused
    self.nodes = nodes
  }

  func metadata(for node: Int) -> AccessibilityNodeMetadata<Int> {
    guard let value = nodes[node] else {
      fatalError("Missing fake AX node \(node)")
    }
    return AccessibilityNodeMetadata(
      role: value.role,
      subrole: value.subrole,
      isHidden: value.hidden,
      isSelected: value.selected,
      frame: value.frame,
      valueCharacterCount: value.valueCount,
      parent: value.parent,
      children: value.children,
      visibleChildren: value.visibleChildren,
      visibleCharacterRange: value.visibleRange
    )
  }

  func string(_ attribute: AccessibilityStringAttribute, from node: Int) -> String? {
    requestedStrings.append(.init(node: node, attribute: attribute))
    guard let value = nodes[node] else {
      fatalError("Missing fake AX node \(node)")
    }
    switch attribute {
    case .value: return value.value
    case .selectedText: return value.selectedText
    case .title: return value.title
    case .description: return value.description
    }
  }

  func string(for range: CFRange, from node: Int) -> String? {
    requestedRanges.append(range)
    guard let value = nodes[node] else {
      fatalError("Missing fake AX node \(node)")
    }
    return value.rangeValue
  }
}

private func node(
  role: String? = nil,
  subrole: String? = nil,
  hidden: Bool? = nil,
  selected: Bool? = nil,
  frame: CGRect? = nil,
  valueCount: Int? = nil,
  value: String? = nil,
  parent: Int? = nil,
  selectedText: String? = nil,
  title: String? = nil,
  description: String? = nil,
  children: [Int]? = nil,
  visibleChildren: [Int]? = nil,
  visibleRange: CFRange? = nil,
  rangeValue: String? = nil
) -> FakeNode {
  FakeNode(
    role: role,
    subrole: subrole,
    hidden: hidden,
    selected: selected,
    frame: frame,
    valueCount: valueCount,
    value: value,
    parent: parent,
    selectedText: selectedText,
    title: title,
    description: description,
    children: children,
    visibleChildren: visibleChildren,
    visibleRange: visibleRange,
    rangeValue: rangeValue
  )
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
  CGRect(x: x, y: y, width: width, height: height)
}
