@testable import HubrisVoiceApp
import XCTest

@MainActor
final class OverlayControllerTests: XCTestCase {
  func testTranscriptGrowthStopsAtTheLineCapAndKeepsTheBottomEdge() {
    let model = OverlayViewModel()
    let controller = OverlayController(model: model)
    controller.lineCap = 3
    controller.show(anchor: nil, preference: .bottomOfScreen)
    let oneLine = controller.panelFrame
    let lineHeight = PillLayout.lineHeight

    model.transcript = String(repeating: "A growing transcript. ", count: 30)

    XCTAssertTrue(controller.hostingSizingOptions.isEmpty)
    XCTAssertEqual(controller.panelFrame.height, oneLine.height + 2 * lineHeight, accuracy: 0.5)
    XCTAssertEqual(controller.panelFrame.minY, oneLine.minY)
    XCTAssertTrue(model.overflows)
  }

  func testSingleLineCapNeverGrowsTall() {
    let model = OverlayViewModel()
    let controller = OverlayController(model: model)
    controller.lineCap = 1
    controller.show(anchor: nil, preference: .bottomOfScreen)
    let oneLine = controller.panelFrame

    model.transcript = String(repeating: "A growing transcript. ", count: 30)

    XCTAssertEqual(controller.panelFrame.height, oneLine.height)
    XCTAssertTrue(model.overflows)
  }
}
