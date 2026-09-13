@testable import HubrisVoiceApp
import XCTest

@MainActor
final class CaptureFinalizerTests: XCTestCase {
  func testGraceAudioPrecedesCommitAndNewCapture() {
    let finalizer = CaptureFinalizer()
    var events = ["audio"]
    finalizer.schedule(generation: 1) { events.append("stop") }
    finalizer.commitAfterStop(generation: 1) { events.append("commit") }
    events.append("tail audio")
    XCTAssertEqual(events, ["audio", "tail audio"])
    // Starting another capture explicitly drains the previous grace period.
    finalizer.finish()
    events.append("new capture")
    XCTAssertEqual(events, ["audio", "tail audio", "stop", "commit", "new capture"])
    finalizer.finish()
    XCTAssertEqual(events.count, 5)
  }

  func testReplayCommitIsNotDelayedByAnotherGeneration() {
    let finalizer = CaptureFinalizer()
    var events: [String] = []
    finalizer.schedule(generation: 2) { events.append("stop 2") }
    finalizer.commitAfterStop(generation: 1) { events.append("commit 1") }
    XCTAssertEqual(events, ["commit 1"])
    finalizer.finish()
    XCTAssertEqual(events, ["commit 1", "stop 2"])
  }
}
