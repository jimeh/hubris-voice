import Foundation
@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

@MainActor
final class TranscriptionEngineRuntimeTests: XCTestCase {
  func testRejectedCancellationDoesNotSuppressLaterInvocationEvents() async {
    let runtime = StubTranscriptionEngineRuntime(acceptsCommands: false)
    let epoch = TranscriptionBackendEpoch(1)
    let invocationID = TranscriptionInvocationID(epoch: epoch, generation: 1)
    let coordinator = TranscriptionEngineCoordinator(runtime: runtime, epoch: epoch)
    var events = coordinator.events.makeAsyncIterator()

    XCTAssertFalse(coordinator.submit(.cancel(id: invocationID)))
    runtime.emit(.preview(id: invocationID, text: "still active"))
    runtime.emit(.readiness(epoch: epoch, state: .ready))

    let nextEvent = await events.next()
    XCTAssertEqual(nextEvent, .preview(id: invocationID, text: "still active"))
  }

  func testAcceptedCancellationSuppressesLaterInvocationEvents() async {
    let runtime = StubTranscriptionEngineRuntime(acceptsCommands: true)
    let epoch = TranscriptionBackendEpoch(1)
    let invocationID = TranscriptionInvocationID(epoch: epoch, generation: 1)
    let coordinator = TranscriptionEngineCoordinator(runtime: runtime, epoch: epoch)
    var events = coordinator.events.makeAsyncIterator()

    XCTAssertTrue(coordinator.submit(.cancel(id: invocationID)))
    runtime.emit(.preview(id: invocationID, text: "late"))
    runtime.emit(.readiness(epoch: epoch, state: .ready))

    let nextEvent = await events.next()
    XCTAssertEqual(nextEvent, .readiness(epoch: epoch, state: .ready))
  }
}

private final class StubTranscriptionEngineRuntime: TranscriptionEngineRuntime, @unchecked Sendable {
  let events: AsyncStream<TranscriptionEngineEvent>
  private let continuation: AsyncStream<TranscriptionEngineEvent>.Continuation
  private let acceptsCommands: Bool

  init(acceptsCommands: Bool) {
    self.acceptsCommands = acceptsCommands
    let pair = AsyncStream.makeStream(of: TranscriptionEngineEvent.self)
    events = pair.stream
    continuation = pair.continuation
  }

  func submit(_: TranscriptionEngineCommand) -> Bool {
    acceptsCommands
  }

  func emit(_ event: TranscriptionEngineEvent) {
    continuation.yield(event)
  }
}
