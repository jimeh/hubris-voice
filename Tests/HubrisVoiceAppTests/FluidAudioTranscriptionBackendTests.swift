import Foundation
@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
final class FluidAudioTranscriptionBackendTests: XCTestCase {
  func testBackendDeallocatesWithoutExplicitUnload() async {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "unused", candidateText: nil)
    )
    var backend: FluidAudioTranscriptionBackend? = makeBackend(
      processor: processor,
      policy: .disabled
    )
    weak var releasedBackend: FluidAudioTranscriptionBackend?
    releasedBackend = backend

    backend = nil
    for _ in 0 ..< 20 where releasedBackend != nil {
      await Task.yield()
    }

    XCTAssertNil(releasedBackend)
  }

  func testCorrectionSegmentsKeepSubwordTokensAndPunctuationTogether() {
    let tokens: [FluidAudioCorrectionSegmenter.TimedToken] = [
      .init(index: 0, text: " first", startTime: 0, endTime: 0.4),
      .init(index: 1, text: "Word", startTime: 0.4, endTime: 0.8),
      .init(index: 2, text: ".", startTime: 0.8, endTime: 0.9),
      .init(index: 3, text: " next", startTime: 1.2, endTime: 1.5),
      .init(index: 4, text: "Word", startTime: 1.5, endTime: 1.8),
    ]

    let segments = FluidAudioCorrectionSegmenter.segments(tokens, maximumCoreDuration: 1)

    XCTAssertEqual(segments.map { $0.map(\.index) }, [[0, 1, 2], [3, 4]])
    XCTAssertEqual(segments.flatMap(\.self).map(\.text).joined(), tokens.map(\.text).joined())
  }

  func testEmitsRawPreviewAndGuardedFinalText() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(
        rawText: "Use user underscore ID, please.",
        candidateText: "Use user_id please"
      )
    )
    let backend = makeBackend(processor: processor, policy: .strict)
    let recorder = EventRecorder(stream: backend.events)
    let invocation = makeInvocation(generation: 1)

    XCTAssertTrue(backend.submit(.prepare(epoch: invocation.id.epoch)))
    _ = try await recorder.waitUntil { event in
      if case .readiness(_, .ready) = event {
        return true
      }
      return false
    }
    XCTAssertTrue(backend.submit(.begin(invocation)))
    XCTAssertTrue(backend.submit(.append(id: invocation.id, sequence: 0, audio: Data([0, 0]))))
    XCTAssertTrue(backend.submit(.finish(id: invocation.id)))

    let final = try await recorder.waitUntil { event in
      if case .final(id: invocation.id, _) = event {
        return true
      }
      return false
    }
    XCTAssertEqual(
      final,
      .final(
        id: invocation.id,
        result: TranscriptionFinalResult(text: "Use user_id, please.", correction: .applied)
      )
    )
    let events = await recorder.snapshot()
    XCTAssertTrue(events.contains(.preview(id: invocation.id, text: "raw preview")))
  }

  func testCancellationRetiresFinalizingInvocationAndReplaysNextBufferedAudio() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "second result", candidateText: nil),
      blockFinish: true
    )
    let backend = makeBackend(processor: processor, policy: .disabled)
    let recorder = EventRecorder(stream: backend.events)
    let first = makeInvocation(generation: 1)
    let second = makeInvocation(generation: 2)

    XCTAssertTrue(backend.submit(.prepare(epoch: first.id.epoch)))
    _ = try await recorder.waitUntil {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }
    XCTAssertTrue(backend.submit(.begin(first)))
    XCTAssertTrue(backend.submit(.append(id: first.id, sequence: 0, audio: Data([0, 0]))))
    XCTAssertTrue(backend.submit(.finish(id: first.id)))
    try await processor.waitForFinish()

    XCTAssertTrue(backend.submit(.begin(second)))
    XCTAssertTrue(backend.submit(.append(id: second.id, sequence: 0, audio: Data([1, 0]))))
    XCTAssertTrue(backend.submit(.finish(id: second.id)))
    XCTAssertTrue(backend.submit(.cancel(id: first.id)))
    try await processor.waitForFinishCancellation()
    await processor.releaseFinish()

    _ = try await recorder.waitUntil {
      if case .final(id: second.id, _) = $0 {
        return true
      }
      return false
    }
    let events = await recorder.snapshot()
    XCTAssertFalse(events.contains {
      if case .final(id: first.id, _) = $0 {
        true
      } else {
        false
      }
    })
    let resetCount = await processor.resetCount()
    let appendedChunks = await processor.appendedChunks()
    XCTAssertEqual(resetCount, 2)
    XCTAssertEqual(appendedChunks, [Data([0, 0]), Data([1, 0])])
  }

  func testUnloadRetainsModelLeaseUntilInFlightInferenceStops() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "finished", candidateText: nil),
      blockFinish: true,
      ignoreFinishCancellation: true
    )
    let releases = ReleaseRecorder()
    let backend = makeBackend(processor: processor, policy: .disabled) {
      await releases.record()
    }
    let recorder = EventRecorder(stream: backend.events)
    let invocation = makeInvocation(generation: 5)

    XCTAssertTrue(backend.submit(.prepare(epoch: invocation.id.epoch)))
    _ = try await recorder.waitUntil {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }
    XCTAssertTrue(backend.submit(.begin(invocation)))
    XCTAssertTrue(backend.submit(.finish(id: invocation.id)))
    try await processor.waitForFinish()

    let unloadTask = Task { await backend.unload() }
    try await Task.sleep(for: .milliseconds(20))
    let releasesWhileInFlight = await releases.count()
    XCTAssertEqual(releasesWhileInFlight, 0)

    await processor.releaseFinish()
    await unloadTask.value
    let releaseCount = await releases.count()
    XCTAssertEqual(releaseCount, 1)
  }

  func testCancellationDuringLoadingNeverStartsRetiredInvocation() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "unused", candidateText: nil),
      blockPrepare: true
    )
    let backend = makeBackend(processor: processor, policy: .disabled)
    let recorder = EventRecorder(stream: backend.events)
    let invocation = makeInvocation(generation: 6)

    XCTAssertTrue(backend.submit(.prepare(epoch: invocation.id.epoch)))
    XCTAssertTrue(backend.submit(.begin(invocation)))
    XCTAssertTrue(backend.submit(.append(id: invocation.id, sequence: 0, audio: Data([0, 0]))))
    XCTAssertTrue(backend.submit(.finish(id: invocation.id)))
    try await processor.waitForPrepare()
    XCTAssertTrue(backend.submit(.cancel(id: invocation.id)))
    // The invalid format fails synchronously after earlier commands, proving cancel
    // was processed before preparation is released.
    let cancellationBarrier = TranscriptionInvocation(
      id: .init(epoch: invocation.id.epoch, generation: invocation.id.generation + 1),
      format: .openAI
    )
    XCTAssertTrue(backend.submit(.begin(cancellationBarrier)))
    _ = try await recorder.waitUntil {
      if case .failure(_, id: cancellationBarrier.id, _) = $0 {
        true
      } else {
        false
      }
    }
    await processor.releasePrepare()
    _ = try await recorder.waitUntil {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }

    let resetCount = await processor.resetCount()
    let appendedChunks = await processor.appendedChunks()
    let events = await recorder.snapshot()
    XCTAssertEqual(resetCount, 0)
    XCTAssertEqual(appendedChunks, [])
    XCTAssertFalse(events.contains {
      if case .final(id: invocation.id, _) = $0 {
        true
      } else {
        false
      }
    })
    await backend.unload()
  }

  func testRetiredInvocationCannotBeginAgain() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "unused", candidateText: nil)
    )
    let backend = makeBackend(processor: processor, policy: .disabled)
    let recorder = EventRecorder(stream: backend.events)
    let invocation = makeInvocation(generation: 20)

    XCTAssertTrue(backend.submit(.prepare(epoch: invocation.id.epoch)))
    _ = try await recorder.waitUntil {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }
    XCTAssertTrue(backend.submit(.begin(invocation)))
    XCTAssertTrue(backend.submit(.cancel(id: invocation.id)))
    XCTAssertTrue(backend.submit(.begin(invocation)))
    XCTAssertTrue(backend.submit(.append(id: invocation.id, sequence: 0, audio: Data([1, 0]))))
    XCTAssertTrue(backend.submit(.finish(id: invocation.id)))

    let barrier = makeInvocation(generation: 21)
    XCTAssertTrue(backend.submit(.begin(barrier)))
    XCTAssertTrue(backend.submit(.finish(id: barrier.id)))
    _ = try await recorder.waitUntil {
      if case .final(id: barrier.id, _) = $0 {
        true
      } else {
        false
      }
    }
    let appendedChunks = await processor.appendedChunks()
    XCTAssertEqual(appendedChunks, [])
  }

  func testAppendAfterFinishIsIgnored() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "finished", candidateText: nil)
    )
    let backend = makeBackend(processor: processor, policy: .disabled)
    let recorder = EventRecorder(stream: backend.events)
    let invocation = makeInvocation(generation: 22)

    XCTAssertTrue(backend.submit(.prepare(epoch: invocation.id.epoch)))
    _ = try await recorder.waitUntil {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }
    XCTAssertTrue(backend.submit(.begin(invocation)))
    XCTAssertTrue(backend.submit(.finish(id: invocation.id)))
    XCTAssertTrue(backend.submit(.append(id: invocation.id, sequence: 0, audio: Data([1, 0]))))
    _ = try await recorder.waitUntil {
      if case .final(id: invocation.id, _) = $0 {
        true
      } else {
        false
      }
    }

    let appendedChunks = await processor.appendedChunks()
    XCTAssertEqual(appendedChunks, [])
  }

  func testRepeatedPreparationReleasesSupersededModelLeases() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "unused", candidateText: nil)
    )
    let primaryReleases = ReleaseRecorder()
    let correctionReleases = ReleaseRecorder()
    let backend = FluidAudioTranscriptionBackend(
      context: LocalInvocationContext(permanentEntries: [
        LocalVocabularyEntry(canonicalText: "PostgreSQL"),
      ]),
      correctionPolicy: .strict,
      processor: processor,
      acquireModels: { _, _ in
        FluidAudioModelLease(
          primaryDirectory: URL(fileURLWithPath: "/owned/primary"),
          release: { await primaryReleases.record() }
        )
      },
      acquireCorrection: {
        FluidAudioCorrectionLease(
          directory: URL(fileURLWithPath: "/owned/ctc"),
          release: { await correctionReleases.record() }
        )
      }
    )
    let recorder = EventRecorder(stream: backend.events)
    let epoch = TranscriptionBackendEpoch(7)

    XCTAssertTrue(backend.submit(.prepare(epoch: epoch)))
    _ = try await recorder.waitUntil {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }
    let eventCountBeforeSecondPreparation = await recorder.snapshot().count
    XCTAssertTrue(backend.submit(.prepare(epoch: epoch)))
    _ = try await recorder.waitUntil(after: eventCountBeforeSecondPreparation) {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }

    var primaryReleaseCount = await primaryReleases.count()
    var correctionReleaseCount = await correctionReleases.count()
    XCTAssertEqual(primaryReleaseCount, 1)
    XCTAssertEqual(correctionReleaseCount, 1)
    await backend.unload()
    primaryReleaseCount = await primaryReleases.count()
    correctionReleaseCount = await correctionReleases.count()
    XCTAssertEqual(primaryReleaseCount, 2)
    XCTAssertEqual(correctionReleaseCount, 2)
  }

  func testUnloadDuringSupersededLeaseReleaseDoesNotEmitStaleReady() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "unused", candidateText: nil)
    )
    let primaryReleases = ReleaseRecorder()
    let correctionReleases = ReleaseRecorder(blockNext: true)
    let backend = FluidAudioTranscriptionBackend(
      context: LocalInvocationContext(permanentEntries: [
        LocalVocabularyEntry(canonicalText: "PostgreSQL"),
      ]),
      correctionPolicy: .strict,
      processor: processor,
      acquireModels: { _, _ in
        FluidAudioModelLease(
          primaryDirectory: URL(fileURLWithPath: "/owned/primary"),
          release: { await primaryReleases.record() }
        )
      },
      acquireCorrection: {
        FluidAudioCorrectionLease(
          directory: URL(fileURLWithPath: "/owned/ctc"),
          release: { await correctionReleases.record() }
        )
      }
    )
    let recorder = EventRecorder(stream: backend.events)
    let epoch = TranscriptionBackendEpoch(8)

    XCTAssertTrue(backend.submit(.prepare(epoch: epoch)))
    _ = try await recorder.waitUntil {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }
    let eventCountBeforeSecondPreparation = await recorder.snapshot().count
    XCTAssertTrue(backend.submit(.prepare(epoch: epoch)))
    try await correctionReleases.waitUntilBlocked()

    let unloadTask = Task { await backend.unload() }
    try await correctionReleases.waitUntilCancellationObserved()
    await correctionReleases.resume()
    await unloadTask.value

    let laterEvents = await recorder.snapshot().dropFirst(eventCountBeforeSecondPreparation)
    XCTAssertFalse(laterEvents.contains {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    })
    let primaryReleaseCount = await primaryReleases.count()
    let correctionReleaseCount = await correctionReleases.count()
    XCTAssertEqual(primaryReleaseCount, 2)
    XCTAssertEqual(correctionReleaseCount, 2)
  }

  func testUnloadCancelsAndAwaitsInFlightConfigurationUpdate() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "unused", candidateText: nil)
    )
    let primaryReleases = ReleaseRecorder()
    let correctionReleases = ReleaseRecorder()
    let backend = FluidAudioTranscriptionBackend(
      context: .init(permanentEntries: []),
      correctionPolicy: .disabled,
      processor: processor,
      acquireModels: { _, _ in
        FluidAudioModelLease(
          primaryDirectory: URL(fileURLWithPath: "/owned/primary"),
          release: { await primaryReleases.record() }
        )
      },
      acquireCorrection: {
        FluidAudioCorrectionLease(
          directory: URL(fileURLWithPath: "/owned/ctc"),
          release: { await correctionReleases.record() }
        )
      }
    )
    let recorder = EventRecorder(stream: backend.events)
    let epoch = TranscriptionBackendEpoch(9)

    XCTAssertTrue(backend.submit(.prepare(epoch: epoch)))
    _ = try await recorder.waitUntil {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }
    await processor.blockNextPrepare()
    let updateTask = Task {
      try await backend.updateConfiguration(
        context: LocalInvocationContext(permanentEntries: [
          LocalVocabularyEntry(canonicalText: "PostgreSQL"),
        ]),
        correctionPolicy: .strict
      )
    }
    try await processor.waitForPrepareCount(2)

    let unloadTask = Task { await backend.unload() }
    try await processor.waitForPrepareCancellation()
    await processor.releasePrepare()
    let updated = try await updateTask.value
    await unloadTask.value

    XCTAssertFalse(updated)
    let primaryReleaseCount = await primaryReleases.count()
    let correctionReleaseCount = await correctionReleases.count()
    XCTAssertEqual(primaryReleaseCount, 1)
    XCTAssertEqual(correctionReleaseCount, 1)
  }

  func testPreparationSupersedesConfigurationUpdateWithoutLeavingItBusy() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "unused", candidateText: nil)
    )
    let correctionReleases = ReleaseRecorder()
    let backend = FluidAudioTranscriptionBackend(
      context: .init(permanentEntries: []),
      correctionPolicy: .disabled,
      processor: processor,
      acquireModels: { _, _ in
        FluidAudioModelLease(
          primaryDirectory: URL(fileURLWithPath: "/owned/primary"),
          release: {}
        )
      },
      acquireCorrection: {
        FluidAudioCorrectionLease(
          directory: URL(fileURLWithPath: "/owned/ctc"),
          release: { await correctionReleases.record() }
        )
      }
    )
    let recorder = EventRecorder(stream: backend.events)

    XCTAssertTrue(backend.submit(.prepare(epoch: TranscriptionBackendEpoch(9))))
    _ = try await recorder.waitUntil {
      if case .readiness(TranscriptionBackendEpoch(9), .ready) = $0 {
        true
      } else {
        false
      }
    }
    await processor.blockNextPrepare()
    let updateTask = Task {
      try await backend.updateConfiguration(
        context: LocalInvocationContext(permanentEntries: [
          LocalVocabularyEntry(canonicalText: "PostgreSQL"),
        ]),
        correctionPolicy: .strict
      )
    }
    try await processor.waitForPrepareCount(2)

    XCTAssertTrue(backend.submit(.prepare(epoch: TranscriptionBackendEpoch(10))))
    try await processor.waitForPrepareCancellation()
    await processor.releasePrepare()
    _ = try await recorder.waitUntil {
      if case .readiness(TranscriptionBackendEpoch(10), .ready) = $0 {
        true
      } else {
        false
      }
    }

    let supersededUpdate = try await updateTask.value
    let subsequentUpdate = try await backend.updateConfiguration(
      context: .init(permanentEntries: []),
      correctionPolicy: .disabled
    )
    let correctionReleaseCount = await correctionReleases.count()
    XCTAssertFalse(supersededUpdate)
    XCTAssertTrue(subsequentUpdate)
    XCTAssertEqual(correctionReleaseCount, 2)
  }

  func testRepreparationBlocksNewInvocation() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "unused", candidateText: nil)
    )
    let eventPair = AsyncStream.makeStream(of: TranscriptionEngineEvent.self)
    let state = FluidAudioTranscriptionState(
      context: .init(permanentEntries: []),
      correctionPolicy: .disabled,
      processor: processor,
      acquireModels: { _, _ in
        FluidAudioModelLease(
          primaryDirectory: URL(fileURLWithPath: "/owned/primary"),
          release: {}
        )
      },
      acquireCorrection: { nil },
      events: eventPair.continuation
    )
    let recorder = EventRecorder(stream: eventPair.stream)
    let initialEpoch = TranscriptionBackendEpoch(9)
    let replacementEpoch = TranscriptionBackendEpoch(10)

    await state.handle(.prepare(epoch: initialEpoch))
    _ = try await recorder.waitUntil {
      if case .readiness(initialEpoch, .ready) = $0 {
        true
      } else {
        false
      }
    }
    await processor.blockNextPrepare()
    await state.handle(.prepare(epoch: replacementEpoch))
    try await processor.waitForPrepareCount(2)

    await state.handle(.begin(TranscriptionInvocation(
      id: TranscriptionInvocationID(epoch: replacementEpoch, generation: 1),
      format: .local
    )))
    let unloadTask = Task { await state.unload() }
    try await processor.waitForPrepareCancellation()
    await processor.releasePrepare()
    await unloadTask.value

    let resetCount = await processor.resetCount()
    XCTAssertEqual(resetCount, 0)
  }

  func testRepreparationProcessesQueuedInvocationWhenReady() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "queued result", candidateText: nil)
    )
    let eventPair = AsyncStream.makeStream(of: TranscriptionEngineEvent.self)
    let state = FluidAudioTranscriptionState(
      context: .init(permanentEntries: []),
      correctionPolicy: .disabled,
      processor: processor,
      acquireModels: { _, _ in
        FluidAudioModelLease(
          primaryDirectory: URL(fileURLWithPath: "/owned/primary"),
          release: {}
        )
      },
      acquireCorrection: { nil },
      events: eventPair.continuation
    )
    let recorder = EventRecorder(stream: eventPair.stream)
    let initialEpoch = TranscriptionBackendEpoch(9)
    let replacementEpoch = TranscriptionBackendEpoch(10)
    let invocation = TranscriptionInvocation(
      id: TranscriptionInvocationID(epoch: replacementEpoch, generation: 1),
      format: .local
    )

    await state.handle(.prepare(epoch: initialEpoch))
    _ = try await recorder.waitUntil {
      if case .readiness(initialEpoch, .ready) = $0 {
        true
      } else {
        false
      }
    }
    await processor.blockNextPrepare()
    await state.handle(.prepare(epoch: replacementEpoch))
    try await processor.waitForPrepareCount(2)
    await state.handle(.begin(invocation))
    await state.handle(.append(id: invocation.id, sequence: 0, audio: Data([0, 0])))
    await state.handle(.finish(id: invocation.id))

    await processor.releasePrepare()
    _ = try await recorder.waitUntil {
      if case .readiness(replacementEpoch, .ready) = $0 {
        true
      } else {
        false
      }
    }
    let final = try await recorder.waitUntil {
      if case .final(id: invocation.id, _) = $0 {
        true
      } else {
        false
      }
    }

    XCTAssertEqual(final, .final(
      id: invocation.id,
      result: TranscriptionFinalResult(text: "queued result", correction: .disabled)
    ))
    await state.unload()
  }

  func testIdleConfigurationUpdateKeepsPrimaryLoadedAndAppliesToNextInvocation() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(
        rawText: "Use user underscore ID, please.",
        candidateText: "Use user_id please"
      )
    )
    let initialContext = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "PostgreSQL"),
    ])
    let updatedContext = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "user_id"),
    ])
    let backend = makeBackend(
      processor: processor,
      policy: .strict,
      context: initialContext
    )
    let recorder = EventRecorder(stream: backend.events)
    let invocation = makeInvocation(generation: 7)

    XCTAssertTrue(backend.submit(.prepare(epoch: invocation.id.epoch)))
    _ = try await recorder.waitUntil {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }
    let updated = try await backend.updateConfiguration(
      context: updatedContext,
      correctionPolicy: .strict
    )
    XCTAssertTrue(updated)
    XCTAssertTrue(backend.submit(.begin(invocation)))
    XCTAssertTrue(backend.submit(.finish(id: invocation.id)))

    let final = try await recorder.waitUntil {
      if case .final(id: invocation.id, _) = $0 {
        true
      } else {
        false
      }
    }
    XCTAssertEqual(
      final,
      .final(
        id: invocation.id,
        result: TranscriptionFinalResult(text: "Use user_id, please.", correction: .applied)
      )
    )
    let prepareCount = await processor.prepareCount()
    let primaryLoadCount = await processor.primaryLoadCount()
    let latestContext = await processor.latestContext()
    XCTAssertEqual(prepareCount, 2)
    XCTAssertEqual(primaryLoadCount, 1)
    XCTAssertEqual(latestContext, updatedContext)
  }

  func testBusyConfigurationUpdateReturnsFalseAndCanBeRetried() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(
        rawText: "Use user underscore ID, please.",
        candidateText: "Use user_id please"
      ),
      blockFinish: true
    )
    let initialContext = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "PostgreSQL"),
    ])
    let updatedContext = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "user_id"),
    ])
    let backend = makeBackend(
      processor: processor,
      policy: .strict,
      context: initialContext
    )
    let recorder = EventRecorder(stream: backend.events)
    let first = makeInvocation(generation: 9)

    XCTAssertTrue(backend.submit(.prepare(epoch: first.id.epoch)))
    _ = try await recorder.waitUntil {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }
    XCTAssertTrue(backend.submit(.begin(first)))
    XCTAssertTrue(backend.submit(.finish(id: first.id)))
    try await processor.waitForFinish()

    let busyUpdate = try await backend.updateConfiguration(
      context: updatedContext,
      correctionPolicy: .strict
    )
    XCTAssertFalse(busyUpdate)
    await processor.releaseFinish()
    _ = try await recorder.waitUntil {
      if case .final(id: first.id, _) = $0 {
        true
      } else {
        false
      }
    }

    let retry = try await backend.updateConfiguration(
      context: updatedContext,
      correctionPolicy: .strict
    )
    XCTAssertTrue(retry)
    let latestContext = await processor.latestContext()
    XCTAssertEqual(latestContext, updatedContext)
  }

  func testCorrectionLeaseReleaseIsRollbackSafeAcrossConfigurationUpdates() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "unused", candidateText: nil)
    )
    let primaryReleases = ReleaseRecorder()
    let correctionReleases = ReleaseRecorder()
    let backend = makeLeaseTrackingBackend(
      processor: processor,
      primaryReleases: primaryReleases,
      correctionReleases: correctionReleases
    )
    let recorder = EventRecorder(stream: backend.events)
    let invocation = makeInvocation(generation: 12)
    XCTAssertTrue(backend.submit(.prepare(epoch: invocation.id.epoch)))
    _ = try await recorder.waitUntil {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }

    await processor.failNextPrepare()
    do {
      _ = try await updateConfiguration(backend, entries: ["user_id"], policy: .strict)
      XCTFail("Expected configuration update failure")
    } catch is TranscriptionFailure {}
    let releasesAfterFailedEnable = await correctionReleases.count()
    let primaryReleasesAfterFailedEnable = await primaryReleases.count()
    XCTAssertEqual(releasesAfterFailedEnable, 1)
    XCTAssertEqual(primaryReleasesAfterFailedEnable, 0)

    let enabled = try await updateConfiguration(backend, entries: ["user_id"], policy: .strict)
    let enabledDirectory = await processor.latestCorrectionDirectory()
    let releasesAfterEnable = await correctionReleases.count()
    XCTAssertTrue(enabled)
    XCTAssertEqual(enabledDirectory, URL(fileURLWithPath: "/owned/ctc"))
    XCTAssertEqual(releasesAfterEnable, 1)

    await processor.failNextPrepare()
    do {
      _ = try await updateConfiguration(backend, entries: [], policy: .strict)
      XCTFail("Expected configuration update failure")
    } catch is TranscriptionFailure {}
    let releasesAfterFailure = await correctionReleases.count()
    XCTAssertEqual(releasesAfterFailure, 1)

    let emptied = try await updateConfiguration(backend, entries: [], policy: .strict)
    let emptiedDirectory = await processor.latestCorrectionDirectory()
    let releasesAfterEmpty = await correctionReleases.count()
    XCTAssertTrue(emptied)
    XCTAssertNil(emptiedDirectory)
    XCTAssertEqual(releasesAfterEmpty, 2)

    let reenabled = try await updateConfiguration(backend, entries: ["user_id"], policy: .strict)
    let releasesAfterReenable = await correctionReleases.count()
    XCTAssertTrue(reenabled)
    XCTAssertEqual(releasesAfterReenable, 2)

    let disabled = try await updateConfiguration(backend, entries: ["user_id"], policy: .disabled)
    let disabledDirectory = await processor.latestCorrectionDirectory()
    let releasesAfterDisable = await correctionReleases.count()
    XCTAssertTrue(disabled)
    XCTAssertNil(disabledDirectory)
    XCTAssertEqual(releasesAfterDisable, 3)
    await backend.unload()
    let correctionReleasesAfterUnload = await correctionReleases.count()
    let primaryReleasesAfterUnload = await primaryReleases.count()
    XCTAssertEqual(correctionReleasesAfterUnload, 3)
    XCTAssertEqual(primaryReleasesAfterUnload, 1)
  }

  func testDisablingInitiallyLoadedCorrectionReleasesItButRetainsPrimary() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "unused", candidateText: nil)
    )
    let primaryReleases = ReleaseRecorder()
    let correctionReleases = ReleaseRecorder()
    let backend = makeBackend(
      processor: processor,
      policy: .strict,
      release: { await primaryReleases.record() },
      correctionRelease: { await correctionReleases.record() }
    )
    let recorder = EventRecorder(stream: backend.events)
    let invocation = makeInvocation(generation: 13)
    XCTAssertTrue(backend.submit(.prepare(epoch: invocation.id.epoch)))
    _ = try await recorder.waitUntil {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }

    let loadedDirectory = await processor.latestCorrectionDirectory()
    XCTAssertEqual(loadedDirectory, URL(fileURLWithPath: "/owned/ctc"))

    let disabled = try await updateConfiguration(backend, entries: ["user_id"], policy: .disabled)
    let correctionDirectory = await processor.latestCorrectionDirectory()
    let primaryReleasesAfterDisable = await primaryReleases.count()
    let correctionReleasesAfterDisable = await correctionReleases.count()
    XCTAssertTrue(disabled)
    XCTAssertNil(correctionDirectory)
    XCTAssertEqual(primaryReleasesAfterDisable, 0)
    XCTAssertEqual(correctionReleasesAfterDisable, 1)
    await backend.unload()
    let primaryReleasesAfterUnload = await primaryReleases.count()
    let correctionReleasesAfterUnload = await correctionReleases.count()
    XCTAssertEqual(primaryReleasesAfterUnload, 1)
    XCTAssertEqual(correctionReleasesAfterUnload, 1)
  }

  func testConfigurationUpdateFailureThrowsSanitizedErrorAndRestoresPolicy() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(
        rawText: "Use user underscore ID, please.",
        candidateText: "Use user_id please"
      )
    )
    let initialContext = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "PostgreSQL"),
    ])
    let backend = makeBackend(
      processor: processor,
      policy: .strict,
      context: initialContext
    )
    let recorder = EventRecorder(stream: backend.events)
    let invocation = makeInvocation(generation: 10)

    XCTAssertTrue(backend.submit(.prepare(epoch: invocation.id.epoch)))
    _ = try await recorder.waitUntil {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }
    await processor.failNextPrepare()
    do {
      _ = try await backend.updateConfiguration(
        context: LocalInvocationContext(permanentEntries: [
          LocalVocabularyEntry(canonicalText: "user_id"),
        ]),
        correctionPolicy: .strict
      )
      XCTFail("Expected configuration update failure")
    } catch let failure as TranscriptionFailure {
      XCTAssertEqual(failure.kind, .configuration)
      XCTAssertEqual(
        failure.message,
        "The local correction configuration could not be applied."
      )
    }

    XCTAssertTrue(backend.submit(.begin(invocation)))
    XCTAssertTrue(backend.submit(.finish(id: invocation.id)))
    let final = try await recorder.waitUntil {
      if case .final(id: invocation.id, _) = $0 {
        true
      } else {
        false
      }
    }
    XCTAssertEqual(
      final,
      .final(
        id: invocation.id,
        result: TranscriptionFinalResult(
          text: "Use user underscore ID, please.",
          correction: .degraded
        )
      )
    )
  }

  func testPreparationFailureTerminatesQueuedInvocation() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "unused", candidateText: nil),
      blockPrepare: true,
      failPrepare: true
    )
    let backend = makeBackend(processor: processor, policy: .disabled)
    let recorder = EventRecorder(stream: backend.events)
    let invocation = makeInvocation(generation: 8)

    XCTAssertTrue(backend.submit(.prepare(epoch: invocation.id.epoch)))
    XCTAssertTrue(backend.submit(.begin(invocation)))
    XCTAssertTrue(backend.submit(.finish(id: invocation.id)))
    try await processor.waitForPrepare()
    await Task.yield()
    await processor.releasePrepare()

    let failure = try await recorder.waitUntil {
      if case .failure(_, id: invocation.id, _) = $0 {
        true
      } else {
        false
      }
    }
    guard case .failure(let epoch, _, let detail) = failure else {
      return XCTFail("Expected a targeted invocation failure")
    }
    XCTAssertEqual(epoch, invocation.id.epoch)
    XCTAssertEqual(detail.kind, .configuration)
    _ = try await recorder.waitUntil {
      if case .readiness(_, .unavailable) = $0 {
        true
      } else {
        false
      }
    }
    let resetCount = await processor.resetCount()
    XCTAssertEqual(resetCount, 0)
  }

  func testOutOfOrderAudioFailsWithoutCallingProcessor() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "unused", candidateText: nil)
    )
    let backend = makeBackend(processor: processor, policy: .disabled)
    let recorder = EventRecorder(stream: backend.events)
    let invocation = makeInvocation(generation: 3)

    XCTAssertTrue(backend.submit(.prepare(epoch: invocation.id.epoch)))
    _ = try await recorder.waitUntil {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }
    XCTAssertTrue(backend.submit(.begin(invocation)))
    XCTAssertTrue(backend.submit(.append(id: invocation.id, sequence: 1, audio: Data([0, 0]))))

    let failure = try await recorder.waitUntil {
      if case .failure(_, id: invocation.id, _) = $0 {
        return true
      }
      return false
    }
    guard case .failure(_, _, let detail) = failure else {
      return XCTFail("Expected invocation failure")
    }
    XCTAssertEqual(detail.kind, .capture)
    let appendedChunks = await processor.appendedChunks()
    XCTAssertEqual(appendedChunks, [])
  }

  func testMissingCorrectionPipelineReturnsRawTextAsDegraded() async throws {
    let processor = FakeFluidAudioProcessor(
      final: FluidAudioProcessResult(rawText: "usable raw text", candidateText: nil)
    )
    let backend = makeBackend(processor: processor, policy: .strict)
    let recorder = EventRecorder(stream: backend.events)
    let invocation = makeInvocation(generation: 4)

    XCTAssertTrue(backend.submit(.prepare(epoch: invocation.id.epoch)))
    _ = try await recorder.waitUntil {
      if case .readiness(_, .ready) = $0 {
        true
      } else {
        false
      }
    }
    XCTAssertTrue(backend.submit(.begin(invocation)))
    XCTAssertTrue(backend.submit(.finish(id: invocation.id)))

    let event = try await recorder.waitUntil {
      if case .final(id: invocation.id, _) = $0 {
        return true
      }
      return false
    }
    XCTAssertEqual(
      event,
      .final(
        id: invocation.id,
        result: TranscriptionFinalResult(text: "usable raw text", correction: .degraded)
      )
    )
  }

  private func makeBackend(
    processor: FakeFluidAudioProcessor,
    policy: LocalCorrectionPolicy,
    release: @escaping @Sendable () async -> Void = {},
    correctionRelease: @escaping @Sendable () async -> Void = {},
    context: LocalInvocationContext = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "user_id"),
    ])
  ) -> FluidAudioTranscriptionBackend {
    FluidAudioTranscriptionBackend(
      context: context,
      correctionPolicy: policy,
      processor: processor,
      acquireModels: { _, _ in
        FluidAudioModelLease(
          primaryDirectory: URL(fileURLWithPath: "/owned/primary"),
          release: release
        )
      },
      acquireCorrection: {
        FluidAudioCorrectionLease(
          directory: URL(fileURLWithPath: "/owned/ctc"),
          release: correctionRelease
        )
      }
    )
  }

  private func makeInvocation(generation: Int) -> TranscriptionInvocation {
    TranscriptionInvocation(
      id: TranscriptionInvocationID(epoch: TranscriptionBackendEpoch(7), generation: generation),
      format: .local
    )
  }
}

private func updateConfiguration(
  _ backend: FluidAudioTranscriptionBackend,
  entries: [String],
  policy: LocalCorrectionPolicy
) async throws -> Bool {
  try await backend.updateConfiguration(
    context: LocalInvocationContext(permanentEntries: entries.map {
      LocalVocabularyEntry(canonicalText: $0)
    }),
    correctionPolicy: policy
  )
}

private func makeLeaseTrackingBackend(
  processor: FakeFluidAudioProcessor,
  primaryReleases: ReleaseRecorder,
  correctionReleases: ReleaseRecorder
) -> FluidAudioTranscriptionBackend {
  FluidAudioTranscriptionBackend(
    context: LocalInvocationContext(permanentEntries: []),
    correctionPolicy: .disabled,
    processor: processor,
    acquireModels: { _, _ in
      FluidAudioModelLease(
        primaryDirectory: URL(fileURLWithPath: "/owned/primary"),
        release: { await primaryReleases.record() }
      )
    },
    acquireCorrection: {
      FluidAudioCorrectionLease(
        directory: URL(fileURLWithPath: "/owned/ctc"),
        release: { await correctionReleases.record() }
      )
    }
  )
}

private actor FakeFluidAudioProcessor: FluidAudioProcessing {
  private let finalResult: FluidAudioProcessResult
  private var shouldBlockPrepare: Bool
  private var shouldFailPrepare: Bool
  private var shouldBlockFinish: Bool
  private let ignoreFinishCancellation: Bool
  private var finishStarted = false
  private var finishCancelled = false
  private var prepareStarted = false
  private var prepareCancellationObserved = false
  private var prepareContinuation: CheckedContinuation<Void, Error>?
  private var finishContinuation: CheckedContinuation<Void, Error>?
  private var preparedPrimaryDirectory: URL?
  private var preparations = 0
  private var primaryLoads = 0
  private var currentContext: LocalInvocationContext?
  private var currentCorrectionDirectory: URL?
  private var resets = 0
  private var chunks: [Data] = []

  init(
    final: FluidAudioProcessResult,
    blockPrepare: Bool = false,
    failPrepare: Bool = false,
    blockFinish: Bool = false,
    ignoreFinishCancellation: Bool = false
  ) {
    finalResult = final
    shouldBlockPrepare = blockPrepare
    shouldFailPrepare = failPrepare
    shouldBlockFinish = blockFinish
    self.ignoreFinishCancellation = ignoreFinishCancellation
  }

  func prepare(
    primaryDirectory: URL,
    correctionDirectory: URL?,
    context: LocalInvocationContext,
    correctionPolicy _: LocalCorrectionPolicy
  ) async throws {
    prepareStarted = true
    preparations += 1
    currentContext = context
    currentCorrectionDirectory = correctionDirectory
    if preparedPrimaryDirectory != primaryDirectory {
      preparedPrimaryDirectory = primaryDirectory
      primaryLoads += 1
    }
    if shouldBlockPrepare {
      shouldBlockPrepare = false
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          prepareContinuation = continuation
        }
      } onCancel: {
        Task { await self.recordPrepareCancellation() }
      }
    }
    if shouldFailPrepare {
      shouldFailPrepare = false
      throw FakeProcessorError.preparationFailed
    }
  }

  func reset() throws {
    resets += 1
  }

  func append(_ audio: Data) throws -> String {
    chunks.append(audio)
    return "raw preview"
  }

  func finish() async throws -> FluidAudioProcessResult {
    finishStarted = true
    if shouldBlockFinish, ignoreFinishCancellation {
      try await withCheckedThrowingContinuation { continuation in
        finishContinuation = continuation
      }
    }
    do {
      while shouldBlockFinish {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(5))
      }
    } catch is CancellationError {
      finishCancelled = true
      throw CancellationError()
    }
    return finalResult
  }

  func unload() {}

  func releaseFinish() {
    shouldBlockFinish = false
    finishContinuation?.resume()
    finishContinuation = nil
  }

  func releasePrepare() {
    shouldBlockPrepare = false
    prepareContinuation?.resume()
    prepareContinuation = nil
  }

  func failNextPrepare() {
    shouldFailPrepare = true
  }

  func blockNextPrepare() {
    shouldBlockPrepare = true
    prepareCancellationObserved = false
  }

  func waitForPrepare() async throws {
    for _ in 0 ..< 200 where !prepareStarted {
      try await Task.sleep(for: .milliseconds(5))
    }
    guard prepareStarted else { throw TestWaitError.timedOut }
  }

  func waitForPrepareCount(_ expectedCount: Int) async throws {
    for _ in 0 ..< 200 where preparations < expectedCount {
      try await Task.sleep(for: .milliseconds(5))
    }
    guard preparations >= expectedCount else { throw TestWaitError.timedOut }
  }

  func waitForPrepareCancellation() async throws {
    for _ in 0 ..< 200 where !prepareCancellationObserved {
      try await Task.sleep(for: .milliseconds(5))
    }
    guard prepareCancellationObserved else { throw TestWaitError.timedOut }
  }

  private func recordPrepareCancellation() {
    prepareCancellationObserved = true
  }

  func waitForFinish() async throws {
    for _ in 0 ..< 200 where !finishStarted {
      try await Task.sleep(for: .milliseconds(5))
    }
    guard finishStarted else { throw TestWaitError.timedOut }
  }

  func waitForFinishCancellation() async throws {
    for _ in 0 ..< 200 where !finishCancelled {
      try await Task.sleep(for: .milliseconds(5))
    }
    guard finishCancelled else { throw TestWaitError.timedOut }
  }

  func resetCount() -> Int {
    resets
  }

  func prepareCount() -> Int {
    preparations
  }

  func primaryLoadCount() -> Int {
    primaryLoads
  }

  func latestContext() -> LocalInvocationContext? {
    currentContext
  }

  func latestCorrectionDirectory() -> URL? {
    currentCorrectionDirectory
  }

  func appendedChunks() -> [Data] {
    chunks
  }
}

private actor ReleaseRecorder {
  private var releases = 0
  private var shouldBlockNext: Bool
  private var isBlocked = false
  private var cancellationObserved = false
  private var continuation: CheckedContinuation<Void, Never>?

  init(blockNext: Bool = false) {
    shouldBlockNext = blockNext
  }

  func record() async {
    releases += 1
    guard shouldBlockNext else { return }
    shouldBlockNext = false
    isBlocked = true
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
      }
    } onCancel: {
      Task { await self.recordCancellation() }
    }
    isBlocked = false
  }

  func count() -> Int {
    releases
  }

  func waitUntilBlocked() async throws {
    for _ in 0 ..< 200 where !isBlocked {
      try await Task.sleep(for: .milliseconds(5))
    }
    guard isBlocked else { throw TestWaitError.timedOut }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }

  func waitUntilCancellationObserved() async throws {
    for _ in 0 ..< 200 where !cancellationObserved {
      try await Task.sleep(for: .milliseconds(5))
    }
    guard cancellationObserved else { throw TestWaitError.timedOut }
  }

  private func recordCancellation() {
    cancellationObserved = true
  }
}

private actor EventRecorder {
  private var events: [TranscriptionEngineEvent] = []

  init(stream: AsyncStream<TranscriptionEngineEvent>) {
    Task { [weak self] in
      for await event in stream {
        await self?.record(event)
      }
    }
  }

  func snapshot() -> [TranscriptionEngineEvent] {
    events
  }

  func waitUntil(
    after eventIndex: Int = 0,
    _ predicate: @Sendable (TranscriptionEngineEvent) -> Bool
  ) async throws -> TranscriptionEngineEvent {
    for _ in 0 ..< 200 {
      if let event = events.dropFirst(eventIndex).first(where: predicate) {
        return event
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw TestWaitError.timedOut
  }

  private func record(_ event: TranscriptionEngineEvent) {
    events.append(event)
  }
}

private enum TestWaitError: Error {
  case timedOut
}

private enum FakeProcessorError: Error {
  case preparationFailed
}
