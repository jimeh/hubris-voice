import AppKit
import AVFoundation
import CryptoKit
import SwiftUI

struct Phrase: Codable {
  let id: String
  let spoken: String
  let expected: String
  let terms: [String]
  let aliases: [String: [String]]
}

struct Corpus: Decodable {
  let distractors: [String]
  let cases: [Phrase]
}

struct Take: Codable {
  let id: String
  let voice: String
  let spoken: String
  let expected: String
  let terms: [String]
  let aliases: [String: [String]]
  let file: String
  let seconds: Double
  let sha256: String
}

struct SessionManifest: Codable {
  let distractors: [String]
  var recordings: [Take]
}

/// Accepted takes are durable; a pending recording never replaces an accepted take.
final class RecordingSession {
  let root: URL
  let corpus: Corpus
  private(set) var manifest: SessionManifest
  var count: Int {
    manifest.recordings.count
  }

  var complete: Bool {
    count == corpus.cases.count * 3
  }

  var phrase: Phrase {
    corpus.cases[min(count / 3, corpus.cases.count - 1)]
  }

  var takeNumber: Int {
    count % 3 + 1
  }

  init(root: URL, corpus: Corpus) throws {
    self.root = root
    self.corpus = corpus
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("manifest.json")
    if FileManager.default.fileExists(atPath: file.path) {
      manifest = try JSONDecoder().decode(SessionManifest.self, from: Data(contentsOf: file))
      guard manifest.recordings.count <= corpus.cases.count * 3,
            manifest.distractors == corpus.distractors
      else {
        throw CocoaError(.fileReadCorruptFile)
      }
      for (index, take) in manifest.recordings.enumerated() {
        let expected = corpus.cases[index / 3]
        guard take.id == expected.id, take.voice == "Jim-take-\(index % 3 + 1)",
              take.expected == expected.expected, take.terms == expected.terms,
              take.aliases == expected.aliases,
              FileManager.default.fileExists(atPath: take.file),
              try Self.hash(Data(contentsOf: URL(fileURLWithPath: take.file))) == take.sha256
        else {
          throw CocoaError(.fileReadCorruptFile)
        }
      }
    } else {
      manifest = SessionManifest(distractors: corpus.distractors, recordings: [])
    }
    // Recover completion if the application exited just after saving the last manifest.
    if complete {
      try writeReady()
    }
  }

  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func accept(_ pending: URL) throws {
    guard !complete else { throw CocoaError(.fileWriteFileExists) }
    let audio = try AVAudioFile(forReading: pending)
    guard audio.fileFormat.sampleRate == 16_000, audio.fileFormat.channelCount == 1,
          audio.length >= 8_000 else { throw CocoaError(.fileReadCorruptFile) }
    let data = try Data(contentsOf: pending)
    let output = root.appendingPathComponent("\(phrase.id)-take-\(takeNumber)-\(UUID().uuidString).wav")
    try data.write(to: output, options: .atomic)
    let take = Take(
      id: phrase.id, voice: "Jim-take-\(takeNumber)", spoken: phrase.expected,
      expected: phrase.expected, terms: phrase.terms, aliases: phrase.aliases,
      file: output.path, seconds: Double(audio.length) / 16_000,
      sha256: Self.hash(data)
    )
    var updated = manifest
    updated.recordings.append(take)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      try encoder.encode(updated).write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
    } catch {
      try? FileManager.default.removeItem(at: output)
      throw error
    }
    manifest = updated
    if complete {
      try writeReady()
    }
  }

  private func writeReady() throws {
    try Data("ready\n".utf8).write(to: root.appendingPathComponent("ready"), options: .atomic)
  }
}

@MainActor
final class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
  @Published var allowed = false
  @Published var recording = false
  @Published var pending: URL?
  @Published var elapsed = 0.0
  @Published var level = 0.0
  @Published var error = ""
  @Published var saved = 0
  let session: RecordingSession
  private var audio: AVAudioRecorder?
  private var player: AVAudioPlayer?
  private var timer: Timer?
  private var started: Date?

  init(session: RecordingSession) {
    self.session = session
    saved = session.count
    super.init()
    allowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    NotificationCenter.default.addObserver(
      self, selector: #selector(interrupted), name: NSApplication.didResignActiveNotification, object: nil
    )
  }

  func requestPermission() {
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      Task { @MainActor in
        self.allowed = granted
        if !granted {
          self.error = "Allow STT Phrase Recorder in System Settings → Privacy & Security → Microphone, then reopen it."
        }
      }
    }
  }

  func start() {
    guard allowed, !recording, pending == nil, !session.complete else { return }
    error = ""
    player?.stop()
    let file = session.root.appendingPathComponent("pending-\(UUID().uuidString).wav")
    do {
      let recorder = try AVAudioRecorder(url: file, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ])
      recorder.delegate = self
      recorder.isMeteringEnabled = true
      guard recorder.prepareToRecord(), recorder.record() else {
        throw CocoaError(.fileWriteUnknown)
      }
      audio = recorder
      recording = true
      elapsed = 0
      started = Date()
      let tick = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.tick() }
      }
      timer = tick
      RunLoop.main.add(tick, forMode: .common)
    } catch {
      self.error = "Could not start the microphone: \(error.localizedDescription)"
      try? FileManager.default.removeItem(at: file)
    }
  }

  private func tick() {
    guard recording else { return }
    elapsed = Date().timeIntervalSince(started ?? Date())
    audio?.updateMeters()
    level = max(0, min(1, (Double(audio?.averagePower(forChannel: 0) ?? -60) + 60) / 60))
    if elapsed >= 120 {
      stop()
    }
  }

  func stop() {
    guard recording, let audio else { return }
    audio.stop()
    timer?.invalidate()
    timer = nil
    recording = false
    level = 0
    do {
      let file = try AVAudioFile(forReading: audio.url)
      guard file.length >= 8_000 else { throw CocoaError(.fileReadCorruptFile) }
      elapsed = Double(file.length) / file.fileFormat.sampleRate
      pending = audio.url
    } catch {
      self.error = "That take was too short or could not be read. Hold the button while speaking, then release it."
      try? FileManager.default.removeItem(at: audio.url)
    }
    self.audio = nil
  }

  @objc private func interrupted() {
    if recording {
      stop()
      error = "Recording stopped because the window lost focus. Listen before keeping this take."
    }
  }

  func play() {
    guard let pending else { return }
    do {
      player = try AVAudioPlayer(contentsOf: pending)
      guard player?.play() == true else { throw CocoaError(.fileReadUnknown) }
    } catch { self.error = "Playback failed: \(error.localizedDescription)" }
  }

  func redo() {
    player?.stop()
    if let pending {
      try? FileManager.default.removeItem(at: pending)
    }
    pending = nil
    elapsed = 0
    error = ""
  }

  func keep() {
    guard let pending else { return }
    do {
      try session.accept(pending)
      saved = session.count
      redo()
    } catch { self.error = "Could not save this take: \(error.localizedDescription)" }
  }

  nonisolated func audioRecorderEncodeErrorDidOccur(_: AVAudioRecorder, error: Error?) {
    Task { @MainActor in
      self.stop()
      self.error = "Recording failed: \(error?.localizedDescription ?? "unknown audio error"). Please redo this take."
      self.redo()
      self.error = "Recording failed. Please redo this take."
    }
  }
}

/// Mouse-up ends recording even when the pointer has moved outside the button.
final class HoldControl: NSButton {
  var begin: (() -> Void)?
  var end: (() -> Void)?

  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    begin?()
    super.mouseDown(with: event)
    end?()
  }
}

struct HoldButton: NSViewRepresentable {
  @ObservedObject var recorder: Recorder

  func makeNSView(context _: Context) -> HoldControl {
    let button = HoldControl(title: "Hold to record", target: nil, action: nil)
    button.bezelStyle = .rounded
    button.controlSize = .large
    button.font = .systemFont(ofSize: 18, weight: .semibold)
    button.begin = { recorder.start() }
    button.end = { recorder.stop() }
    button.setAccessibilityLabel("Hold to record. Release to stop.")
    return button
  }

  func updateNSView(_ button: HoldControl, context _: Context) {
    button.title = recorder.recording ? "Recording… release to stop" : "Hold to record"
    button.isEnabled = recorder.allowed && recorder.pending == nil && !recorder.session.complete
  }
}

struct RecorderView: View {
  @ObservedObject var recorder: Recorder

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text("Local speech test").font(.title2.bold())
        Spacer()
        Text("\(recorder.saved) / 18 saved").foregroundStyle(.secondary).monospacedDigit()
      }
      ProgressView(value: Double(recorder.saved), total: 18)
      if recorder.session.complete {
        Text("All 18 takes saved.").font(.title.bold())
        Text(
          "The local engine comparison will start automatically. You can close this window. Recordings and results stay on this Mac."
        )
        Button("Show recordings") { NSWorkspace.shared.open(recorder.session.root) }
      } else {
        Text("Phrase \(recorder.saved / 3 + 1) of 6 · Take \(recorder.saved % 3 + 1) of 3")
          .font(.headline).foregroundStyle(.secondary)
        Text(recorder.session.phrase.expected)
          .font(.system(size: recorder.session.phrase.id == "long" ? 22 : 27, weight: .medium))
          .lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 175, alignment: .leading)
        Text(
          "Read naturally, as you would dictate. No need to say punctuation, capitals, or underscores. Pause briefly after pressing and before releasing."
        )
        .foregroundStyle(.secondary)
        if !recorder.allowed {
          Button("Enable microphone") { recorder.requestPermission() }.controlSize(.large)
        } else if recorder.pending != nil {
          HStack {
            Button("Play take") { recorder.play() }
            Button("Redo") { recorder.redo() }
            Spacer()
            Button(recorder.saved == 17 ? "Keep and run tests" : "Keep and next") { recorder.keep() }
              .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
          }.controlSize(.large)
          Text(String(
            format: "%.1f seconds recorded. Keep it if you read the whole phrase; otherwise redo.",
            recorder.elapsed
          ))
          .foregroundStyle(.secondary)
        } else {
          HoldButton(recorder: recorder).frame(height: 48)
          HStack {
            ProgressView(value: recorder.level).frame(width: 180)
            Text(recorder
              .recording ? String(format: "Recording · %.1f s", recorder.elapsed) :
              "Default microphone · audio saved locally")
              .monospacedDigit().foregroundStyle(.secondary)
          }
        }
      }
      if !recorder.error.isEmpty {
        Text(recorder.error).foregroundStyle(.red).textSelection(.enabled)
      }
      Spacer(minLength: 0)
      Text("Checks technical words, exact identifiers, and unwanted dictionary corrections.")
        .font(.caption).foregroundStyle(.secondary)
    }.padding(30).frame(width: 740, height: 600)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow?
  func applicationDidFinishLaunching(_: Notification) {
    do {
      let resource = Bundle.main.resourceURL!
      let corpus = try JSONDecoder().decode(
        Corpus.self,
        from: Data(contentsOf: resource.appendingPathComponent("fixtures.json"))
      )
      let directory = try String(contentsOf: resource.appendingPathComponent("output-directory.txt"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let session = try RecordingSession(root: URL(fileURLWithPath: directory), corpus: corpus)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 740, height: 600),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
      )
      window.title = "STT Phrase Recorder"
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: RecorderView(recorder: Recorder(session: session)))
      window.center()
      window.makeKeyAndOrderFront(nil)
      self.window = window
      NSApp.activate(ignoringOtherApps: true)
    } catch {
      let alert = NSAlert()
      alert.messageText = "Could not open the recording session"
      alert.informativeText = error.localizedDescription
      alert.runModal()
      NSApp.terminate(nil)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
    true
  }
}

@main
enum Main {
  @MainActor static func main() throws {
    if CommandLine.arguments.contains("--self-test") {
      try selfTest()
      return
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }

  static func selfTest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let phrase = Phrase(
      id: "test",
      spoken: "Read URL session",
      expected: "Read URLSession",
      terms: ["URLSession"],
      aliases: [:]
    )
    let corpus = Corpus(distractors: ["Rust"], cases: [phrase])
    let session = try RecordingSession(root: root, corpus: corpus)
    let pending = root.appendingPathComponent("test.wav")
    do {
      let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
      let file = try AVAudioFile(
        forWriting: pending,
        settings: format.settings,
        commonFormat: .pcmFormatInt16,
        interleaved: true
      )
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
      buffer.frameLength = 16_000
      memset(buffer.int16ChannelData![0], 0, 32_000)
      try file.write(from: buffer)
    }
    for _ in 0 ..< 3 {
      try session.accept(pending)
    }
    precondition(session.complete && session.manifest.recordings.count == 3)
    precondition(Set(session.manifest.recordings.map(\.file)).count == 3)
    let resumed = try RecordingSession(root: root, corpus: corpus)
    precondition(resumed.complete && resumed.manifest.recordings[2].voice == "Jim-take-3")
    precondition(resumed.manifest.recordings.allSatisfy { $0.seconds == 1 && $0.expected == phrase.expected })
    precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path))
    do {
      try resumed.accept(pending)
      preconditionFailure("Accepted a fourth take")
    } catch {}
    try Data("corrupt".utf8).write(to: URL(fileURLWithPath: resumed.manifest.recordings[0].file))
    do {
      _ = try RecordingSession(root: root, corpus: corpus)
      preconditionFailure("Accepted a corrupt recording on resume")
    } catch {}
    print(
      "PASS: three takes, PCM export, manifest round-trip, resume, completion, extra-take rejection, hash validation"
    )
  }
}
