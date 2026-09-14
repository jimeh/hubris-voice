@testable import HubrisVoiceCore
import XCTest

final class RealtimeConnectionHandshakeTests: XCTestCase {
  func testWaitForOpenDoesNotCompleteUntilConnectionOpens() async throws {
    let handshake = RealtimeConnectionHandshake()
    let probe = CompletionProbe()

    let waitTask = Task {
      try await handshake.waitForOpen(timeout: .seconds(1))
      await probe.markCompleted()
    }

    let didStartWaiting = await waitUntilWaiting(handshake)
    XCTAssertTrue(didStartWaiting)
    let completedBeforeOpen = await probe.isCompleted
    XCTAssertFalse(completedBeforeOpen)

    await handshake.open()
    try await waitTask.value

    let completedAfterOpen = await probe.isCompleted
    XCTAssertTrue(completedAfterOpen)
  }

  func testWaitForOpenThrowsHandshakeFailure() async {
    let handshake = RealtimeConnectionHandshake()
    let expected = RealtimeConnectionFailure.rejected(
      statusCode: 403,
      requestID: "request-123"
    )

    await handshake.fail(expected)

    do {
      try await handshake.waitForOpen(timeout: .seconds(1))
      XCTFail("Expected the stored handshake failure")
    } catch let error as RealtimeConnectionFailure {
      XCTAssertEqual(error, expected)
      XCTAssertEqual(
        error.localizedDescription,
        "OpenAI rejected the Realtime WebSocket handshake "
          + "(HTTP 403, request request-123)."
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testWaitForOpenTimesOut() async {
    let handshake = RealtimeConnectionHandshake()

    do {
      try await handshake.waitForOpen(timeout: .milliseconds(10))
      XCTFail("Expected the WebSocket handshake to time out")
    } catch let error as RealtimeConnectionFailure {
      XCTAssertEqual(error, .timedOut)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testFailureDescriptionsPreserveCloseAndTransportDetails() {
    XCTAssertEqual(
      RealtimeConnectionFailure.closed(
        code: 1_008,
        reason: "Policy violation"
      ).localizedDescription,
      "OpenAI closed the Realtime WebSocket before it opened "
        + "(code 1008: Policy violation)."
    )
    XCTAssertEqual(
      RealtimeConnectionFailure.transport(
        message: "The network connection was lost."
      ).localizedDescription,
      "OpenAI Realtime connection failed before the WebSocket opened: "
        + "The network connection was lost."
    )
  }
}

private func waitUntilWaiting(
  _ handshake: RealtimeConnectionHandshake,
  timeout: Duration = .seconds(1)
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await handshake.isWaitingForOpen {
      return true
    }
    await Task.yield()
  }
  return await handshake.isWaitingForOpen
}

private actor CompletionProbe {
  private(set) var isCompleted = false

  func markCompleted() {
    isCompleted = true
  }
}
