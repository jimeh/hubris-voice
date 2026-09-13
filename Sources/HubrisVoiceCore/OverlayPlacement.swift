import Foundation

public struct LayoutPoint: Equatable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public struct LayoutSize: Equatable, Sendable {
  public var width: Double
  public var height: Double

  public init(width: Double, height: Double) {
    self.width = width
    self.height = height
  }
}

public struct LayoutRect: Equatable, Sendable {
  public var origin: LayoutPoint
  public var size: LayoutSize

  public init(origin: LayoutPoint, size: LayoutSize) {
    self.origin = origin
    self.size = size
  }

  public var minX: Double {
    origin.x
  }

  public var midX: Double {
    origin.x + size.width / 2
  }

  public var maxX: Double {
    origin.x + size.width
  }

  public var minY: Double {
    origin.y
  }

  public var midY: Double {
    origin.y + size.height / 2
  }

  public var maxY: Double {
    origin.y + size.height
  }

  public static func fromTopLeft(
    x left: Double,
    y top: Double,
    width: Double,
    height: Double,
    primaryScreenHeight: Double
  ) -> LayoutRect {
    LayoutRect(
      origin: LayoutPoint(
        x: left,
        y: primaryScreenHeight - (top + height)
      ),
      size: LayoutSize(width: width, height: height)
    )
  }
}

public struct OverlayAnchor: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case caret
    case element
    case window
  }

  public let kind: Kind
  public let rect: LayoutRect

  public init(kind: Kind, rect: LayoutRect) {
    self.kind = kind
    self.rect = rect
  }
}

public enum OverlayPlacementPreference: String, CaseIterable, Sendable {
  case automatic
  case bottomOfScreen
  case topOfScreen
}

public struct OverlayPlacement: Equatable, Sendable {
  public var gap: Double
  public var screenInset: Double
  public var edgeMargin: Double

  public init(
    gap: Double = 12,
    screenInset: Double = 44,
    edgeMargin: Double = 8
  ) {
    self.gap = gap
    self.screenInset = screenInset
    self.edgeMargin = edgeMargin
  }

  public func origin(
    anchor: OverlayAnchor?,
    preference: OverlayPlacementPreference,
    panelSize: LayoutSize,
    visibleFrame: LayoutRect
  ) -> LayoutPoint {
    let proposedOrigin: LayoutPoint = switch (preference, anchor) {
    case (.bottomOfScreen, _), (.automatic, nil):
      LayoutPoint(
        x: visibleFrame.midX - panelSize.width / 2,
        y: visibleFrame.minY + screenInset
      )
    case (.topOfScreen, _):
      LayoutPoint(
        x: visibleFrame.midX - panelSize.width / 2,
        y: visibleFrame.maxY - screenInset - panelSize.height
      )
    case (.automatic, .some(let anchor)):
      automaticOrigin(
        anchor: anchor,
        panelSize: panelSize,
        visibleFrame: visibleFrame
      )
    }

    return clamped(
      proposedOrigin,
      panelSize: panelSize,
      visibleFrame: visibleFrame
    )
  }

  private func automaticOrigin(
    anchor: OverlayAnchor,
    panelSize: LayoutSize,
    visibleFrame: LayoutRect
  ) -> LayoutPoint {
    if anchor.kind == .window {
      return LayoutPoint(
        x: anchor.rect.midX - panelSize.width / 2,
        y: anchor.rect.maxY - edgeMargin - panelSize.height
      )
    }

    // The panel's width follows the transcript, so it is aligned to the
    // anchor's left edge rather than centered; centering would shift it with
    // every word.
    let leadingX = anchor.rect.minX
    let aboveY = anchor.rect.maxY + gap
    if aboveY + panelSize.height <= visibleFrame.maxY - edgeMargin {
      return LayoutPoint(x: leadingX, y: aboveY)
    }
    let belowY = anchor.rect.minY - gap - panelSize.height
    if belowY >= visibleFrame.minY + edgeMargin {
      return LayoutPoint(x: leadingX, y: belowY)
    }
    return LayoutPoint(x: leadingX, y: aboveY)
  }

  private func clamped(
    _ origin: LayoutPoint,
    panelSize: LayoutSize,
    visibleFrame: LayoutRect
  ) -> LayoutPoint {
    let minimumX = visibleFrame.minX + edgeMargin
    let minimumY = visibleFrame.minY + edgeMargin
    let maximumX = max(
      minimumX,
      visibleFrame.maxX - edgeMargin - panelSize.width
    )
    let maximumY = max(
      minimumY,
      visibleFrame.maxY - edgeMargin - panelSize.height
    )
    return LayoutPoint(
      x: min(max(origin.x, minimumX), maximumX),
      y: min(max(origin.y, minimumY), maximumY)
    )
  }
}
