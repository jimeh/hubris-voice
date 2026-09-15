import Foundation

enum WindowTextRangeStrategy: String, Equatable, Sendable {
  case reportedRange
  case geometryClipped
  case trailingLines
}

struct WindowTextRangeDecision: Equatable, Sendable {
  let applicationIdentifier: String?
  let strategy: WindowTextRangeStrategy
  let reportedRange: CFRange
  let effectiveRange: CFRange

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.applicationIdentifier == rhs.applicationIdentifier
      && lhs.strategy == rhs.strategy
      && lhs.reportedRange.location == rhs.reportedRange.location
      && lhs.reportedRange.length == rhs.reportedRange.length
      && lhs.effectiveRange.location == rhs.effectiveRange.location
      && lhs.effectiveRange.length == rhs.effectiveRange.length
  }
}

enum WindowTextRangeResolver {
  static func resolve<Reader: AccessibilityWindowReading>(
    _ reportedRange: CFRange,
    metadata: AccessibilityNodeMetadata<Reader.Node>,
    node: Reader.Node,
    clippingRects: [CGRect],
    reader: Reader
  ) -> WindowTextRangeDecision {
    if let clippingRect = clippingRects.last,
       let range = geometryClippedRange(
         reportedRange,
         characterCount: metadata.valueCharacterCount,
         clippingRect: clippingRect,
         node: node,
         reader: reader
       )
    {
      return WindowTextRangeDecision(
        applicationIdentifier: reader.applicationIdentifier,
        strategy: .geometryClipped,
        reportedRange: reportedRange,
        effectiveRange: range
      )
    }
    if let lineLimit = WindowTextVisibilityQuirks.trailingLineLimit(
      for: reader.applicationIdentifier
    ),
      let range = trailingLineRange(
        reportedRange,
        characterCount: metadata.valueCharacterCount,
        lineLimit: lineLimit,
        node: node,
        reader: reader
      )
    {
      return WindowTextRangeDecision(
        applicationIdentifier: reader.applicationIdentifier,
        strategy: .trailingLines,
        reportedRange: reportedRange,
        effectiveRange: range
      )
    }
    return WindowTextRangeDecision(
      applicationIdentifier: reader.applicationIdentifier,
      strategy: .reportedRange,
      reportedRange: reportedRange,
      effectiveRange: reportedRange
    )
  }

  private static func geometryClippedRange<Reader: AccessibilityWindowReading>(
    _ reportedRange: CFRange,
    characterCount: Int?,
    clippingRect: CGRect,
    node: Reader.Node,
    reader: Reader
  ) -> CFRange? {
    guard clippingRect.width > 2, clippingRect.height > 2 else { return nil }
    let topY = clippingRect.minY + 1
    let bottomY = clippingRect.maxY - 1
    let leftX = clippingRect.minX + 1
    let rightX = clippingRect.maxX - 1
    let points = [
      CGPoint(x: leftX, y: topY),
      CGPoint(x: rightX, y: topY),
      CGPoint(x: leftX, y: bottomY),
      CGPoint(x: rightX, y: bottomY),
    ]
    let ranges = points.map { reader.range(at: $0, from: node) }
    guard ranges.allSatisfy({ $0 != nil }) else { return nil }
    let topRanges = ranges.prefix(2).compactMap(\.self)
    let bottomRanges = ranges.suffix(2).compactMap(\.self)
    guard let top = topRanges.map(\.location).min(),
          let bottom = bottomRanges.map(rangeEnd).max()
    else { return nil }

    let contentEnd = max(0, characterCount ?? rangeEnd(reportedRange))
    var lower = min(max(0, top), contentEnd)
    var upper = min(max(0, bottom), contentEnd)
    guard upper > lower else { return nil }

    if let topLine = reader.line(forCharacterAt: lower, from: node),
       let bottomLine = reader.line(forCharacterAt: max(lower, upper - 1), from: node),
       let topLineRange = reader.range(forLine: topLine, from: node),
       let bottomLineRange = reader.range(forLine: bottomLine, from: node)
    {
      lower = min(max(0, topLineRange.location), contentEnd)
      upper = min(max(0, rangeEnd(bottomLineRange)), contentEnd)
    }
    return intersection(
      reportedRange,
      CFRange(location: lower, length: max(0, upper - lower))
    )
  }

  private static func trailingLineRange<Reader: AccessibilityWindowReading>(
    _ reportedRange: CFRange,
    characterCount: Int?,
    lineLimit: Int,
    node: Reader.Node,
    reader: Reader
  ) -> CFRange? {
    guard lineLimit > 0 else { return nil }
    let upper = min(rangeEnd(reportedRange), max(0, characterCount ?? rangeEnd(reportedRange)))
    let lower = min(max(0, reportedRange.location), upper)
    guard upper > lower,
          let finalLine = reader.line(forCharacterAt: upper - 1, from: node)
    else { return nil }
    let firstLine = max(0, finalLine - lineLimit + 1)
    guard firstLine > 0 else {
      return CFRange(location: lower, length: upper - lower)
    }

    var searchLower = lower
    var searchUpper = upper
    while searchLower < searchUpper {
      let middle = searchLower + (searchUpper - searchLower) / 2
      guard let line = reader.line(forCharacterAt: middle, from: node) else { return nil }
      if line < firstLine {
        searchLower = middle + 1
      } else {
        searchUpper = middle
      }
    }
    return CFRange(location: searchLower, length: upper - searchLower)
  }

  private static func intersection(_ lhs: CFRange, _ rhs: CFRange) -> CFRange? {
    let lower = max(lhs.location, rhs.location)
    let upper = min(rangeEnd(lhs), rangeEnd(rhs))
    guard upper > lower else { return nil }
    return CFRange(location: lower, length: upper - lower)
  }

  private static func rangeEnd(_ range: CFRange) -> Int {
    range.location.addingReportingOverflow(range.length).overflow
      ? Int.max
      : range.location + range.length
  }
}

private enum WindowTextVisibilityQuirks {
  static func trailingLineLimit(for applicationIdentifier: String?) -> Int? {
    guard applicationIdentifier?.hasPrefix("com.mitchellh.ghostty") == true else { return nil }
    return 200
  }
}
