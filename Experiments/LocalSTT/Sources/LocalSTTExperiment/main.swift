import AVFoundation
import Darwin
import FluidAudio
import Foundation

struct Recording: Decodable {
  let id: String
  let voice: String
  let file: String
  let seconds: Double
  let terms: [String]
  let aliases: [String: [String]]
}

struct Manifest: Decodable {
  let distractors: [String]
  let recordings: [Recording]
}

func now() -> Double {
  ProcessInfo.processInfo.systemUptime
}

func emit(_ object: [String: Any]) throws {
  let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data([10]))
}

func readAudio(_ recording: Recording) throws -> [Float] {
  let file = try AVAudioFile(forReading: URL(fileURLWithPath: recording.file))
  precondition(file.processingFormat.sampleRate == 16_000 && file.processingFormat.channelCount == 1)
  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
  try file.read(into: buffer)
  return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

func audioBuffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer {
  let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
  buffer.frameLength = buffer.frameCapacity
  samples.withUnsafeBufferPointer { pointer in
    buffer.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
  }
  return buffer
}

@main
struct Experiment {
  static func main() async throws {
    let args = CommandLine.arguments
    guard args.count >= 3 else {
      fatalError("Usage: LocalSTTExperiment prepare|run|lifecycle manifest.json [paced] [320|640]")
    }
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    let paced = args.contains("paced")
    let captureRaw = args.contains("capture-raw")
    let correctionProfile = args.first { $0.hasPrefix("sweep-") }
    let supportedProfiles = ["sweep-default", "sweep-no-rescue", "sweep-taper", "sweep-strict", "sweep-conservative"]
    precondition(correctionProfile == nil || supportedProfiles.contains(correctionProfile!))
    let tier = args.contains("320") ? 320 : 640
    let manager = StreamingUnifiedAsrManager(config: tier == 320
      ? UnifiedConfig(leftFrames: 70, chunkFrames: 2, rightFrames: 2)
      : UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 1))
    let loading = now()
    if args[1] == "prepare" {
      try await manager.loadModels()
    } else {
      let modelDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio/Models/parakeet-unified-en-0.6b")
      try await manager.loadModels(from: modelDirectory)
    }
    let primarySeconds = now() - loading
    let ctcStart = now()
    let ctc: CtcModels = if args[1] == "prepare" {
      try await CtcModels.downloadAndLoad()
    } else {
      try await CtcModels.loadDirect(from: CtcModels.defaultCacheDirectory())
    }
    try emit([
      "kind": "load",
      "engine": "fluid",
      "version": "0.15.7",
      "tier_ms": tier,
      "primary_seconds": primarySeconds,
      "ctc_seconds": now() - ctcStart,
      "note": args[1] == "prepare"
        ? "Preparation may download missing models."
        : "Local model load; OS/CoreML caches may be warm.",
    ])
    if args[1] == "prepare" {
      return
    }
    let recordings = paced
      ? manifest.recordings
      .filter { ["Daniel", "Jim-take-1"].contains($0.voice) && ["identifiers", "long"].contains($0.id) }
      : manifest.recordings
    // Baseline runs before boosting has ever been configured. cleared runs verify
    // explicit empty replacement after vocabulary-bearing invocations.
    let modes = args[1] == "lifecycle" ? [] :
      correctionProfile != nil ? ["none", "relevant", "mixed", "filtered"] :
      paced ? ["relevant", "mixed"] : ["none", "relevant", "mixed", "aliases", "cleared"]
    for mode in modes {
      for recording in recordings {
        let samples = try readAudio(recording)
        let resetStart = now()
        try await manager.reset()
        let resetSeconds = now() - resetStart
        let selected = mode == "none" || mode == "cleared" ? [] : recording.terms
        let combined = mode == "mixed" || mode == "filtered"
          ? Array(Set(selected + manifest.distractors)).sorted() : selected
        let terms = mode == "filtered"
          ? combined.filter { $0.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count >= 6 }
          : combined
        let configureStart = now()
        if mode != "none" {
          let strict = correctionProfile == "sweep-strict" || correctionProfile == "sweep-conservative"
          let vocabulary = CustomVocabularyContext(terms: terms.map {
            CustomVocabularyTerm(
              text: $0,
              aliases: mode == "aliases" || correctionProfile != nil ? recording.aliases[$0] : nil
            )
          }, minSimilarity: strict ? 0.8 : 0.52)
          let tuning: VocabularyRescorer.Config? = correctionProfile.map { profile in
            VocabularyRescorer.Config(
              shortTermCbwTaperPivot: ["sweep-taper", "sweep-conservative"].contains(profile) ? 5 : 1,
              shortTermCbwTaperExponent: 2,
              spotterRescueMinSimilarity: strict ? 0.8 : 0.3,
              spotterRescueMultiWordMinSimilarity: strict ? 0.85 : 0.5,
              spotterRescueEnabled: !["sweep-no-rescue", "sweep-conservative"].contains(profile)
            )
          }
          try await manager.configureVocabularyBoosting(vocabulary: vocabulary, ctcModels: ctc, config: tuning)
        }
        let configureSeconds = now() - configureStart
        let start = now()
        var previews: [[String: Any]] = []
        var last = ""
        var rawTokenText = ""
        for offset in stride(from: 0, to: samples.count, by: 1_600) {
          let end = min(offset + 1_600, samples.count)
          if paced {
            let wait = start + Double(end) / 16_000 - now()
            if wait > 0 {
              try await Task.sleep(for: .seconds(wait))
            }
          }
          try await manager.appendAudio(audioBuffer(samples[offset ..< end]))
          try await manager.processBufferedAudio()
          if captureRaw {
            rawTokenText += await manager.consumeTokenTimings().map(\.token).joined()
          }
          let preview = await manager.getPartialTranscript()
          if preview != last {
            previews.append(["audio_seconds": Double(end) / 16_000, "wall_seconds": now() - start, "text": preview])
            last = preview
          }
        }
        let finishStart = now()
        let final = try await manager.finish()
        if captureRaw {
          rawTokenText += await manager.consumeTokenTimings().map(\.token).joined()
        }
        let finishSeconds = now() - finishStart
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        try emit([
          "kind": "result",
          "engine": "fluid",
          "tier_ms": tier,
          "correction_profile": correctionProfile ?? "original",
          "id": recording.id,
          "voice": recording.voice,
          "mode": mode,
          "paced": paced,
          "audio_seconds": recording.seconds,
          "reset_seconds": resetSeconds,
          "configure_seconds": configureSeconds,
          "finish_seconds": finishSeconds,
          "total_seconds": now() - start,
          "release_to_final_seconds": paced ? now() - start - recording.seconds : NSNull(),
          "peak_rss_bytes": usage.ru_maxrss,
          "terms": terms,
          "preview_before_finish": last,
          "previews": previews,
          "text": final,
          "raw_token_text": captureRaw ? rawTokenText.trimmingCharacters(in: .whitespacesAndNewlines) : NSNull(),
        ])
      }
    }
    // Cooperative reset between partial input and a new invocation. This does
    // not claim Task.cancel interrupts an in-flight CoreML prediction.
    let first = manifest.recordings[0]
    let samples = try readAudio(first)
    try await manager.reset()
    try await manager.appendAudio(audioBuffer(samples.prefix(min(16_000, samples.count))))
    try await manager.processBufferedAudio()
    let cancelStart = now()
    try await manager.reset()
    try await emit([
      "kind": "cancel_reset",
      "reset_seconds": now() - cancelStart,
      "preview_after_reset": manager.getPartialTranscript(),
    ])
    try await manager.appendAudio(audioBuffer(samples[...]))
    let fresh = try await manager.finish()
    try emit(["kind": "after_cancel", "id": first.id, "voice": first.voice, "text": fresh])
    if args[1] == "lifecycle" {
      let long = manifest.recordings.first { $0.id == "long" }!
      let longSamples = try readAudio(long)
      try await manager.reset()
      try await manager.appendAudio(audioBuffer(longSamples[...]))
      let entered = AsyncStream<Void>.makeStream()
      let start = now()
      let worker = Task {
        entered.continuation.yield(())
        entered.continuation.finish()
        do {
          let text = try await manager.finish()
          return ("completed", text, Task.isCancelled)
        } catch {
          return ("threw", String(describing: error), Task.isCancelled)
        }
      }
      // Signal establishes that the worker has started; it does not assert
      // that CoreML has entered a particular native prediction instruction.
      for await _ in entered.stream {
        break
      }
      worker.cancel()
      let outcome = await worker.value
      try emit([
        "kind": "task_cancel",
        "outcome": outcome.0,
        "text": outcome.1,
        "worker_observed_cancelled": outcome.2,
        "seconds": now() - start,
      ])
      try await manager.reset()
      try await emit(["kind": "post_task_cancel_reset", "preview": manager.getPartialTranscript()])
    }
  }
}
