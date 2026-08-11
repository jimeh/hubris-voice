@testable import HubrisVoiceCore
import XCTest

final class OverlayPresentationTests: XCTestCase {
  func testLayoutGrowsWithTranscriptBeforeCappingItsViewport() {
    let layout = OverlayLayoutPolicy(
      minimumTranscriptHeight: 44,
      maximumTranscriptHeight: 132,
      panelChromeHeight: 134
    )

    XCTAssertEqual(
      layout.transcriptViewportHeight(measuredTextHeight: 20),
      44
    )
    XCTAssertEqual(
      layout.transcriptViewportHeight(measuredTextHeight: 96),
      96
    )
    XCTAssertEqual(
      layout.transcriptViewportHeight(measuredTextHeight: 240),
      132
    )
    XCTAssertEqual(layout.panelHeight(measuredTextHeight: 20), 178)
    XCTAssertEqual(layout.panelHeight(measuredTextHeight: 240), 266)
  }

  func testDelayedActionRunsAfterDelay() async {
    let scheduler = await DelayedActionScheduler()
    let probe = CompletionProbe()

    await scheduler.schedule(after: .milliseconds(10)) {
      Task {
        await probe.markCompleted()
      }
    }

    try? await Task.sleep(for: .milliseconds(40))
    let didComplete = await probe.isCompleted
    XCTAssertTrue(didComplete)
  }

  func testDelayedActionCanBeCancelled() async {
    let scheduler = await DelayedActionScheduler()
    let probe = CompletionProbe()

    await scheduler.schedule(after: .milliseconds(10)) {
      Task {
        await probe.markCompleted()
      }
    }
    await scheduler.cancel()

    try? await Task.sleep(for: .milliseconds(40))
    let didComplete = await probe.isCompleted
    XCTAssertFalse(didComplete)
  }

  func testSchedulingAgainReplacesPendingAction() async {
    let scheduler = await DelayedActionScheduler()
    let firstProbe = CompletionProbe()
    let replacementProbe = CompletionProbe()

    await scheduler.schedule(after: .milliseconds(40)) {
      Task {
        await firstProbe.markCompleted()
      }
    }
    await scheduler.schedule(after: .milliseconds(10)) {
      Task {
        await replacementProbe.markCompleted()
      }
    }

    try? await Task.sleep(for: .milliseconds(70))
    let firstDidComplete = await firstProbe.isCompleted
    let replacementDidComplete = await replacementProbe.isCompleted
    XCTAssertFalse(firstDidComplete)
    XCTAssertTrue(replacementDidComplete)
  }
}

private actor CompletionProbe {
  private(set) var isCompleted = false

  func markCompleted() {
    isCompleted = true
  }
}
