@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

// swiftlint:disable file_length type_body_length

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
    let next = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(next))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "next-item", delta: "Next"))
    let nextPreview = try await fixture.next()
    XCTAssertEqual(nextPreview, .preview(id: next.id, text: "Next"))
  }

  func testRejectsInvocationWithLocalAudioFormat() async throws {
    let fixture = await Fixture.make()
    let invocation = TranscriptionInvocation(id: fixture.id(0), format: .local)

    await fixture.backend.testingHandle(.begin(invocation))

    guard case .failure(_, let failedID?, let failure) = try await fixture.next() else {
      return XCTFail("Expected a configuration failure")
    }
    XCTAssertEqual(failedID, invocation.id)
    XCTAssertEqual(failure.kind, .configuration)
    let hasInvocation = await fixture.backend.testingHasInvocation(invocation.id)
    XCTAssertFalse(hasInvocation)
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
    let recovering = try await fixture.next()
    XCTAssertEqual(
      recovering,
      .readiness(
        epoch: fixture.epoch,
        state: .recovering(message: "Reconnecting after cancelled dictation.")
      )
    )

    let next = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(next))
    await fixture.backend.testingHandle(.append(id: next.id, sequence: 0, audio: Data([2])))
    await fixture.backend.testingReceive(
      .transcriptDelta(itemID: "old-item", delta: "Old"),
      attemptID: "test-attempt"
    )
    await fixture.backend.testingSetReady(epoch: fixture.epoch, attemptID: "replacement-attempt")
    let ready = try await fixture.next()
    XCTAssertEqual(
      ready,
      .readiness(epoch: fixture.epoch, state: .ready)
    )
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "new-item", delta: "New"))
    let event = try await fixture.next()
    XCTAssertEqual(event, .preview(id: next.id, text: "New"))
  }

  func testCancellingInferredItemWithPendingCommitReplacesConnection() async throws {
    let fixture = await Fixture.make()
    let cancelled = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(cancelled))
    await fixture.backend.testingHandle(.append(id: cancelled.id, sequence: 0, audio: Data([1])))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "cancelled-item", delta: "Old"))
    let preview = try await fixture.next()
    XCTAssertEqual(preview, .preview(id: cancelled.id, text: "Old"))
    await fixture.backend.testingHandle(.finish(id: cancelled.id))

    let commitEventID = await fixture.backend.testingCommitEventID(for: cancelled.id)
    XCTAssertNotNil(commitEventID)
    await fixture.backend.testingHandle(.cancel(id: cancelled.id))

    let recovering = try await fixture.next()
    XCTAssertEqual(
      recovering,
      .readiness(
        epoch: fixture.epoch,
        state: .recovering(message: "Reconnecting after cancelled dictation.")
      )
    )
  }

  func testNextInvocationRemainsBufferedUntilCurrentFinalCompletes() async throws {
    let fixture = await Fixture.make()
    let first = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(first))
    await fixture.backend.testingHandle(.append(id: first.id, sequence: 0, audio: Data([1])))
    await fixture.backend.testingHandle(.finish(id: first.id))

    let next = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(next))
    await fixture.backend.testingHandle(.append(id: next.id, sequence: 0, audio: Data([2])))
    await fixture.backend.testingHandle(.finish(id: next.id))
    let queuedCommitBeforeFinal = await fixture.backend.testingCommitEventID(for: next.id)
    XCTAssertNil(queuedCommitBeforeFinal)

    await fixture.backend.testingReceive(.inputCommitted(itemID: "first-item"))
    await fixture.backend.testingReceive(
      .transcriptCompleted(itemID: "first-item", transcript: "First")
    )
    let firstFinal = try await fixture.next()
    XCTAssertEqual(
      firstFinal,
      .final(id: first.id, result: .init(text: "First", correction: .disabled))
    )

    let queuedCommitAfterFinal = await fixture.backend.testingCommitEventID(for: next.id)
    XCTAssertNotNil(queuedCommitAfterFinal)
    await fixture.backend.testingReceive(.inputCommitted(itemID: "next-item"))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "next-item", delta: "Next"))
    let nextPreview = try await fixture.next()
    XCTAssertEqual(nextPreview, .preview(id: next.id, text: "Next"))
  }

  func testLateFirstDeltaFromCancelledInputCannotBindReplacement() async throws {
    let fixture = await Fixture.make()
    let cancelled = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(cancelled))
    await fixture.backend.testingHandle(.append(id: cancelled.id, sequence: 0, audio: Data([1])))
    await fixture.backend.testingHandle(.cancel(id: cancelled.id))
    let recovering = try await fixture.next()
    XCTAssertEqual(
      recovering,
      .readiness(
        epoch: fixture.epoch,
        state: .recovering(message: "Reconnecting after cancelled dictation.")
      )
    )

    let replacement = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(replacement))
    await fixture.backend.testingHandle(.append(id: replacement.id, sequence: 0, audio: Data([2])))
    await fixture.backend.testingReceive(
      .transcriptDelta(itemID: "cancelled-item", delta: "Stale"),
      attemptID: "test-attempt"
    )
    await fixture.backend.testingSetReady(epoch: fixture.epoch, attemptID: "replacement-attempt")
    let ready = try await fixture.next()
    XCTAssertEqual(
      ready,
      .readiness(epoch: fixture.epoch, state: .ready)
    )
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "replacement-item", delta: "Fresh"))
    let preview = try await fixture.next()
    XCTAssertEqual(preview, .preview(id: replacement.id, text: "Fresh"))

    await fixture.backend.testingHandle(.finish(id: replacement.id))
    await fixture.backend.testingReceive(.inputCommitted(itemID: "replacement-item"))
    await fixture.backend.testingReceive(
      .transcriptCompleted(itemID: "replacement-item", transcript: "Fresh final")
    )

    let final = try await fixture.next()
    XCTAssertEqual(
      final,
      .final(id: replacement.id, result: .init(text: "Fresh final", correction: .disabled))
    )
  }

  func testCancellingInputWithoutAudioKeepsActiveItemInferenceEnabled() async throws {
    let fixture = await Fixture.make()
    let cancelled = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(cancelled))
    await fixture.backend.testingHandle(.cancel(id: cancelled.id))

    let replacement = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(replacement))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "replacement-item", delta: "Fresh"))

    let preview = try await fixture.next()
    XCTAssertEqual(preview, .preview(id: replacement.id, text: "Fresh"))
  }

  func testCancellingRetainedAudioWhileRecoveringKeepsFreshAttemptInferenceEnabled() async throws {
    let fixture = await Fixture.make()
    await fixture.backend.testingResetForReconnect()
    let cancelled = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(cancelled))
    await fixture.backend.testingHandle(.append(id: cancelled.id, sequence: 0, audio: Data([1])))
    await fixture.backend.testingHandle(.cancel(id: cancelled.id))

    let replacement = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(replacement))
    await fixture.backend.testingHandle(.append(id: replacement.id, sequence: 0, audio: Data([2])))
    await fixture.backend.testingSetReady(epoch: fixture.epoch, attemptID: "replacement-attempt")
    let ready = try await fixture.next()
    XCTAssertEqual(ready, .readiness(epoch: fixture.epoch, state: .ready))

    await fixture.backend.testingReceive(.transcriptDelta(itemID: "replacement-item", delta: "Fresh"))
    let preview = try await fixture.next()
    XCTAssertEqual(preview, .preview(id: replacement.id, text: "Fresh"))
  }

  func testCancellingQueuedInvocationDoesNotDisturbActiveInvocation() async throws {
    let fixture = await Fixture.make()
    let active = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(active))
    await fixture.backend.testingHandle(.append(id: active.id, sequence: 0, audio: Data([1])))
    await fixture.backend.testingHandle(.finish(id: active.id))

    let cancelled = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(cancelled))
    await fixture.backend.testingHandle(.append(id: cancelled.id, sequence: 0, audio: Data([2])))
    await fixture.backend.testingHandle(.cancel(id: cancelled.id))
    let hasCancelledInvocation = await fixture.backend.testingHasInvocation(cancelled.id)
    XCTAssertFalse(hasCancelledInvocation)

    let replacement = fixture.invocation(2)
    await fixture.backend.testingHandle(.begin(replacement))
    await fixture.backend.testingHandle(.append(id: replacement.id, sequence: 0, audio: Data([3])))
    await fixture.backend.testingHandle(.finish(id: replacement.id))
    let replacementCommitBeforeFinal = await fixture.backend.testingCommitEventID(for: replacement.id)
    XCTAssertNil(replacementCommitBeforeFinal)

    await fixture.backend.testingReceive(.inputCommitted(itemID: "active-item"))
    await fixture.backend.testingReceive(
      .transcriptCompleted(itemID: "active-item", transcript: "Active final")
    )
    let activeFinal = try await fixture.next()
    XCTAssertEqual(
      activeFinal,
      .final(id: active.id, result: .init(text: "Active final", correction: .disabled))
    )
    let replacementCommitAfterFinal = await fixture.backend.testingCommitEventID(for: replacement.id)
    XCTAssertNotNil(replacementCommitAfterFinal)

    await fixture.backend.testingReceive(.inputCommitted(itemID: "replacement-item"))
    await fixture.backend.testingReceive(
      .transcriptCompleted(itemID: "replacement-item", transcript: "Fresh final")
    )
    let replacementFinal = try await fixture.next()
    XCTAssertEqual(
      replacementFinal,
      .final(id: replacement.id, result: .init(text: "Fresh final", correction: .disabled))
    )
  }

  func testConflictingAcknowledgementReconnectsWithoutBindingQueuedInvocation() async throws {
    let fixture = await Fixture.make()
    let active = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(active))
    await fixture.backend.testingHandle(.append(id: active.id, sequence: 0, audio: Data([1])))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "expected", delta: "Preview"))
    let initialPreview = try await fixture.next()
    XCTAssertEqual(initialPreview, .preview(id: active.id, text: "Preview"))
    await fixture.backend.testingHandle(.finish(id: active.id))

    let queued = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(queued))
    await fixture.backend.testingHandle(.append(id: queued.id, sequence: 0, audio: Data([2])))
    await fixture.backend.testingHandle(.finish(id: queued.id))
    await fixture.backend.testingReceive(.inputCommitted(itemID: "conflicting"))

    let clearedPreview = try await fixture.next()
    XCTAssertEqual(
      clearedPreview,
      .preview(id: active.id, text: "")
    )
    let recovering = try await fixture.next()
    XCTAssertEqual(
      recovering,
      .readiness(
        epoch: fixture.epoch,
        state: .recovering(message: "Reconnecting after an ambiguous transcription acknowledgement.")
      )
    )
    let queuedCommit = await fixture.backend.testingCommitEventID(for: queued.id)
    XCTAssertNil(queuedCommit)
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
    await fixture.backend.testingSetReady(epoch: fixture.epoch)
    _ = try await fixture.next()
    await fixture.backend.testingReceive(.inputCommitted(itemID: "replayed-old-item"))
    await fixture.backend.testingReceive(
      .transcriptCompleted(itemID: "replayed-old-item", transcript: "Old final")
    )
    _ = try await fixture.next()
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
    await fixture.backend.testingHandle(.finish(id: active.id))
    await fixture.backend.testingReceive(
      .transcriptCompleted(itemID: "old-item", transcript: "Old final")
    )
    _ = try await fixture.next()
    await fixture.backend.testingReceive(.inputCommitted(itemID: "active-item"))
    await fixture.backend.testingReceive(
      .transcriptCompleted(itemID: "active-item", transcript: "Authoritative final")
    )
    let final = try await fixture.next()
    XCTAssertEqual(
      final,
      .final(id: active.id, result: .init(text: "Authoritative final", correction: .disabled))
    )
  }

  func testCumulativeProviderPreviewOverflowDisablesActiveItemInference() async throws {
    let fixture = await Fixture.make()
    let old = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(old))
    await fixture.backend.testingHandle(.append(id: old.id, sequence: 0, audio: Data([1])))
    await fixture.backend.testingHandle(.finish(id: old.id))
    let active = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(active))
    await fixture.backend.testingHandle(.append(id: active.id, sequence: 0, audio: Data([2])))

    let maximumPreview = String(repeating: "x", count: 65_536)
    await fixture.backend.testingReceive(
      .transcriptDelta(itemID: "old-item", delta: maximumPreview)
    )
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "old-item", delta: "x"))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "candidate", delta: "Wrong"))
    await fixture.backend.testingReceive(.inputCommitted(itemID: "old-item"))
    let oldPreview = try await fixture.next()
    XCTAssertEqual(oldPreview, .preview(id: old.id, text: maximumPreview))

    await fixture.backend.testingHandle(.finish(id: active.id))
    await fixture.backend.testingReceive(
      .transcriptCompleted(itemID: "old-item", transcript: "Old final")
    )
    _ = try await fixture.next()
    await fixture.backend.testingReceive(.inputCommitted(itemID: "active-item"))
    await fixture.backend.testingReceive(
      .transcriptCompleted(itemID: "active-item", transcript: "Authoritative final")
    )
    let final = try await fixture.next()
    XCTAssertEqual(
      final,
      .final(id: active.id, result: .init(text: "Authoritative final", correction: .disabled))
    )
  }

  func testFailedUnassignedCommitCannotLeakBufferedPreviewIntoLaterInput() async throws {
    let fixture = await Fixture.make()
    let old = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(old))
    await fixture.backend.testingHandle(.append(id: old.id, sequence: 0, audio: Data([1])))
    await fixture.backend.testingHandle(.finish(id: old.id))
    let failed = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(failed))
    await fixture.backend.testingHandle(.append(id: failed.id, sequence: 0, audio: Data([2])))
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "failed-item", delta: "Stale"))
    await fixture.backend.testingHandle(.finish(id: failed.id))
    await fixture.backend.testingReceive(.inputCommitted(itemID: "old-item"))
    await fixture.backend.testingReceive(
      .transcriptCompleted(itemID: "old-item", transcript: "Old final")
    )
    let oldFinal = try await fixture.next()
    XCTAssertEqual(
      oldFinal,
      .final(id: old.id, result: .init(text: "Old final", correction: .disabled))
    )
    let maybeEventID = await fixture.backend.testingCommitEventID(for: failed.id)
    let eventID = try XCTUnwrap(maybeEventID)
    await fixture.backend.testingReceive(.error(message: "Commit failed", eventID: eventID))
    guard case .failure(_, let failedID?, _) = try await fixture.next() else {
      return XCTFail("Expected the failed invocation to retire")
    }
    XCTAssertEqual(failedID, failed.id)
    let recovering = try await fixture.next()
    XCTAssertEqual(
      recovering,
      .readiness(
        epoch: fixture.epoch,
        state: .recovering(message: "Reconnecting after a transcription error.")
      )
    )

    let active = fixture.invocation(2)
    await fixture.backend.testingHandle(.begin(active))
    await fixture.backend.testingHandle(.append(id: active.id, sequence: 0, audio: Data([3])))
    await fixture.backend.testingReceive(
      .transcriptDelta(itemID: "failed-item", delta: " stale"),
      attemptID: "test-attempt"
    )
    await fixture.backend.testingSetReady(epoch: fixture.epoch, attemptID: "replacement-attempt")
    let ready = try await fixture.next()
    XCTAssertEqual(
      ready,
      .readiness(epoch: fixture.epoch, state: .ready)
    )
    await fixture.backend.testingReceive(.transcriptDelta(itemID: "active-item", delta: "Fresh"))
    let activePreview = try await fixture.next()
    XCTAssertEqual(activePreview, .preview(id: active.id, text: "Fresh"))

    await fixture.backend.testingHandle(.finish(id: active.id))
    await fixture.backend.testingReceive(.inputCommitted(itemID: "active-item"))
    await fixture.backend.testingReceive(
      .transcriptCompleted(itemID: "active-item", transcript: "Fresh final")
    )

    let activeFinal = try await fixture.next()
    XCTAssertEqual(
      activeFinal,
      .final(id: active.id, result: .init(text: "Fresh final", correction: .disabled))
    )
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
    let recovering = try await fixture.next()
    XCTAssertEqual(
      recovering,
      .readiness(
        epoch: fixture.epoch,
        state: .recovering(message: "Reconnecting after a transcription error.")
      )
    )

    let next = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(next))
    await fixture.backend.testingHandle(.append(id: next.id, sequence: 0, audio: Data([2])))
    await fixture.backend.testingHandle(.finish(id: next.id))
    await fixture.backend.testingSetReady(epoch: fixture.epoch, attemptID: "replacement-attempt")
    let ready = try await fixture.next()
    XCTAssertEqual(ready, .readiness(epoch: fixture.epoch, state: .ready))
    await fixture.backend.testingReceive(.inputCommitted(itemID: "next-item"))
    await fixture.backend.testingReceive(.transcriptCompleted(itemID: "next-item", transcript: "Recovered"))
    let event = try await fixture.next()
    XCTAssertEqual(
      event,
      .final(id: next.id, result: .init(text: "Recovered", correction: .disabled))
    )
  }

  func testUncorrelatedErrorRetiresOnlyActiveCommitAndReplaysQueuedInvocation() async throws {
    let fixture = await Fixture.make()
    let active = fixture.invocation(0)
    await fixture.backend.testingHandle(.begin(active))
    await fixture.backend.testingHandle(.append(id: active.id, sequence: 0, audio: Data([1])))
    await fixture.backend.testingHandle(.finish(id: active.id))

    let queued = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(queued))
    await fixture.backend.testingHandle(.append(id: queued.id, sequence: 0, audio: Data([2])))
    await fixture.backend.testingHandle(.finish(id: queued.id))

    await fixture.backend.testingReceive(.error(message: "Unknown server error"))
    guard case .failure(_, let failedID?, let failure) = try await fixture.next() else {
      return XCTFail("Expected a targeted failure")
    }
    XCTAssertEqual(failedID, active.id)
    XCTAssertEqual(failure.message, "Unknown server error")
    let recovering = try await fixture.next()
    XCTAssertEqual(
      recovering,
      .readiness(
        epoch: fixture.epoch,
        state: .recovering(message: "Reconnecting after an uncorrelated transcription error.")
      )
    )
    let hasActive = await fixture.backend.testingHasInvocation(active.id)
    let hasQueued = await fixture.backend.testingHasInvocation(queued.id)
    XCTAssertFalse(hasActive)
    XCTAssertTrue(hasQueued)

    await fixture.backend.testingSetReady(epoch: fixture.epoch, attemptID: "replacement-attempt")
    _ = try await fixture.next()
    let replayedCommit = await fixture.backend.testingCommitEventID(for: queued.id)
    XCTAssertNotNil(replayedCommit)
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

  func testCloudInvocationsAreTranscribedSerially() async throws {
    let fixture = await Fixture.make()
    let first = fixture.invocation(0)
    let second = fixture.invocation(1)
    await fixture.backend.testingHandle(.begin(first))
    await fixture.backend.testingHandle(.append(id: first.id, sequence: 0, audio: Data([1])))
    await fixture.backend.testingHandle(.finish(id: first.id))
    await fixture.backend.testingHandle(.begin(second))
    await fixture.backend.testingHandle(.append(id: second.id, sequence: 0, audio: Data([2])))
    await fixture.backend.testingHandle(.finish(id: second.id))
    let secondCommitBeforeFirstFinal = await fixture.backend.testingCommitEventID(for: second.id)
    XCTAssertNil(secondCommitBeforeFirstFinal)

    await fixture.backend.testingReceive(.inputCommitted(itemID: "first"))
    await fixture.backend.testingReceive(.transcriptCompleted(itemID: "first", transcript: "one"))
    let firstEvent = try await fixture.next()
    XCTAssertEqual(
      firstEvent,
      .final(id: first.id, result: .init(text: "one", correction: .disabled))
    )
    let secondCommitAfterFirstFinal = await fixture.backend.testingCommitEventID(for: second.id)
    XCTAssertNotNil(secondCommitAfterFirstFinal)

    await fixture.backend.testingReceive(.inputCommitted(itemID: "second"))
    await fixture.backend.testingReceive(.transcriptCompleted(itemID: "second", transcript: "two"))
    let secondFinal = try await fixture.next()
    XCTAssertEqual(
      secondFinal,
      .final(id: second.id, result: .init(text: "two", correction: .disabled))
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
    let invocation = fixture.invocation(0)
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
    let hasActiveAttempt = await fixture.backend.testingHasActiveAttempt()
    XCTAssertFalse(hasFailedInvocation)
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
      reconnectPolicy: .init(initialDelay: .seconds(60)),
      outboundCapacity: outboundCapacity,
      consumesOutboundActions: consumesOutboundActions
    )
    let recorder = OpenAIEventRecorder(events: backend.events)
    let fixture = Self(backend: backend, recorder: recorder)
    await backend.testingSetReady(epoch: fixture.epoch)
    do {
      let readiness = try await fixture.next(timeout: .seconds(5))
      XCTAssertEqual(readiness, .readiness(epoch: fixture.epoch, state: .ready))
    } catch {
      XCTFail("Fixture did not become ready: \(error)")
    }
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
  private struct Waiter {
    let continuation: CheckedContinuation<TranscriptionEngineEvent, Error>
    let timeoutTask: Task<Void, Never>
  }

  private var events: [TranscriptionEngineEvent] = []
  private var waiters: [UUID: Waiter] = [:]
  private var waiterOrder: [UUID] = []

  init(events: AsyncStream<TranscriptionEngineEvent>) {
    Task { [weak self] in
      for await event in events {
        await self?.record(event)
      }
    }
  }

  func next(timeout: Duration = .seconds(1)) async throws -> TranscriptionEngineEvent {
    if !events.isEmpty {
      return events.removeFirst()
    }
    let waiterID = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let timeoutTask = Task { [weak self] in
          try? await Task.sleep(for: timeout)
          await self?.timeOut(waiterID)
        }
        waiters[waiterID] = Waiter(
          continuation: continuation,
          timeoutTask: timeoutTask
        )
        waiterOrder.append(waiterID)
      }
    } onCancel: {
      Task { await self.cancel(waiterID) }
    }
  }

  private func record(_ event: TranscriptionEngineEvent) {
    guard let waiterID = waiterOrder.first else {
      events.append(event)
      return
    }
    waiterOrder.removeFirst()
    guard let waiter = waiters.removeValue(forKey: waiterID) else {
      events.append(event)
      return
    }
    waiter.timeoutTask.cancel()
    waiter.continuation.resume(returning: event)
  }

  private func timeOut(_ waiterID: UUID) {
    guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
    waiterOrder.removeAll { $0 == waiterID }
    waiter.continuation.resume(throwing: OpenAIEventRecorderError.timedOut)
  }

  private func cancel(_ waiterID: UUID) {
    guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
    waiterOrder.removeAll { $0 == waiterID }
    waiter.timeoutTask.cancel()
    waiter.continuation.resume(throwing: CancellationError())
  }
}

// swiftlint:enable file_length type_body_length
