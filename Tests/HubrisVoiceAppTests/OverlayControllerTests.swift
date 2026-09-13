@testable import HubrisVoiceApp
import XCTest

@MainActor
final class OverlayControllerTests: XCTestCase {
  func testTranscriptGrowthLeavesWindowSizingToTheController() {
    let model = OverlayViewModel()
    let controller = OverlayController(model: model)
    controller.show(
      anchor: nil,
      preference: .bottomOfScreen
    )
    let initialBottomEdge = controller.panelFrame.minY

    model.transcript = String(repeating: "A growing transcript. ", count: 30)

    XCTAssertTrue(controller.hostingSizingOptions.isEmpty)
    XCTAssertGreaterThan(controller.panelFrame.height, 178)
    XCTAssertEqual(controller.panelFrame.minY, initialBottomEdge)
  }
}
