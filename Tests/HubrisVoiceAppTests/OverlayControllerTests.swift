@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

@MainActor
final class OverlayControllerTests: XCTestCase {
  func testPreviewRemovesOnlyLeadingWhitespaceAcrossStreamUpdates() {
    let model = OverlayViewModel()
    model.apply(OverlayPresentation(mode: .listening, transcript: " \n\tHello ", message: "", pendingCount: 0))
    XCTAssertEqual(model.transcript, "Hello ")

    model.apply(OverlayPresentation(
      mode: .listening,
      transcript: " \n\tHello world\n  Next line",
      message: "",
      pendingCount: 0
    ))
    XCTAssertEqual(model.transcript, "Hello world\n  Next line")

    model.apply(OverlayPresentation(
      mode: .finalizing,
      transcript: "Hello world\n  Next line",
      message: "",
      pendingCount: 0
    ))
    XCTAssertEqual(model.transcript, "Hello world\n  Next line")
  }

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
