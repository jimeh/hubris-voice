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
    let sleeper = ControlledSleeper()
    let scheduler = await DelayedActionScheduler {
      try await sleeper.sleep(for: $0)
    }
    let probe = CompletionProbe()

    await scheduler.schedule(after: .milliseconds(10)) {
      probe.markCompleted()
    }

    let didStartSleeping = await sleeper.waitUntilStarted(count: 1)
    XCTAssertTrue(didStartSleeping)
    let requestedDurations = await sleeper.requestedDurations
    XCTAssertEqual(requestedDurations, [.milliseconds(10)])
    let didCompleteImmediately = await probe.isCompleted
    XCTAssertFalse(didCompleteImmediately)
    await sleeper.advanceAll()
    let didComplete = await waitUntilCompleted(probe)
    XCTAssertTrue(didComplete)
  }

  func testDelayedActionCanBeCancelled() async {
    let sleeper = ControlledSleeper()
    let scheduler = await DelayedActionScheduler {
      try await sleeper.sleep(for: $0)
    }
    let probe = CompletionProbe()
    let barrier = CompletionProbe()

    await scheduler.schedule(after: .milliseconds(10)) {
      probe.markCompleted()
    }
    let didStartSleeping = await sleeper.waitUntilStarted(count: 1)
    XCTAssertTrue(didStartSleeping)
    await scheduler.cancel()
    await scheduler.schedule(after: .milliseconds(10)) {
      barrier.markCompleted()
    }
    let didStartBarrier = await sleeper.waitUntilStarted(count: 2)
    XCTAssertTrue(didStartBarrier)
    let requestedDurations = await sleeper.requestedDurations
    XCTAssertEqual(requestedDurations, [.milliseconds(10), .milliseconds(10)])

    await sleeper.advanceAll()
    let didCompleteBarrier = await waitUntilCompleted(barrier)
    XCTAssertTrue(didCompleteBarrier)
    let didCompleteCancelledAction = await probe.isCompleted
    XCTAssertFalse(didCompleteCancelledAction)
  }

  func testSchedulingAgainReplacesPendingAction() async {
    let sleeper = ControlledSleeper()
    let scheduler = await DelayedActionScheduler {
      try await sleeper.sleep(for: $0)
    }
    let firstProbe = CompletionProbe()
    let replacementProbe = CompletionProbe()

    await scheduler.schedule(after: .milliseconds(40)) {
      firstProbe.markCompleted()
    }
    let didStartFirstSleep = await sleeper.waitUntilStarted(count: 1)
    XCTAssertTrue(didStartFirstSleep)
    await scheduler.schedule(after: .milliseconds(10)) {
      replacementProbe.markCompleted()
    }
    let didStartReplacementSleep = await sleeper.waitUntilStarted(count: 2)
    XCTAssertTrue(didStartReplacementSleep)
    let requestedDurations = await sleeper.requestedDurations
    XCTAssertEqual(requestedDurations, [.milliseconds(40), .milliseconds(10)])

    await sleeper.advanceAll()
    let replacementDidComplete = await waitUntilCompleted(replacementProbe)
    let firstDidComplete = await firstProbe.isCompleted
    XCTAssertFalse(firstDidComplete)
    XCTAssertTrue(replacementDidComplete)
  }
}

private actor ControlledSleeper {
  private var nextID = 0
  private(set) var requestedDurations: [Duration] = []
  private var continuations: [Int: CheckedContinuation<Void, any Error>] = [:]

  func sleep(for duration: Duration) async throws {
    let sleepID = nextID
    nextID += 1
    requestedDurations.append(duration)
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        continuations[sleepID] = continuation
      }
    } onCancel: {
      Task { await self.cancel(sleepID: sleepID) }
    }
  }

  func waitUntilStarted(count: Int, timeout: Duration = .seconds(1)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while requestedDurations.count < count, clock.now < deadline {
      await Task.yield()
    }
    return requestedDurations.count >= count
  }

  func advanceAll() {
    let pending = continuations.values
    continuations.removeAll()
    pending.forEach { $0.resume() }
  }

  private func cancel(sleepID: Int) {
    continuations.removeValue(forKey: sleepID)?.resume(throwing: CancellationError())
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

@MainActor
private final class CompletionProbe {
  private(set) var isCompleted = false

  func markCompleted() {
    isCompleted = true
  }
}
