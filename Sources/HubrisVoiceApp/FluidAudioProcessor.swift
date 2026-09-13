@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import HubrisVoiceCore

struct FluidAudioProcessResult: Sendable {
  let rawText: String
  let candidateText: String?
}

protocol FluidAudioProcessing: Sendable {
  func prepare(
    primaryDirectory: URL,
    correctionDirectory: URL?,
    context: LocalInvocationContext,
    correctionPolicy: LocalCorrectionPolicy
  ) async throws
  func reset() async throws
  func append(_ audio: Data) async throws -> String
  func finish() async throws -> FluidAudioProcessResult
  func unload() async
}

actor FluidAudioProcessor: FluidAudioProcessing {
  private struct CorrectionPipeline {
    let vocabulary: CustomVocabularyContext
    let spotter: CtcKeywordSpotter
    let rescorer: VocabularyRescorer
    let contextBiasWeight: Float
    let minimumSimilarity: Float
  }

  private let manager = StreamingUnifiedAsrManager(
    config: UnifiedConfig(leftFrames: 70, chunkFrames: 2, rightFrames: 2)
  )
  private var loadedPrimaryDirectory: URL?
  private var correction: CorrectionPipeline?
  private var samples: [Float] = []
  private var timings: [TokenTiming] = []

  func prepare(
    primaryDirectory: URL,
    correctionDirectory: URL?,
    context: LocalInvocationContext,
    correctionPolicy: LocalCorrectionPolicy
  ) async throws {
    let normalizedPrimaryDirectory = primaryDirectory.standardizedFileURL
    if loadedPrimaryDirectory != normalizedPrimaryDirectory {
      if loadedPrimaryDirectory != nil {
        await manager.cleanup()
        loadedPrimaryDirectory = nil
      }
      try await manager.loadModels(from: normalizedPrimaryDirectory)
      loadedPrimaryDirectory = normalizedPrimaryDirectory
    }
    guard
      let correctionDirectory,
      let configuration = correctionPolicy.configuration,
      !context.resolvedEntries.isEmpty
    else {
      correction = nil
      return
    }

    do {
      correction = try await makeCorrectionPipeline(
        directory: correctionDirectory,
        entries: context.resolvedEntries,
        configuration: configuration
      )
    } catch {
      correction = nil
    }
  }

  private func makeCorrectionPipeline(
    directory: URL,
    entries: [LocalVocabularyEntry],
    configuration: LocalCorrectionConfiguration
  ) async throws -> CorrectionPipeline? {
    let models = try await CtcModels.loadDirect(from: directory)
    let tokenizer = try await CtcTokenizer.load(from: directory)
    let vocabulary = CustomVocabularyContext(
      terms: entries.compactMap { entry in
        let tokenIDs = tokenizer.encode(entry.canonicalText)
        guard !tokenIDs.isEmpty else { return nil }
        return CustomVocabularyTerm(
          text: entry.canonicalText,
          aliases: entry.explicitAliases,
          ctcTokenIds: tokenIDs
        )
      },
      minSimilarity: Float(configuration.minimumSimilarity)
    )
    guard !vocabulary.terms.isEmpty else { return nil }
    let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
    let rescorer = try await VocabularyRescorer.create(
      spotter: spotter,
      vocabulary: vocabulary,
      config: VocabularyRescorer.Config(
        shortTermCbwTaperPivot: configuration.shortTermTaperPivot,
        shortTermCbwTaperExponent: 2,
        spotterRescueMinSimilarity: Float(configuration.rescueMinimumSimilarity),
        spotterRescueMultiWordMinSimilarity: Float(
          configuration.rescueMultiwordMinimumSimilarity
        ),
        spotterRescueEnabled: configuration.acousticRescueEnabled
      ),
      ctcModelDirectory: directory
    )
    return CorrectionPipeline(
      vocabulary: vocabulary,
      spotter: spotter,
      rescorer: rescorer,
      contextBiasWeight: ContextBiasingConstants.rescorerConfig(
        forVocabSize: vocabulary.terms.count
      ).cbw,
      minimumSimilarity: Float(configuration.minimumSimilarity)
    )
  }

  func reset() async throws {
    samples.removeAll(keepingCapacity: true)
    timings.removeAll(keepingCapacity: true)
    try await manager.reset()
  }

  func append(_ audio: Data) async throws -> String {
    let newSamples = try Self.decodePCM16(audio)
    samples.append(contentsOf: newSamples)
    try await manager.appendAudio(Self.audioBuffer(newSamples))
    try await manager.processBufferedAudio()
    await timings.append(contentsOf: manager.consumeTokenTimings())
    return await manager.getPartialTranscript()
  }

  func finish() async throws -> FluidAudioProcessResult {
    let managerText = try await manager.finish()
    await timings.append(contentsOf: manager.consumeTokenTimings())
    let rawText = timings.map(\.token).joined()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let usableRaw = rawText.isEmpty ? managerText : rawText
    guard let correction, !timings.isEmpty else {
      return FluidAudioProcessResult(rawText: usableRaw, candidateText: nil)
    }
    do {
      let candidate = try await correctedText(rawText: usableRaw, pipeline: correction)
      return FluidAudioProcessResult(rawText: usableRaw, candidateText: candidate)
    } catch {
      return FluidAudioProcessResult(rawText: usableRaw, candidateText: nil)
    }
  }

  func unload() async {
    loadedPrimaryDirectory = nil
    correction = nil
    samples.removeAll(keepingCapacity: false)
    timings.removeAll(keepingCapacity: false)
    await manager.cleanup()
  }

  /// Runs CTC in windows of at most 13 seconds of complete words plus one second
  /// of audio context on either side. No subword token crosses a window boundary.
  private func correctedText(
    rawText: String,
    pipeline: CorrectionPipeline
  ) async throws -> String {
    let contextSeconds = 1.0
    let duration = Double(samples.count) / 16_000
    var correctedSegments: [String] = []
    let segments = FluidAudioCorrectionSegmenter.segments(
      timings.enumerated().map { index, timing in
        .init(index: index, text: timing.token, startTime: timing.startTime, endTime: timing.endTime)
      }
    )
    for segment in segments {
      let selected = segment.map { timings[$0.index] }
      let audioStart = max(0, (selected.first?.startTime ?? 0) - contextSeconds)
      let audioEnd = min(duration, (selected.last?.endTime ?? duration) + contextSeconds)
      let lowerSample = Int(audioStart * 16_000)
      let upperSample = min(samples.count, Int(audioEnd * 16_000))
      let rebased = selected.map { timing in
        TokenTiming(
          token: timing.token,
          tokenId: timing.tokenId,
          startTime: timing.startTime - audioStart,
          endTime: timing.endTime - audioStart,
          confidence: timing.confidence
        )
      }
      let transcript = selected.map(\.token).joined()
      let spotted = try await pipeline.spotter.spotKeywordsWithLogProbs(
        audioSamples: Array(samples[lowerSample ..< upperSample]),
        customVocabulary: pipeline.vocabulary
      )
      let corrected = pipeline.rescorer.ctcTokenRescore(
        transcript: transcript,
        tokenTimings: rebased,
        logProbs: spotted.logProbs,
        frameDuration: spotted.frameDuration,
        cbw: pipeline.contextBiasWeight,
        marginSeconds: 0.5,
        minSimilarity: pipeline.minimumSimilarity
      ).text
      correctedSegments.append(corrected)
    }
    return correctedSegments.isEmpty ? rawText : correctedSegments.joined(separator: " ")
  }

  private static func decodePCM16(_ data: Data) throws -> [Float] {
    guard data.count.isMultiple(of: 2) else {
      throw TranscriptionFailure(
        kind: .capture,
        message: "Local audio ended with an incomplete PCM sample.",
        isRecoverable: false
      )
    }
    return data.withUnsafeBytes { bytes in
      stride(from: 0, to: bytes.count, by: 2).map { offset in
        let value = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        return Float(Int16(bitPattern: value)) / 32_768
      }
    }
  }

  private static func audioBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
    guard
      let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
      ),
      let channel = buffer.floatChannelData?.pointee
    else {
      throw TranscriptionFailure(
        kind: .capture,
        message: "Could not prepare local PCM audio.",
        isRecoverable: false
      )
    }
    buffer.frameLength = buffer.frameCapacity
    samples.withUnsafeBufferPointer { pointer in
      if let source = pointer.baseAddress {
        channel.update(from: source, count: samples.count)
      }
    }
    return buffer
  }
}

enum FluidAudioCorrectionSegmenter {
  struct TimedToken: Equatable, Sendable {
    let index: Int
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
  }

  static func segments(
    _ tokens: [TimedToken],
    maximumCoreDuration: TimeInterval = 13
  ) -> [[TimedToken]] {
    let words = words(from: tokens)
    var segments: [[TimedToken]] = []
    var current: [TimedToken] = []
    for word in words {
      if let start = current.first?.startTime,
         let end = word.last?.endTime,
         end - start > maximumCoreDuration,
         !current.isEmpty
      {
        segments.append(current)
        current = []
      }
      current.append(contentsOf: word)
    }
    if !current.isEmpty {
      segments.append(current)
    }
    return segments
  }

  private static func words(from tokens: [TimedToken]) -> [[TimedToken]] {
    var words: [[TimedToken]] = []
    for token in tokens {
      let startsWord = token.text.first?.isWhitespace == true
        || token.text.hasPrefix("▁")
        || words.isEmpty
      if startsWord {
        words.append([token])
      } else {
        words[words.index(before: words.endIndex)].append(token)
      }
    }
    return words
  }
}
