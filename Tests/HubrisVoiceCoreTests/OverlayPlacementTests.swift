@testable import HubrisVoiceCore
import XCTest

final class OverlayPlacementTests: XCTestCase {
  private let placement = OverlayPlacement()
  private let visibleFrame = LayoutRect(
    origin: LayoutPoint(x: 100, y: 50),
    size: LayoutSize(width: 1_200, height: 800)
  )
  private let panelSize = LayoutSize(width: 400, height: 180)

  func testBottomOfScreenCentersWithInset() {
    XCTAssertEqual(
      origin(preference: .bottomOfScreen),
      LayoutPoint(x: 500, y: 94)
    )
  }

  func testTopOfScreenSitsBelowInset() {
    XCTAssertEqual(
      origin(preference: .topOfScreen),
      LayoutPoint(x: 500, y: 626)
    )
  }

  func testAutomaticWithoutAnchorMatchesBottomOfScreen() {
    XCTAssertEqual(
      origin(preference: .automatic),
      origin(preference: .bottomOfScreen)
    )
  }

  func testCaretWithRoomAboveUsesGapAndCentersOnCaret() {
    let caret = anchor(.caret, x: 690, y: 300, width: 2, height: 20)

    XCTAssertEqual(
      origin(anchor: caret),
      LayoutPoint(x: 491, y: 332)
    )
  }

  func testCaretNearTopFlipsBelow() {
    let caret = anchor(.caret, x: 690, y: 760, width: 2, height: 20)

    XCTAssertEqual(
      origin(anchor: caret),
      LayoutPoint(x: 491, y: 568)
    )
  }

  func testElementNearLeftEdgeClampsToMargin() {
    let element = anchor(.element, x: 105, y: 300, width: 80, height: 40)

    XCTAssertEqual(origin(anchor: element).x, 108)
  }

  func testAnchorWithoutRoomUsesAboveAndClampsToTopMargin() {
    let shortFrame = LayoutRect(
      origin: LayoutPoint(x: 0, y: 0),
      size: LayoutSize(width: 500, height: 250)
    )
    let element = anchor(.element, x: 200, y: 100, width: 100, height: 50)

    XCTAssertEqual(
      placement.origin(
        anchor: element,
        preference: .automatic,
        panelSize: LayoutSize(width: 200, height: 180),
        visibleFrame: shortFrame
      ),
      LayoutPoint(x: 150, y: 62)
    )
  }

  func testWindowAnchorPlacesInsideWindowNearTop() {
    let window = anchor(.window, x: 250, y: 150, width: 900, height: 600)

    XCTAssertEqual(
      origin(anchor: window),
      LayoutPoint(x: 500, y: 562)
    )
  }

  func testZeroWidthPositiveHeightCaretIsPlaced() {
    let caret = anchor(.caret, x: 700, y: 300, width: 0, height: 20)

    XCTAssertEqual(
      origin(anchor: caret),
      LayoutPoint(x: 500, y: 332)
    )
  }

  func testTopLeftConversionHandlesPrimaryAndScreenAbovePrimary() {
    XCTAssertEqual(
      LayoutRect.fromTopLeft(
        x: 40,
        y: 100,
        width: 80,
        height: 20,
        primaryScreenHeight: 900
      ),
      LayoutRect(
        origin: LayoutPoint(x: 40, y: 780),
        size: LayoutSize(width: 80, height: 20)
      )
    )
    XCTAssertEqual(
      LayoutRect.fromTopLeft(
        x: 40,
        y: -700,
        width: 80,
        height: 20,
        primaryScreenHeight: 900
      ),
      LayoutRect(
        origin: LayoutPoint(x: 40, y: 1_580),
        size: LayoutSize(width: 80, height: 20)
      )
    )
  }

  func testGrowthKeepsEdgeNearestAnchorFixed() {
    let above = anchor(.caret, x: 690, y: 300, width: 2, height: 20)
    let aboveShort = origin(anchor: above, panelHeight: 100)
    let aboveTall = origin(anchor: above, panelHeight: 200)
    XCTAssertEqual(aboveShort.y, aboveTall.y)

    let below = anchor(.caret, x: 690, y: 760, width: 2, height: 20)
    let belowShort = origin(anchor: below, panelHeight: 100)
    let belowTall = origin(anchor: below, panelHeight: 200)
    XCTAssertEqual(belowShort.y + 100, belowTall.y + 200)
  }

  private func origin(
    anchor: OverlayAnchor? = nil,
    preference: OverlayPlacementPreference = .automatic,
    panelHeight: Double? = nil
  ) -> LayoutPoint {
    placement.origin(
      anchor: anchor,
      preference: preference,
      panelSize: LayoutSize(
        width: panelSize.width,
        height: panelHeight ?? panelSize.height
      ),
      visibleFrame: visibleFrame
    )
  }

  private func anchor(
    _ kind: OverlayAnchor.Kind,
    x: Double,
    y: Double,
    width: Double,
    height: Double
  ) -> OverlayAnchor {
    OverlayAnchor(
      kind: kind,
      rect: LayoutRect(
        origin: LayoutPoint(x: x, y: y),
        size: LayoutSize(width: width, height: height)
      )
    )
  }
}
