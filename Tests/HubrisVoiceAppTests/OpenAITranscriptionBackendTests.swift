@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

final class OpenAITranscriptionBackendTests: XCTestCase {
  func testBackendDeallocatesWithoutExplicitShutdown() async {
    var backend: OpenAITranscriptionBackend? = OpenAITranscriptionBackend(
      apiKey: "",
      configuration: .init(languages: [], prompt: "", keywords: [], delay: .low)
    )
    weak var releasedBackend = backend

    backend = nil
    for _ in 0 ..< 20 where releasedBackend != nil {
      await Task.yield()
    }

    XCTAssertNil(releasedBackend)
  }

  func testPrecommitDeltasBecomeWholePreviewSnapshots() async throws {
    let fixture = await Fixture.make()
    await fixture.backend.testingHandle(.begin(fixture.invocation(0)))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "live", delta: "Ship "))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "live", delta: "it"))

    let first = try await fixture.next()
    let second = try await fixture.next()
    XCTAssertEqual(first, .preview(id: fixture.id(0), text: "Ship "))
    XCTAssertEqual(second, .preview(id: fixture.id(0), text: "Ship it"))
  }

  func testLateAcknowledgementForCancelledCommitCannotClaimNextInvocation() async throws {
    let fixture = await Fixture.make()
    let old = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(old))
    await fixture.backend.testingHandle(.finish(id: old.id))
    await fixture.backend.testingHandle(.cancel(id: old.id))
    await fixture.backend.testingReceive(.inputCommitted(itemID: "old-item"))

    let next = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(next))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "old-item", delta: "Old"))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "new-item", delta: "New"))
    let event = try await fixture.next()
    XCTAssertEqual(event, .preview(id: next.id, text: "New"))
  }

  func testRejectedCommitDoesNotConsumeNextAcknowledgement() async throws {
    let fixture = await Fixture.make()
    let rejected = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(rejected))
    await fixture.backend.testingHandle(.finish(id: rejected.id))
    let maybeEventID = await fixture.backend.testingCommitEventID(for: rejected.id)
    let eventID = try XCTUnwrap(maybeEventID)
    await fixture.backend.testingReceive(.error(message: "Empty buffer", eventID: eventID))
    let failureEvent = try await fixture.next()
    guard case .failure(_, let failedID?, let failure) = failureEvent else {
      return XCTFail("Expected a targeted failure")
    }
    XCTAssertEqual(failedID, rejected.id)
    XCTAssertEqual(failure.message, "Empty buffer")

    let next = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(next))
    await fixture.backend.testingHandle(.finish(id: next.id))
    await fixture.backend.testingReceive(.inputCommitted(itemID: "next-item"))
    await fixture.backend.testingReceive(.transcriptCompleted(itemID: "next-item", transcript: "Recovered"))
    let event = try await fixture.next()
    XCTAssertEqual(
      event,
      .final(id: next.id, result: .init(text: "Recovered", correction: .disabled))
    )
  }

  func testReconnectClearsPreviewAndUsesNewItemIdentity() async throws {
    let fixture = await Fixture.make()
    let invocation = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(invocation))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "old", delta: "old preview"))
    _ = try await fixture.next()
    await fixture.backend.testingResetForReconnect()
    let cleared = try await fixture.next()
    XCTAssertEqual(cleared, .preview(id: invocation.id, text: ""))

    await fixture.backend.testingSetReady(epoch: fixture.epoch)
    _ = try await fixture.next()
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "new", delta: "new preview"))
    let replayed = try await fixture.next()
    XCTAssertEqual(replayed, .preview(id: invocation.id, text: "new preview"))
  }

  func testReconnectReplaysMoreThanMailboxCapacityAndCommitsInOrder() async throws {
    let fixture = await Fixture.make(outboundCapacity: 512, consumesOutboundActions: false)
    await fixture.backend.testingResetForReconnect()

    let invocation = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(invocation))
    for sequence in 0 ..< 600 {
      await fixture.backend.testingHandle(.append(
        id: invocation.id,
        sequence: sequence,
        audio: Data("chunk-\(sequence)".utf8)
      ))
    }
    await fixture.backend.testingHandle(.finish(id: invocation.id))

    await fixture.backend.testingSetReady(epoch: fixture.epoch)
    _ = try await fixture.next()

    let maybeCommitEventID = await fixture.backend.testingCommitEventID(for: invocation.id)
    let hasInvocation = await fixture.backend.testingHasInvocation(invocation.id)
    _ = try XCTUnwrap(maybeCommitEventID)
    XCTAssertTrue(hasInvocation)

    await fixture.backend.testingReceive(.inputCommitted(itemID: "replayed-item"))
    await fixture.backend.testingReceive(
      .transcriptCompleted(itemID: "replayed-item", transcript: "Complete replay")
    )
    let event = try await fixture.next()
    XCTAssertEqual(
      event,
      .final(id: invocation.id, result: .init(text: "Complete replay", correction: .disabled))
    )
  }

  func testCompletionsRouteOutOfOrderByProviderItemIdentity() async throws {
    let fixture = await Fixture.make()
    let first = fixture.invocation(0)
    let second = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(first))
    await fixture.backend.testingHandle(.finish(id: first.id))
    await fixture.backend.testingHandle(.begin(second))
    await fixture.backend.testingHandle(.finish(id: second.id))
    await fixture.backend.testingReceive(.inputCommitted(itemID: "first"))
    await fixture.backend.testingReceive(.inputCommitted(itemID: "second"))
    await fixture.backend.testingReceive(.transcriptCompleted(itemID: "second", transcript: "two"))
    await fixture.backend.testingReceive(.transcriptCompleted(itemID: "first", transcript: "one"))
    let secondEvent = try await fixture.next()
    let firstEvent = try await fixture.next()
    XCTAssertEqual(
      secondEvent,
      .final(id: second.id, result: .init(text: "two", correction: .disabled))
    )
    XCTAssertEqual(
      firstEvent,
      .final(id: first.id, result: .init(text: "one", correction: .disabled))
    )
  }

  func testShutdownIsTerminalAcrossDelayedEntryPoints() async {
    let configuration = RealtimeSessionConfiguration(
      languages: [],
      prompt: "",
      keywords: [],
      delay: .low
    )
    let backend = OpenAITranscriptionBackend(
      apiKey: "test-key",
      configuration: configuration
    )
    let epoch = TranscriptionBackendEpoch(1)

    await backend.shutdown()
    await backend.shutdown()
    XCTAssertFalse(backend.submit(.prepare(epoch: epoch)))
    await backend.testingHandle(.prepare(epoch: epoch))
    await backend.updateCredentials("replacement-key")
    await backend.requestReconnect()
    let updated = await backend.updateConfiguration(configuration, reconnect: true)

    XCTAssertFalse(updated)
    let isInactive = await backend.testingIsTransportInactive()
    XCTAssertTrue(isInactive)
    var iterator = backend.events.makeAsyncIterator()
    let trailingEvent = await iterator.next()
    XCTAssertNil(trailingEvent)
  }

  func testOutboundRejectionRetiresInvocationAndConnection() async throws {
    let fixture = await Fixture.make(outboundCapacity: 0, consumesOutboundActions: false)
    let survivor = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(survivor))
    let invocation = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(invocation))
    await fixture.backend.testingHandle(.append(
      id: invocation.id,
      sequence: 0,
      audio: Data([1])
    ))

    let failureEvent = try await fixture.next()
    guard case .failure(_, let failedID, _) = failureEvent else {
      return XCTFail("Expected a targeted transport failure")
    }
    XCTAssertEqual(failedID, invocation.id)
    let hasFailedInvocation = await fixture.backend.testingHasInvocation(invocation.id)
    let hasSurvivingInvocation = await fixture.backend.testingHasInvocation(survivor.id)
    let hasActiveAttempt = await fixture.backend.testingHasActiveAttempt()
    XCTAssertFalse(hasFailedInvocation)
    XCTAssertTrue(hasSurvivingInvocation)
    XCTAssertFalse(hasActiveAttempt)
    await fixture.backend.shutdown()
  }

  func testRejectedCancelledCommitRemovesInvocation() async throws {
    let fixture = await Fixture.make()
    let invocation = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(invocation))
    await fixture.backend.testingHandle(.finish(id: invocation.id))
    let maybeEventID = await fixture.backend.testingCommitEventID(for: invocation.id)
    let eventID = try XCTUnwrap(maybeEventID)
    await fixture.backend.testingHandle(.cancel(id: invocation.id))
    await fixture.backend.testingReceive(.error(message: "Empty buffer", eventID: eventID))

    let hasCancelledInvocation = await fixture.backend.testingHasInvocation(invocation.id)
    XCTAssertFalse(hasCancelledInvocation)
  }
}

private struct Fixture: Sendable {
  let epoch = TranscriptionBackendEpoch(11)
  let backend: OpenAITranscriptionBackend
  let recorder: OpenAIEventRecorder

  static func make(
    outboundCapacity: Int = 512,
    consumesOutboundActions: Bool = true
  ) async -> Self {
    let backend = OpenAITranscriptionBackend(
      apiKey: "test-key",
      configuration: .init(languages: [], prompt: "", keywords: [], delay: .low),
      outboundCapacity: outboundCapacity,
      consumesOutboundActions: consumesOutboundActions
    )
    let recorder = OpenAIEventRecorder(events: backend.events)
    let fixture = Self(backend: backend, recorder: recorder)
    await backend.testingSetReady(epoch: fixture.epoch)
    _ = try? await fixture.next()
    return fixture
  }

  func id(_ generation: Int) -> TranscriptionInvocationID {
    .init(epoch: epoch, generation: generation)
  }

  func invocation(_ generation: Int) -> TranscriptionInvocation {
    .init(id: id(generation), format: .openAI)
  }

  func next() async throws -> TranscriptionEngineEvent {
    try await recorder.next()
  }
}

private actor OpenAIEventRecorder {
  private var events: [TranscriptionEngineEvent] = []
  private var waiters: [CheckedContinuation<TranscriptionEngineEvent, Never>] = []

  init(events: AsyncStream<TranscriptionEngineEvent>) {
    Task { [weak self] in
      for await event in events {
        await self?.record(event)
      }
    }
  }

  func next() async throws -> TranscriptionEngineEvent {
    if !events.isEmpty {
      return events.removeFirst()
    }
    return await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  private func record(_ event: TranscriptionEngineEvent) {
    if !waiters.isEmpty {
      waiters.removeFirst().resume(returning: event)
    } else {
      events.append(event)
    }
  }
}
