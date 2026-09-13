import CSherpa
import Darwin
import Foundation

struct Recording: Decodable {
  let id: String
  let voice: String
  let file: String
  let seconds: Double
  let terms: [String]
}

struct Manifest: Decodable {
  let distractors: [String]
  let recordings: [Recording]
}

func now() -> Double {
  ProcessInfo.processInfo.systemUptime
}

func emit(_ value: [String: Any]) throws {
  try FileHandle.standardOutput.write(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
  FileHandle.standardOutput.write(Data([10]))
}

@main
struct SherpaExperiment {
  static func main() throws {
    let args = CommandLine.arguments
    guard args.count >= 3 else { fatalError("Usage: SherpaExperiment model-dir manifest.json [greedy]") }
    let root = args[1]
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    let greedy = args.contains("greedy")
    let score = args.last.flatMap(Float.init) ?? 1.5
    var strings: [UnsafeMutablePointer<CChar>] = []
    func cString(_ value: String) -> UnsafePointer<CChar> {
      let pointer = strdup(value)!
      strings.append(pointer)
      return UnsafePointer(pointer)
    }
    defer { strings.forEach { free($0) } }
    var config = SherpaOnnxOfflineRecognizerConfig()
    config.feat_config.sample_rate = 16_000
    config.feat_config.feature_dim = 128
    config.model_config.transducer.encoder = cString(root + "/encoder.int8.onnx")
    config.model_config.transducer.decoder = cString(root + "/decoder.int8.onnx")
    config.model_config.transducer.joiner = cString(root + "/joiner.int8.onnx")
    config.model_config.tokens = cString(root + "/tokens.txt")
    config.model_config.model_type = cString("nemo_transducer")
    config.model_config.provider = cString("cpu")
    config.model_config.num_threads = 4
    config.model_config.modeling_unit = cString("bpe")
    config.model_config.bpe_vocab = cString(root + "/bpe.vocab")
    config.decoding_method = cString(greedy ? "greedy_search" : "modified_beam_search")
    config.max_active_paths = 4
    config.hotwords_score = score
    let loadStart = now()
    guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
      fatalError("Could not create recognizer")
    }
    defer { SherpaOnnxDestroyOfflineRecognizer(recognizer) }
    try emit([
      "kind": "load",
      "engine": "sherpa",
      "version": "1.13.8",
      "primary_seconds": now() - loadStart,
      "decoder": greedy ? "greedy" : "beam4",
      "provider": "cpu",
      "threads": 4,
      "hotwords_score": score,
    ])
    for mode in greedy ? ["none"] : ["none", "relevant", "mixed", "cleared"] {
      for recording in manifest.recordings {
        let selected = mode == "none" || mode == "cleared" ? [] : recording.terms
        let terms = mode == "mixed" ? Array(Set(selected + manifest.distractors)).sorted() : selected
        let configureStart = now()
        guard let stream = terms.joined(separator: "/").withCString({
          SherpaOnnxCreateOfflineStreamWithHotwords(recognizer, $0)
        }) else { fatalError("Could not create stream") }
        let configureSeconds = now() - configureStart
        guard let wave = recording.file.withCString({ SherpaOnnxReadWave($0) }) else {
          fatalError("Could not read fixture")
        }
        let start = now()
        SherpaOnnxAcceptWaveformOffline(
          stream,
          wave.pointee.sample_rate,
          wave.pointee.samples,
          wave.pointee.num_samples
        )
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        let elapsed = now() - start
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { fatalError("Missing result") }
        let text = String(cString: result.pointee.text)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        try emit([
          "kind": "result",
          "engine": "sherpa",
          "decoder": greedy ? "greedy" : "beam4",
          "id": recording.id,
          "voice": recording.voice,
          "mode": mode,
          "paced": false,
          "hotwords_score": score,
          "audio_seconds": recording.seconds,
          "configure_seconds": configureSeconds,
          "total_seconds": elapsed,
          "finish_seconds": elapsed,
          "peak_rss_bytes": usage.ru_maxrss,
          "terms": terms,
          "text": text,
        ])
        SherpaOnnxDestroyOfflineRecognizerResult(result)
        SherpaOnnxFreeWave(wave)
        SherpaOnnxDestroyOfflineStream(stream)
      }
    }
    // Destroy an undecoded, partially populated invocation; recognizer weights
    // remain loaded. Native DecodeOfflineStream itself is synchronous.
    let start = now()
    let stream = SherpaOnnxCreateOfflineStream(recognizer)!
    let wave = manifest.recordings[0].file.withCString { SherpaOnnxReadWave($0) }!
    SherpaOnnxAcceptWaveformOffline(stream, 16_000, wave.pointee.samples, min(16_000, wave.pointee.num_samples))
    SherpaOnnxDestroyOfflineStream(stream)
    SherpaOnnxFreeWave(wave)
    try emit(["kind": "cancel_before_decode", "seconds": now() - start])
  }
}
