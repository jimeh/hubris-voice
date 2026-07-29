import AppKit
import Combine
import Foundation
import HubrisVoiceCore
import SwiftUI

enum AppPhase: Equatable {
  case needsSetup
  case connecting
  case ready
  case listening
  case finalizing
  case result(didPaste: Bool)
  case error(String)

  var title: String {
    switch self {
    case .needsSetup:
      "Add an API key"
    case .connecting:
      "Connecting"
    case .ready:
      "Ready"
    case .listening:
      "Listening"
    case .finalizing:
      "Finalizing"
    case .result(let didPaste):
      didPaste ? "Pasted" : "Transcript ready"
    case .error:
      "Needs attention"
    }
  }

  var statusColor: Color {
    switch self {
    case .ready, .result(didPaste: true):
      .completionMint
    case .listening:
      .signalBlue
    case .connecting, .finalizing, .result(didPaste: false):
      .voiceCoral
    case .needsSetup, .error:
      .secondary
    }
  }
}

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var phase: AppPhase = .needsSetup
  @Published var apiKeyDraft: String
  @Published var language = "en"
  @Published var prompt: String
  @Published private(set) var dictionaryWords: [String]
  @Published var newDictionaryWord = ""
  @Published private(set) var settingsMessage: String?
  @Published private(set) var microphonePermission: MicrophonePermission
  @Published private(set) var accessibilityTrusted: Bool

  let overlayModel = OverlayViewModel()
  weak var overlayController: OverlayController?

  var menuSystemImage: String {
    switch phase {
    case .listening:
      "waveform.circle.fill"
    case .connecting, .finalizing:
      "ellipsis.circle"
    case .error:
      "exclamationmark.circle"
    default:
      "waveform.circle"
    }
  }

  var errorMessage: String? {
    if case .error(let message) = phase {
      return message
    }
    return nil
  }

  private let client = RealtimeTranscriptionClient()
  private let audioCapture = AudioCapture()
  private let shortcutMonitor = PushToTalkMonitor()
  private let insertionService = TextInsertionService()
  private let keychain = KeychainStore()
  private let defaults: UserDefaults
  private let snippetPolicy = SnippetPolicy()
  private let overlayDismissalScheduler = DelayedActionScheduler()

  private var eventTask: Task<Void, Never>?
  private var elapsedTask: Task<Void, Never>?
  private var isStarted = false
  private var isSessionReady = false
  private var isShortcutRunning = false
  private var recordingStartedAt: Date?
  private var capturedFocus: CapturedFocus?
  private var activeItemID: String?
  private var assembler = TranscriptAssembler()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    apiKeyDraft = (try? keychain.readAPIKey()) ?? ""
    language = defaults.string(forKey: DefaultsKey.language) ?? "en"
    prompt =
      defaults.string(forKey: DefaultsKey.prompt)
      ?? "Transcribe natural dictation. Preserve the spelling and capitalization of dictionary terms. Add punctuation suitable for prose."
    dictionaryWords =
      defaults.stringArray(
        forKey: DefaultsKey.dictionary
      ) ?? []
    microphonePermission = PermissionService.microphone
    accessibilityTrusted = PermissionService.accessibilityTrusted

    let outbound = client.outbound
    audioCapture.onChunk = { data in
      outbound.appendAudio(data)
    }
    audioCapture.onLevel = { [weak self] level in
      Task { @MainActor [weak self] in
        self?.overlayModel.record(level: level)
      }
    }
    audioCapture.onError = { [weak self] message in
      Task { @MainActor [weak self] in
        self?.showError(
          "Audio conversion failed: \(message)",
          inOverlay: true
        )
      }
    }
    shortcutMonitor.onPress = { [weak self] in
      Task { @MainActor [weak self] in
        self?.beginDictation()
      }
    }
    shortcutMonitor.onRelease = { [weak self] in
      Task { @MainActor [weak self] in
        await self?.finishDictation()
      }
    }
  }

  func start() {
    guard !isStarted else {
      return
    }
    isStarted = true
    refreshPermissions()
    startShortcutIfPermitted()
    let hasAPIKey =
      !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    Task {
      await DiagnosticLog.shared.record(
        "application started apiKeyPresent=\(hasAPIKey)"
      )
    }

    let events = client.events
    eventTask = Task { [weak self] in
      for await event in events {
        guard let self else {
          return
        }
        handle(event)
      }
    }

    Task { [weak self] in
      guard let self else {
        return
      }
      await client.start()
      if hasAPIKey {
        await connect()
      }
    }
  }

  func saveSettings() {
    settingsMessage = nil
    do {
      let normalized = try DictionaryVocabulary.normalize(dictionaryWords)
      dictionaryWords = normalized
      let apiKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
      if apiKey.isEmpty {
        try keychain.deleteAPIKey()
      } else {
        try keychain.writeAPIKey(apiKey)
      }

      defaults.set(language, forKey: DefaultsKey.language)
      defaults.set(prompt, forKey: DefaultsKey.prompt)
      defaults.set(dictionaryWords, forKey: DefaultsKey.dictionary)
      settingsMessage = "Saved. Reconnecting with the new vocabulary…"

      Task { [weak self] in
        await self?.connect()
      }
    } catch {
      settingsMessage = error.localizedDescription
      phase = .error(error.localizedDescription)
    }
  }

  func addDictionaryWord() {
    settingsMessage = nil
    do {
      let normalized = try DictionaryVocabulary.normalize(
        dictionaryWords + [newDictionaryWord]
      )
      dictionaryWords = normalized
      newDictionaryWord = ""
    } catch {
      settingsMessage = error.localizedDescription
    }
  }

  func removeDictionaryWord(_ word: String) {
    dictionaryWords.removeAll { $0 == word }
  }

  func requestMicrophonePermission() {
    Task { [weak self] in
      _ = await PermissionService.requestMicrophone()
      self?.refreshPermissions()
    }
  }

  func requestAccessibilityPermission() {
    PermissionService.requestAccessibility()
    refreshPermissions()
    startShortcutIfPermitted()
  }

  func refreshPermissions() {
    microphonePermission = PermissionService.microphone
    accessibilityTrusted = PermissionService.accessibilityTrusted
    if accessibilityTrusted, isStarted {
      startShortcutIfPermitted()
    } else if isShortcutRunning {
      shortcutMonitor.stop()
      isShortcutRunning = false
    }
  }

  func copyResult() {
    guard !overlayModel.transcript.isEmpty else {
      return
    }
    insertionService.copy(overlayModel.transcript)
    overlayModel.mode = .copied
    overlayModel.message = "Copied to the clipboard"
    overlayModel.canCopy = false
    scheduleOverlayDismissal()
  }

  func dismissOverlay() {
    overlayDismissalScheduler.cancel()
    overlayController?.hide()
    resetAfterSnippet()
  }

  private func connect() async {
    let apiKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !apiKey.isEmpty else {
      isSessionReady = false
      phase = .needsSetup
      settingsMessage = "Add an OpenAI API key to connect."
      await client.disconnect()
      return
    }

    do {
      let keywords = try DictionaryVocabulary.normalize(dictionaryWords)
      phase = .connecting
      isSessionReady = false
      try await client.connect(
        apiKey: apiKey,
        configuration: RealtimeSessionConfiguration(
          language: language,
          prompt: prompt,
          keywords: keywords,
          delay: .low
        )
      )
    } catch {
      phase = .error(error.localizedDescription)
      settingsMessage =
        error.localizedDescription
        + " Debug log: \(DiagnosticLog.displayPath)"
    }
  }

  private func startShortcutIfPermitted() {
    guard accessibilityTrusted, !isShortcutRunning else {
      return
    }
    do {
      try shortcutMonitor.start()
      isShortcutRunning = true
    } catch {
      phase = .error(error.localizedDescription)
      settingsMessage = error.localizedDescription
    }
  }

  private func beginDictation() {
    overlayDismissalScheduler.cancel()
    guard
      !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
    else {
      showError("Add an OpenAI API key before dictating.", inOverlay: true)
      return
    }
    guard isSessionReady || phase == .connecting else {
      showError("The transcription session is not ready yet.", inOverlay: true)
      return
    }
    guard microphonePermission == .authorized else {
      showError(
        "Allow Microphone access in Settings before dictating.",
        inOverlay: true
      )
      return
    }
    guard !audioCapture.isRunning else {
      return
    }

    capturedFocus = insertionService.captureFocusedTarget()
    activeItemID = nil
    assembler = TranscriptAssembler()
    recordingStartedAt = Date()
    overlayModel.beginListening()
    phase = .listening
    overlayController?.show()

    do {
      try audioCapture.start()
      startElapsedTimer()
    } catch {
      showError(error.localizedDescription, inOverlay: true)
    }
  }

  private func finishDictation() async {
    guard phase == .listening, let recordingStartedAt else {
      return
    }

    let heldDuration = Date().timeIntervalSince(recordingStartedAt)
    phase = .finalizing
    overlayModel.mode = .finalizing
    overlayModel.message = "Completing the transcript…"

    try? await Task.sleep(for: .milliseconds(100))
    audioCapture.stop()
    elapsedTask?.cancel()
    elapsedTask = nil

    self.recordingStartedAt = nil
    guard phase == .finalizing else {
      return
    }
    guard snippetPolicy.shouldCommit(duration: heldDuration) else {
      client.outbound.clearAudio()
      overlayController?.hide()
      resetAfterSnippet()
      return
    }

    client.outbound.commitAudio()
  }

  private func startElapsedTimer() {
    elapsedTask?.cancel()
    elapsedTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let startedAt = recordingStartedAt else {
          return
        }
        overlayModel.elapsed = Date().timeIntervalSince(startedAt)
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  private func handle(_ event: RealtimeServerEvent) {
    switch event {
    case .sessionReady:
      isSessionReady = true
      settingsMessage =
        "Connected with \(dictionaryWords.count) dictionary term\(dictionaryWords.count == 1 ? "" : "s")."
      if phase == .connecting || phase == .needsSetup {
        phase = .ready
      }
    case .inputCommitted(let itemID):
      activeItemID = itemID
    case .transcriptDelta(let itemID, _):
      if activeItemID == nil {
        activeItemID = itemID
      }
      assembler.apply(event)
      if activeItemID == itemID {
        overlayModel.transcript = assembler.preview(for: itemID) ?? ""
      }
    case .transcriptCompleted(let itemID, _):
      let completion = assembler.apply(event)
      guard activeItemID == itemID, let completion else {
        return
      }
      completeSnippet(completion.text)
    case .error(let message):
      isSessionReady = false
      showError(message, inOverlay: audioCapture.isRunning || phase == .finalizing)
    case .ignored:
      break
    }
  }

  private func completeSnippet(_ rawText: String) {
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      showError("No speech was detected.", inOverlay: true)
      return
    }

    overlayModel.transcript = text
    let didPaste =
      capturedFocus.map {
        insertionService.paste(text, into: $0)
      } ?? false
    phase = .result(didPaste: didPaste)

    if didPaste {
      overlayModel.mode = .completed
      overlayModel.message = "Inserted into the focused field"
      overlayModel.canCopy = false
      scheduleOverlayDismissal()
    } else {
      overlayModel.mode = .attention
      overlayModel.message =
        capturedFocus == nil
        ? "No editable field was captured · copy instead"
        : "Focus changed · copy instead"
      overlayModel.canCopy = true
    }
  }

  private func scheduleOverlayDismissal() {
    overlayDismissalScheduler.schedule(after: .milliseconds(850)) {
      [weak self] in
      self?.overlayController?.hide()
      self?.resetAfterSnippet()
    }
  }

  private func showError(_ message: String, inOverlay: Bool) {
    audioCapture.stop()
    elapsedTask?.cancel()
    phase = .error(message)
    settingsMessage = message
    if inOverlay {
      overlayModel.mode = .attention
      overlayModel.message = message
      overlayModel.canCopy = !overlayModel.transcript.isEmpty
      overlayController?.show()
    }
  }

  private func resetAfterSnippet() {
    capturedFocus = nil
    activeItemID = nil
    assembler = TranscriptAssembler()
    phase = isSessionReady ? .ready : .connecting
  }
}

private enum DefaultsKey {
  static let language = "transcription.language"
  static let prompt = "transcription.prompt"
  static let dictionary = "transcription.dictionary"
}
