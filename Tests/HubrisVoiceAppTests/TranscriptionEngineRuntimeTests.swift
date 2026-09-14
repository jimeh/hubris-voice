import Foundation
@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

@MainActor
final class TranscriptionEngineRuntimeTests: XCTestCase {
  func testDequeuedAudioReleasesMailboxPermit() async {
    let pipe = TranscriptionEngineCommandPipe(capacity: 1)
    let invocationID = TranscriptionInvocationID(epoch: .init(1), generation: 1)
    let first = TranscriptionEngineCommand.append(id: invocationID, sequence: 0, audio: Data([0, 0]))
    let second = TranscriptionEngineCommand.append(id: invocationID, sequence: 1, audio: Data([1, 0]))
    var commands = pipe.stream.makeAsyncIterator()

    XCTAssertTrue(pipe.submit(first))
    XCTAssertFalse(pipe.submit(second))
    let consumed = await commands.next()
    XCTAssertEqual(consumed, first)
    if let consumed {
      pipe.didConsume(consumed)
    }
    XCTAssertTrue(pipe.submit(second))
    pipe.finish()
  }

  func testSaturatedAudioMailboxStillAcceptsOrderedCancellationAndNextInvocation() async {
    let pipe = TranscriptionEngineCommandPipe(capacity: 1)
    let epoch = TranscriptionBackendEpoch(1)
    let firstID = TranscriptionInvocationID(epoch: epoch, generation: 1)
    let secondID = TranscriptionInvocationID(epoch: epoch, generation: 2)
    let first = TranscriptionInvocation(id: firstID, format: .openAI)
    let second = TranscriptionInvocation(id: secondID, format: .openAI)

    XCTAssertTrue(pipe.submit(.begin(first)))
    XCTAssertTrue(pipe.submit(.append(id: firstID, sequence: 0, audio: Data([0, 0]))))
    XCTAssertFalse(pipe.submit(.append(id: firstID, sequence: 1, audio: Data([1, 0]))))
    XCTAssertTrue(pipe.submit(.cancel(id: firstID)))
    XCTAssertTrue(pipe.submit(.begin(second)))
    pipe.finish()

    var commands: [TranscriptionEngineCommand] = []
    var activeID: TranscriptionInvocationID?
    var retired: Set<TranscriptionInvocationID> = []
    for await command in pipe.stream {
      pipe.didConsume(command)
      commands.append(command)
      switch command {
      case .begin(let invocation):
        activeID = invocation.id
      case .cancel(let invocationID):
        retired.insert(invocationID)
        if activeID == invocationID {
          activeID = nil
        }
      case .prepare, .append, .finish:
        break
      }
    }
    XCTAssertEqual(commands, [
      .begin(first),
      .append(id: firstID, sequence: 0, audio: Data([0, 0])),
      .cancel(id: firstID),
      .begin(second),
    ])
    XCTAssertTrue(retired.contains(firstID))
    XCTAssertEqual(activeID, secondID)
  }

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

  func testReleasedCoordinatorCancelsRuntimeEventConsumption() async {
    let runtime = StubTranscriptionEngineRuntime(acceptsCommands: true)
    var coordinator: TranscriptionEngineCoordinator? = TranscriptionEngineCoordinator(
      runtime: runtime,
      epoch: .init(1)
    )
    weak var releasedCoordinator = coordinator

    coordinator = nil

    XCTAssertNil(releasedCoordinator)
    for _ in 0 ..< 20 where !runtime.eventStreamTerminated {
      await Task.yield()
    }
    XCTAssertTrue(runtime.eventStreamTerminated)
  }
}

private final class StubTranscriptionEngineRuntime: TranscriptionEngineRuntime, @unchecked Sendable {
  let events: AsyncStream<TranscriptionEngineEvent>
  private let continuation: AsyncStream<TranscriptionEngineEvent>.Continuation
  private let acceptsCommands: Bool
  private let termination = EventStreamTermination()

  var eventStreamTerminated: Bool {
    termination.value
  }

  init(acceptsCommands: Bool) {
    self.acceptsCommands = acceptsCommands
    let pair = AsyncStream.makeStream(of: TranscriptionEngineEvent.self)
    events = pair.stream
    continuation = pair.continuation
    continuation.onTermination = { [termination] _ in termination.mark() }
  }

  func submit(_: TranscriptionEngineCommand) -> Bool {
    acceptsCommands
  }

  func emit(_ event: TranscriptionEngineEvent) {
    continuation.yield(event)
  }
}

private final class EventStreamTermination: @unchecked Sendable {
  private let lock = NSLock()
  private var terminated = false

  var value: Bool {
    lock.withLock { terminated }
  }

  func mark() {
    lock.withLock { terminated = true }
  }
}
