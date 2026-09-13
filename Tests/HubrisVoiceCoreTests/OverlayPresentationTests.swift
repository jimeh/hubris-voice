@testable import HubrisVoiceCore
import XCTest

final class OverlayPresentationTests: XCTestCase {
  func testVisibleLinesClampBetweenOneAndTheCap() {
    let threeLines = PillLayoutPolicy(lineCap: 3)
    XCTAssertEqual(threeLines.visibleLines(measuredLines: 0), 1)
    XCTAssertEqual(threeLines.visibleLines(measuredLines: 1), 1)
    XCTAssertEqual(threeLines.visibleLines(measuredLines: 3), 3)
    XCTAssertEqual(threeLines.visibleLines(measuredLines: 4), 3)

    let singleLine = PillLayoutPolicy(lineCap: 1)
    XCTAssertTrue(singleLine.isSingleLine)
    XCTAssertFalse(threeLines.isSingleLine)
    XCTAssertEqual(singleLine.visibleLines(measuredLines: 5), 1)
  }

  func testPanelSizeFollowsTextUpToTheMaximumWidth() {
    let policy = PillLayoutPolicy()

    XCTAssertEqual(
      policy.panelSize(measuredTextWidth: 0, measuredLines: 0),
      LayoutSize(width: 52, height: 42)
    )
    XCTAssertEqual(
      policy.panelSize(measuredTextWidth: 100, measuredLines: 1),
      LayoutSize(width: 164, height: 42)
    )
    XCTAssertEqual(
      policy.panelSize(measuredTextWidth: 900, measuredLines: 8),
      LayoutSize(width: 440, height: 86)
    )
    XCTAssertEqual(policy.maximumTextWidth, 376)
  }

  func testMessageHeightIsAddedBelowTheTranscript() {
    let policy = PillLayoutPolicy()

    XCTAssertEqual(
      policy.panelSize(measuredTextWidth: 100, measuredLines: 1, messageHeight: 18).height,
      60
    )
  }

  func testDelayedActionRunsAfterDelay() async {
    let scheduler = await DelayedActionScheduler()
    let probe = CompletionProbe()

    await scheduler.schedule(after: .milliseconds(10)) {
      Task {
        await probe.markCompleted()
      }
    }

    let didComplete = await waitUntilCompleted(probe)
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

    try? await Task.sleep(for: .milliseconds(100))
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

    let replacementDidComplete = await waitUntilCompleted(replacementProbe)
    try? await Task.sleep(for: .milliseconds(80))
    let firstDidComplete = await firstProbe.isCompleted
    XCTAssertFalse(firstDidComplete)
    XCTAssertTrue(replacementDidComplete)
  }
}

private func waitUntilCompleted(
  _ probe: CompletionProbe,
  timeout: Duration = .seconds(1)
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await probe.isCompleted {
      return true
    }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await probe.isCompleted
}

private actor CompletionProbe {
  private(set) var isCompleted = false

  func markCompleted() {
    isCompleted = true
  }
}
