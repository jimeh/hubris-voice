import AVFoundation
import Darwin
import FluidAudio
import Foundation

private struct Recording: Decodable {
  let recordingID: String
  let voice: String
  let file: String
  let seconds: Double
  let terms: [String]
  let aliases: [String: [String]]

  private enum CodingKeys: String, CodingKey {
    case recordingID = "id"
    case voice, file, seconds, terms, aliases
  }
}

private struct Manifest: Decodable {
  let recordings: [Recording]
}

private enum Mode: String {
  case builtin
  case `public`
}

private enum ProbeError: LocalizedError {
  case usage
  case unknownMode(String)
  case missingDirectory(URL)
  case noSelectedRecordings

  var errorDescription: String? {
    switch self {
    case .usage:
      "Usage: CacheIsolationProbe builtin|public owned-model-root manifest.json"
    case .unknownMode(let value):
      "Unknown mode '\(value)'; expected 'builtin' or 'public'"
    case .missingDirectory(let url):
      "Required model directory does not exist: \(url.path)"
    case .noSelectedRecordings:
      "Manifest has no identifiers recordings or Jim-take-1 technical/brands recordings"
    }
  }
}

private struct StagedError: LocalizedError {
  let stage: String
  let underlying: Error

  var errorDescription: String? {
    underlying.localizedDescription
  }
}

private struct PublicCorrectionPipeline {
  let vocabulary: CustomVocabularyContext
  let spotter: CtcKeywordSpotter
  let rescorer: VocabularyRescorer
  let cbw: Float
}

private struct ProbeContext {
  let mode: Mode
  let manager: StreamingUnifiedAsrManager
  let ctcModels: CtcModels
  let ctcDirectory: URL
  let primaryLoadSeconds: Double
  let ctcLoadSeconds: Double
}

private struct TranscriptionResult {
  let samples: [Float]
  let tokenTimings: [TokenTiming]
  let rawText: String
  let finalText: String
  let previewCount: Int
  let seconds: Double
}

private func now() -> Double {
  ProcessInfo.processInfo.systemUptime
}

private func emit(_ object: [String: Any]) throws {
  let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data([10]))
}

private func readAudio(_ recording: Recording) throws -> [Float] {
  let file = try AVAudioFile(forReading: URL(fileURLWithPath: recording.file))
  guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 else {
    throw NSError(
      domain: "CacheIsolationProbe",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Expected 16 kHz mono audio: \(recording.file)"]
    )
  }
  guard let buffer = AVAudioPCMBuffer(
    pcmFormat: file.processingFormat,
    frameCapacity: AVAudioFrameCount(file.length)
  ) else {
    throw NSError(
      domain: "CacheIsolationProbe",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "Could not allocate an audio buffer for \(recording.file)"]
    )
  }
  try file.read(into: buffer)
  guard let channelData = buffer.floatChannelData else {
    throw NSError(
      domain: "CacheIsolationProbe",
      code: 3,
      userInfo: [NSLocalizedDescriptionKey: "Audio buffer has no float channel data: \(recording.file)"]
    )
  }
  return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
}

private func audioBuffer(_ samples: ArraySlice<Float>) throws -> AVAudioPCMBuffer {
  guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
        let channelData = buffer.floatChannelData
  else {
    throw NSError(
      domain: "CacheIsolationProbe",
      code: 4,
      userInfo: [NSLocalizedDescriptionKey: "Could not create a 16 kHz mono audio chunk"]
    )
  }
  buffer.frameLength = buffer.frameCapacity
  samples.withUnsafeBufferPointer { pointer in
    if let source = pointer.baseAddress {
      channelData[0].update(from: source, count: samples.count)
    }
  }
  return buffer
}

private func selectedRecordings(from manifest: Manifest) throws -> [Recording] {
  let recordings = manifest.recordings.filter { recording in
    recording.recordingID == "identifiers"
      || (["technical", "brands"].contains(recording.recordingID) && recording.voice == "Jim-take-1")
  }
  guard !recordings.isEmpty else {
    throw ProbeError.noSelectedRecordings
  }
  return recordings
}

private func vocabulary(for recording: Recording, tokenizer: CtcTokenizer? = nil) -> CustomVocabularyContext {
  let terms = recording.terms.compactMap { text -> CustomVocabularyTerm? in
    let tokenIDs = tokenizer?.encode(text)
    if tokenizer != nil, tokenIDs?.isEmpty != false {
      return nil
    }
    return CustomVocabularyTerm(
      text: text,
      aliases: recording.aliases[text],
      ctcTokenIds: tokenIDs
    )
  }
  return CustomVocabularyContext(terms: terms, minSimilarity: 0.8)
}

private func makePublicPipeline(
  recording: Recording,
  ctcModels: CtcModels,
  ctcDirectory: URL
) async throws -> PublicCorrectionPipeline {
  let tokenizer = try await CtcTokenizer.load(from: ctcDirectory)
  let context = vocabulary(for: recording, tokenizer: tokenizer)
  let spotter = CtcKeywordSpotter(models: ctcModels, blankId: ctcModels.vocabulary.count)
  let config = VocabularyRescorer.Config(
    shortTermCbwTaperPivot: 1,
    spotterRescueMinSimilarity: 0.8,
    spotterRescueMultiWordMinSimilarity: 0.85
  )
  let rescorer = try await VocabularyRescorer.create(
    spotter: spotter,
    vocabulary: context,
    config: config,
    ctcModelDirectory: ctcDirectory
  )
  return PublicCorrectionPipeline(
    vocabulary: context,
    spotter: spotter,
    rescorer: rescorer,
    cbw: ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count).cbw
  )
}

private func transcribe(
  recording: Recording,
  manager: StreamingUnifiedAsrManager
) async throws -> TranscriptionResult {
  let samples = try readAudio(recording)
  let start = now()
  var tokenTimings: [TokenTiming] = []
  var previewCount = 0
  var previousPreview = ""
  for offset in stride(from: 0, to: samples.count, by: 1_600) {
    let end = min(offset + 1_600, samples.count)
    try await manager.appendAudio(audioBuffer(samples[offset ..< end]))
    try await manager.processBufferedAudio()
    let newTimings = await manager.consumeTokenTimings()
    tokenTimings.append(contentsOf: newTimings)
    let preview = await manager.getPartialTranscript()
    if preview != previousPreview {
      previewCount += 1
      previousPreview = preview
    }
  }
  let finalText = try await manager.finish()
  let finalTimings = await manager.consumeTokenTimings()
  tokenTimings.append(contentsOf: finalTimings)
  let rawText = tokenTimings.map(\.token).joined().trimmingCharacters(in: .whitespacesAndNewlines)
  return TranscriptionResult(
    samples: samples,
    tokenTimings: tokenTimings,
    rawText: rawText,
    finalText: finalText,
    previewCount: previewCount,
    seconds: now() - start
  )
}

private func correct(
  transcription: TranscriptionResult,
  pipeline: PublicCorrectionPipeline?
) async throws -> String {
  guard let pipeline else {
    return transcription.finalText
  }
  let result = try await pipeline.spotter.spotKeywordsWithLogProbs(
    audioSamples: transcription.samples,
    customVocabulary: pipeline.vocabulary
  )
  return pipeline.rescorer.ctcTokenRescore(
    transcript: transcription.rawText,
    tokenTimings: transcription.tokenTimings,
    logProbs: result.logProbs,
    frameDuration: result.frameDuration,
    cbw: pipeline.cbw,
    // Match VocabularyBoostingSession.rescore's effective margin.
    marginSeconds: 0.5,
    minSimilarity: 0.8
  ).text
}

private func process(
  recording: Recording,
  context: ProbeContext
) async throws {
  var stage = "configure:\(recording.recordingID):\(recording.voice)"
  do {
    try await context.manager.reset()
    let configureStart = now()
    let publicPipeline: PublicCorrectionPipeline?
    switch context.mode {
    case .builtin:
      try await context.manager.configureVocabularyBoosting(
        vocabulary: vocabulary(for: recording),
        ctcModels: context.ctcModels,
        config: VocabularyRescorer.Config(
          shortTermCbwTaperPivot: 1,
          spotterRescueMinSimilarity: 0.8,
          spotterRescueMultiWordMinSimilarity: 0.85
        )
      )
      publicPipeline = nil
    case .public:
      publicPipeline = try await makePublicPipeline(
        recording: recording,
        ctcModels: context.ctcModels,
        ctcDirectory: context.ctcDirectory
      )
    }
    let configureSeconds = now() - configureStart

    stage = "transcribe:\(recording.recordingID):\(recording.voice)"
    let transcription = try await transcribe(recording: recording, manager: context.manager)

    stage = "correct:\(recording.recordingID):\(recording.voice)"
    let correctionStart = now()
    let correctedText = try await correct(transcription: transcription, pipeline: publicPipeline)
    let correctionSeconds = now() - correctionStart

    try emit([
      "mode": context.mode.rawValue,
      "stage": "result",
      "id": recording.recordingID,
      "voice": recording.voice,
      "audio_seconds": recording.seconds,
      "primary_load_seconds": context.primaryLoadSeconds,
      "ctc_load_seconds": context.ctcLoadSeconds,
      "configure_seconds": configureSeconds,
      "transcription_seconds": transcription.seconds,
      "correction_seconds": correctionSeconds,
      "preview_count": transcription.previewCount,
      "raw": transcription.rawText,
      "corrected": correctedText,
    ])
  } catch {
    throw StagedError(stage: stage, underlying: error)
  }
}

private func loadContext(mode: Mode, modelRoot: URL) async throws -> ProbeContext {
  let primaryDirectory = modelRoot.appendingPathComponent("primary", isDirectory: true)
  let ctcDirectory = modelRoot.appendingPathComponent("ctc", isDirectory: true)
  for directory in [primaryDirectory, ctcDirectory]
    where !FileManager.default.fileExists(atPath: directory.path)
  {
    throw ProbeError.missingDirectory(directory)
  }

  let manager = StreamingUnifiedAsrManager(
    config: UnifiedConfig(leftFrames: 70, chunkFrames: 2, rightFrames: 2)
  )
  let primaryStart = now()
  do {
    try await manager.loadModels(from: primaryDirectory)
  } catch {
    throw StagedError(stage: "load-primary", underlying: error)
  }
  let primaryLoadSeconds = now() - primaryStart

  let ctcStart = now()
  let ctcModels: CtcModels
  do {
    ctcModels = try await CtcModels.loadDirect(from: ctcDirectory)
  } catch {
    throw StagedError(stage: "load-ctc", underlying: error)
  }
  return ProbeContext(
    mode: mode,
    manager: manager,
    ctcModels: ctcModels,
    ctcDirectory: ctcDirectory,
    primaryLoadSeconds: primaryLoadSeconds,
    ctcLoadSeconds: now() - ctcStart
  )
}

@main
private struct CacheIsolationProbe {
  static func main() async {
    let modeValue = CommandLine.arguments.dropFirst().first ?? ""
    var stage = "arguments"
    do {
      guard CommandLine.arguments.count == 4 else {
        throw ProbeError.usage
      }
      guard let mode = Mode(rawValue: modeValue) else {
        throw ProbeError.unknownMode(modeValue)
      }

      let modelRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        .standardizedFileURL

      stage = "manifest"
      let manifest = try JSONDecoder().decode(
        Manifest.self,
        from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
      )
      let recordings = try selectedRecordings(from: manifest)

      stage = "load-primary"
      let context = try await loadContext(mode: mode, modelRoot: modelRoot)
      try emit([
        "mode": mode.rawValue,
        "stage": "loaded",
        "primary_load_seconds": context.primaryLoadSeconds,
        "ctc_load_seconds": context.ctcLoadSeconds,
        "recording_count": recordings.count,
      ])

      for recording in recordings {
        try await process(
          recording: recording,
          context: context
        )
      }
    } catch {
      let emittedError: Error
      if let stagedError = error as? StagedError {
        stage = stagedError.stage
        emittedError = stagedError.underlying
      } else {
        emittedError = error
      }
      try? emit([
        "mode": modeValue,
        "stage": stage,
        "error": emittedError.localizedDescription,
        "error_type": String(reflecting: type(of: emittedError)),
      ])
      exit(EXIT_FAILURE)
    }
  }
}
