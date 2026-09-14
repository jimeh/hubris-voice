@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

final class OpenAITranscriptionBackendTests: XCTestCase {
  func testBackendDeallocatesWithoutExplicitShutdown() {
    var backend: OpenAITranscriptionBackend? = OpenAITranscriptionBackend(
      apiKey: "",
      configuration: .init(languages: [], prompt: "", keywords: [], delay: .low)
    )
    weak var releasedBackend: OpenAITranscriptionBackend?
    releasedBackend = backend

    backend = nil
    XCTAssertNil(releasedBackend)
  }

  func testRecorderTimesOutWhenEventDoesNotArrive() async {
    let recorder = OpenAIEventRecorder(events: AsyncStream { _ in })

    do {
      _ = try await recorder.next(timeout: .milliseconds(20))
      XCTFail("Expected the recorder to time out")
    } catch OpenAIEventRecorderError.timedOut {
    } catch {
      XCTFail("Expected a recorder timeout, got \(error)")
    }
  }

  func testEmptyLiveInvocationCompletesLocallyWithoutCommit() async throws {
    let fixture = await Fixture.make()
    let invocation = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(invocation))
    await fixture.backend.testingHandle(.finish(id: invocation.id))

    let event = try await fixture.next()
    XCTAssertEqual(
      event,
      .final(id: invocation.id, result: .init(text: "", correction: .disabled))
    )
    let commitEventID = await fixture.backend.testingCommitEventID(for: invocation.id)
    let hasInvocation = await fixture.backend.testingHasInvocation(invocation.id)
    XCTAssertNil(commitEventID)
    XCTAssertFalse(hasInvocation)
  }

  func testEmptyOfflineInvocationCompletesLocallyBeforeReconnect() async throws {
    let fixture = await Fixture.make()
    await fixture.backend.testingResetForReconnect()
    let invocation = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(invocation))
    await fixture.backend.testingHandle(.finish(id: invocation.id))

    let event = try await fixture.next()
    XCTAssertEqual(
      event,
      .final(id: invocation.id, result: .init(text: "", correction: .disabled))
    )
    let commitEventID = await fixture.backend.testingCommitEventID(for: invocation.id)
    let hasInvocation = await fixture.backend.testingHasInvocation(invocation.id)
    XCTAssertNil(commitEventID)
    XCTAssertFalse(hasInvocation)

    await fixture.backend.testingSetReady(epoch: fixture.epoch)
    _ = try await fixture.next()
    do {
      _ = try await fixture.next(timeout: .milliseconds(30))
      XCTFail("An empty invocation must not be replayed after local completion")
    } catch OpenAIEventRecorderError.timedOut {}
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
    await fixture.backend.testingHandle(.append(id: old.id, sequence: 0, audio: Data([1])))
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

  func testPrecommitDeltasRemainSeparatedUntilOlderCommitIsAcknowledged() async throws {
    let fixture = await Fixture.make()
    let old = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(old))
    await fixture.backend.testingHandle(.append(id: old.id, sequence: 0, audio: Data([1])))
    await fixture.backend.testingHandle(.finish(id: old.id))

    let next = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(next))
    await fixture.backend.testingHandle(.append(id: next.id, sequence: 0, audio: Data([2])))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "old-item", delta: "Old"))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "new-item", delta: "New "))
    await fixture.backend.testingReceive(.inputCommitted(itemID: "old-item"))

    let oldPreview = try await fixture.next()
    let nextPreview = try await fixture.next()
    XCTAssertEqual(oldPreview, .preview(id: old.id, text: "Old"))
    XCTAssertEqual(nextPreview, .preview(id: next.id, text: "New "))

    await fixture.backend.testingReceive(.transcriptDelta(itemID: "new-item", delta: "words"))
    let completedPreview = try await fixture.next()
    XCTAssertEqual(completedPreview, .preview(id: next.id, text: "New words"))
  }

  func testCancellingUnassignedInputFencesItsBufferedProviderItem() async throws {
    let fixture = await Fixture.make()
    let old = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(old))
    await fixture.backend.testingHandle(.append(id: old.id, sequence: 0, audio: Data([1])))
    await fixture.backend.testingHandle(.finish(id: old.id))

    let cancelled = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(cancelled))
    await fixture.backend.testingHandle(.append(id: cancelled.id, sequence: 0, audio: Data([2])))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "old-item", delta: "Old"))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "cancelled-item", delta: "Stale"))
    await fixture.backend.testingHandle(.cancel(id: cancelled.id))
    await fixture.backend.testingReceive(.inputCommitted(itemID: "old-item"))
    await fixture.backend.testingReceive(
      .transcriptCompleted(itemID: "old-item", transcript: "Older final")
    )
    let olderFinal = try await fixture.next()
    XCTAssertEqual(
      olderFinal,
      .final(id: old.id, result: .init(text: "Older final", correction: .disabled))
    )

    let replacement = fixture.invocation(2)
    await fixture.backend.testingHandle(.begin(replacement))
    await fixture.backend.testingHandle(.append(id: replacement.id, sequence: 0, audio: Data([3])))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "cancelled-item", delta: " stale"))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "replacement-item", delta: "Fresh"))

    let preview = try await fixture.next()
    XCTAssertEqual(preview, .preview(id: replacement.id, text: "Fresh"))
  }

  func testAmbiguousProviderItemOverflowDropsUnknownPreviewWithoutMisattribution() async throws {
    let fixture = await Fixture.make()
    for generation in 0 ..< 7 {
      let invocation = fixture.invocation(generation)
      await fixture.backend.testingHandle(.begin(invocation))
      await fixture.backend.testingHandle(.append(
        id: invocation.id,
        sequence: 0,
        audio: Data([UInt8(generation)])
      ))
      await fixture.backend.testingHandle(.finish(id: invocation.id))
    }
    let active = fixture.invocation(7)
    await fixture.backend.testingHandle(.begin(active))
    await fixture.backend.testingHandle(.append(id: active.id, sequence: 0, audio: Data([2])))

    for index in 0 ... 8 {
      await fixture.backend.testingReceive(
        .transcriptDelta(itemID: "ambiguous-\(index)", delta: "\(index)")
      )
    }
    for generation in 0 ..< 7 {
      await fixture.backend.testingReceive(.inputCommitted(itemID: "ambiguous-\(generation)"))
      let oldPreview = try await fixture.next()
      XCTAssertEqual(
        oldPreview,
        .preview(id: fixture.id(generation), text: "\(generation)")
      )
    }
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "active", delta: "Wrong"))

    do {
      _ = try await fixture.next(timeout: .milliseconds(30))
      XCTFail("Overflowed ambiguous provider items must not be attributed to the active input")
    } catch OpenAIEventRecorderError.timedOut {}
  }

  func testReconnectDiscardsBufferedProviderCorrelation() async throws {
    let fixture = await Fixture.make()
    let old = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(old))
    await fixture.backend.testingHandle(.append(id: old.id, sequence: 0, audio: Data([1])))
    await fixture.backend.testingHandle(.finish(id: old.id))
    let active = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(active))
    await fixture.backend.testingHandle(.append(id: active.id, sequence: 0, audio: Data([2])))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "old-attempt-item", delta: "Stale"))

    await fixture.backend.testingResetForReconnect()
    _ = try await fixture.next()
    _ = try await fixture.next()
    await fixture.backend.testingSetReady(epoch: fixture.epoch)
    _ = try await fixture.next()
    await fixture.backend.testingReceive(.inputCommitted(itemID: "replayed-old-item"))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "new-attempt-item", delta: "Fresh"))

    let preview = try await fixture.next()
    XCTAssertEqual(preview, .preview(id: active.id, text: "Fresh"))
  }

  func testOversizedAmbiguousProviderItemDisablesActiveItemInference() async throws {
    let fixture = await Fixture.make()
    let old = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(old))
    await fixture.backend.testingHandle(.append(id: old.id, sequence: 0, audio: Data([1])))
    await fixture.backend.testingHandle(.finish(id: old.id))
    let active = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(active))
    await fixture.backend.testingHandle(.append(id: active.id, sequence: 0, audio: Data([2])))

    await fixture.backend.testingReceive(
      .transcriptDelta(itemID: "oversized", delta: String(repeating: "x", count: 65_537))
    )
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "candidate", delta: "Wrong"))
    await fixture.backend.testingReceive(.inputCommitted(itemID: "old-item"))

    do {
      _ = try await fixture.next(timeout: .milliseconds(30))
      XCTFail("A hidden oversized item must prevent active input inference")
    } catch OpenAIEventRecorderError.timedOut {}
  }

  func testRejectedCommitDoesNotConsumeNextAcknowledgement() async throws {
    let fixture = await Fixture.make()
    let rejected = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(rejected))
    await fixture.backend.testingHandle(.append(id: rejected.id, sequence: 0, audio: Data([1])))
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
    await fixture.backend.testingHandle(.append(id: next.id, sequence: 0, audio: Data([2])))
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
    await fixture.backend.testingHandle(.append(id: first.id, sequence: 0, audio: Data([1])))
    await fixture.backend.testingHandle(.finish(id: first.id))
    await fixture.backend.testingHandle(.begin(second))
    await fixture.backend.testingHandle(.append(id: second.id, sequence: 0, audio: Data([2])))
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
    await fixture.backend.testingHandle(.append(id: invocation.id, sequence: 0, audio: Data([1])))
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

  func next(timeout: Duration = .seconds(1)) async throws -> TranscriptionEngineEvent {
    try await recorder.next(timeout: timeout)
  }
}

private enum OpenAIEventRecorderError: Error {
  case timedOut
}

private actor OpenAIEventRecorder {
  private var events: [TranscriptionEngineEvent] = []

  init(events: AsyncStream<TranscriptionEngineEvent>) {
    Task { [weak self] in
      for await event in events {
        await self?.record(event)
      }
    }
  }

  func next(timeout: Duration = .seconds(1)) async throws -> TranscriptionEngineEvent {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while events.isEmpty, clock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    guard !events.isEmpty else {
      throw OpenAIEventRecorderError.timedOut
    }
    return events.removeFirst()
  }

  private func record(_ event: TranscriptionEngineEvent) {
    events.append(event)
  }
}
