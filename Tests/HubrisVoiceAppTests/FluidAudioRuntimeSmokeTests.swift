@preconcurrency import AVFoundation
import Foundation
@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

final class FluidAudioRuntimeSmokeTests: XCTestCase {
  func testOwnedModelsProduceRawAndCorrectedLongTranscript() async throws {
    guard ProcessInfo.processInfo.environment["HUBRIS_LOCAL_RUNTIME_SMOKE"] == "1" else {
      throw XCTSkip("Set HUBRIS_LOCAL_RUNTIME_SMOKE=1 and run under the network-denied sandbox profile.")
    }
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let pointer = repository.appendingPathComponent(
      "Experiments/LocalSTT/.build/cache-isolation/owned-root.txt"
    )
    let ownedRoot = try URL(
      fileURLWithPath: String(contentsOf: pointer, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    )
    let audioURL = repository.appendingPathComponent(
      "Experiments/LocalSTT/.build/audio/Daniel-long.wav"
    )
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
      throw XCTSkip("Prepared synthetic long-audio fixture is absent.")
    }

    let audio = try Self.pcm16Data(from: audioURL)
    let audioDuration = Double(audio.count) / Double(16_000 * MemoryLayout<Int16>.size)
    let sentinel = "private-vocabulary-\(UUID().uuidString)"
    let expectedTerms = ["PostgreSQL", "Torvane"]
    let context = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "PostgreSQL"),
      LocalVocabularyEntry(canonicalText: "Torvane"),
      LocalVocabularyEntry(canonicalText: "Kubernetes"),
      LocalVocabularyEntry(canonicalText: sentinel, explicitAliases: ["private logging sentinel"]),
    ])

    let disabled = try await Self.run(
      processor: FluidAudioProcessor(),
      modelRoot: ownedRoot,
      context: context,
      policy: .disabled,
      audio: audio
    )
    XCTAssertFalse(disabled.result.rawText.isEmpty)
    XCTAssertNil(disabled.result.candidateText)
    XCTAssertNotNil(disabled.firstPreviewSeconds)

    let strict = try await Self.run(
      processor: FluidAudioProcessor(),
      modelRoot: ownedRoot,
      context: context,
      policy: .strict,
      audio: audio
    )
    XCTAssertFalse(strict.result.rawText.isEmpty)
    let candidate = try XCTUnwrap(strict.result.candidateText)
    XCTAssertFalse(candidate.isEmpty)
    XCTAssertNotNil(strict.firstPreviewSeconds)
    for term in expectedTerms {
      XCTAssertTrue(
        Self.containsWholeWord(term, in: candidate),
        "Expected a complete canonical term in the strict correction candidate: \(term)"
      )
    }

    Self.report(mode: "disabled", metrics: disabled, audioDuration: audioDuration)
    Self.report(mode: "strict", metrics: strict, audioDuration: audioDuration)

    XCTAssertFalse(disabled.result.rawText.contains(sentinel))
    XCTAssertFalse(strict.result.rawText.contains(sentinel))
    XCTAssertFalse(candidate.contains(sentinel))
    let logURL = URL(fileURLWithPath: (DiagnosticLog.displayPath as NSString).expandingTildeInPath)
    let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    XCTAssertFalse(log.contains(sentinel))
  }

  private static func run(
    processor: FluidAudioProcessor,
    modelRoot: URL,
    context: LocalInvocationContext,
    policy: LocalCorrectionPolicy,
    audio: Data
  ) async throws -> Metrics {
    let loadStartedAt = Date()
    try await processor.prepare(
      primaryDirectory: modelRoot.appendingPathComponent("primary"),
      correctionDirectory: policy == .strict ? modelRoot.appendingPathComponent("ctc") : nil,
      context: context,
      correctionPolicy: policy
    )
    let loadSeconds = Date().timeIntervalSince(loadStartedAt)
    try await processor.reset()

    let streamingStartedAt = Date()
    var firstPreviewSeconds: TimeInterval?
    for offset in stride(from: 0, to: audio.count, by: 3_200) {
      let end = min(offset + 3_200, audio.count)
      let preview = try await processor.append(audio[offset ..< end])
      if firstPreviewSeconds == nil, !preview.isEmpty {
        firstPreviewSeconds = Date().timeIntervalSince(streamingStartedAt)
      }
    }
    let streamProcessingSeconds = Date().timeIntervalSince(streamingStartedAt)

    let finalizeStartedAt = Date()
    let result = try await processor.finish()
    let finalizeSeconds = Date().timeIntervalSince(finalizeStartedAt)
    await processor.unload()
    return Metrics(
      result: result,
      loadSeconds: loadSeconds,
      firstPreviewSeconds: firstPreviewSeconds,
      streamProcessingSeconds: streamProcessingSeconds,
      finalizeSeconds: finalizeSeconds
    )
  }

  private static func report(mode: String, metrics: Metrics, audioDuration: TimeInterval) {
    func formatted(_ value: TimeInterval?) -> String {
      value.map { String(format: "%.3f", $0) } ?? "none"
    }
    print(
      "LOCAL_RUNTIME_SMOKE mode=\(mode) " +
        "audio_duration=\(formatted(audioDuration)) " +
        "load_seconds=\(formatted(metrics.loadSeconds)) " +
        "first_preview_seconds=\(formatted(metrics.firstPreviewSeconds)) " +
        "stream_processing_seconds=\(formatted(metrics.streamProcessingSeconds)) " +
        "finalize_seconds=\(formatted(metrics.finalizeSeconds)) " +
        "raw_characters=\(metrics.result.rawText.count) " +
        "candidate_characters=\(metrics.result.candidateText?.count ?? 0)"
    )
  }

  private static func containsWholeWord(_ term: String, in text: String) -> Bool {
    let escaped = NSRegularExpression.escapedPattern(for: term)
    return text.range(
      of: "(?<![\\p{L}\\p{M}\\p{N}_])\(escaped)(?![\\p{L}\\p{M}\\p{N}_])",
      options: .regularExpression
    ) != nil
  }

  private static func pcm16Data(from url: URL) throws -> Data {
    let file = try AVAudioFile(forReading: url)
    guard
      file.processingFormat.sampleRate == 16_000,
      file.processingFormat.channelCount == 1,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(file.length)
      )
    else {
      throw SmokeError.invalidAudio
    }
    try file.read(into: buffer)
    guard let channel = buffer.floatChannelData?.pointee else { throw SmokeError.invalidAudio }
    var data = Data(capacity: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    for index in 0 ..< Int(buffer.frameLength) {
      let scaled = Int16(clamping: Int(channel[index] * 32_767))
      var littleEndian = scaled.littleEndian
      withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }
}

private struct Metrics {
  let result: FluidAudioProcessResult
  let loadSeconds: TimeInterval
  let firstPreviewSeconds: TimeInterval?
  let streamProcessingSeconds: TimeInterval
  let finalizeSeconds: TimeInterval
}

private enum SmokeError: Error {
  case invalidAudio
}
