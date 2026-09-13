import AppKit
import Combine
import Foundation
import HubrisVoiceCore
import Network
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var phaseTitle: String
  @Published var apiKeyDraft: String
  @Published var language = "en"
  @Published var prompt: String
  @Published var overlayPlacement: OverlayPlacementPreference {
    didSet {
      defaults.set(
        overlayPlacement.rawValue,
        forKey: DefaultsKey.overlayPlacement
      )
      if session.presentation != nil {
        overlayController?.show(
          anchor: currentAnchor,
          preference: overlayPlacement
        )
      }
    }
  }

  @Published private(set) var dictionaryWords: [String]
  @Published var newDictionaryWord = ""
  @Published private(set) var settingsMessage: String?
  @Published private(set) var microphonePermission: MicrophonePermission
  @Published private(set) var accessibilityTrusted: Bool

  let overlayModel = OverlayViewModel()
  weak var overlayController: OverlayController?

  var menuSystemImage: String {
    switch session.presentation?.mode {
    case .listening: "waveform.circle.fill"
    case .finalizing: "ellipsis.circle"
    case .attention: "exclamationmark.circle"
    case .completed, .copied: "waveform.circle"
    case nil:
      switch session.connection {
      case .connecting, .disconnected: "ellipsis.circle"
      case .ready, .unconfigured: "waveform.circle"
      }
    }
  }

  var statusColor: Color {
    switch session.presentation?.mode {
    case .listening: .signalBlue
    case .finalizing, .attention: .voiceCoral
    case .completed, .copied: .completionMint
    case nil:
      switch session.connection {
      case .ready: .completionMint
      case .connecting, .disconnected: .voiceCoral
      case .unconfigured: .secondary
      }
    }
  }

  var errorMessage: String? {
    guard case .error(let message, _) = session.presented else { return nil }
    return message
  }

  private let client = RealtimeTranscriptionClient()
  private let audioCapture = AudioCapture()
  private let shortcutMonitor = PushToTalkMonitor()
  private let insertionService = TextInsertionService()
  private let keychain = KeychainStore()
  private let defaults: UserDefaults
  private let reconnectScheduler = DelayedActionScheduler()
  private let dismissScheduler = DelayedActionScheduler()
  private let networkMonitor = NWPathMonitor()
  private let networkQueue = DispatchQueue(label: "com.jimeh.HubrisVoice.network")

  private var session: DictationSession
  private var buffers: [Int: AudioSnippetBuffer] = [:]
  private var focus: [Int: CapturedFocus] = [:]
  private var currentAnchor: OverlayAnchor?
  private var streamingGeneration: Int?
  private var finalizingTimers: [Int: Task<Void, Never>] = [:]
  private var eventTask: Task<Void, Never>?
  private var elapsedTask: Task<Void, Never>?
  private var stopCaptureTask: Task<Void, Never>?
  private var transportTask: Task<Void, Never>?
  private var wakeObserver: NSObjectProtocol?
  private var recordingStartedAt: Date?
  private var isStarted = false
  private var isShortcutRunning = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let storedAPIKey = (try? keychain.readAPIKey()) ?? ""
    apiKeyDraft = storedAPIKey
    language = defaults.string(forKey: DefaultsKey.language) ?? "en"
    prompt = defaults.string(forKey: DefaultsKey.prompt)
      ?? "Transcribe natural dictation. Preserve the spelling and capitalization of dictionary terms. Add punctuation suitable for prose."
    overlayPlacement = defaults.string(
      forKey: DefaultsKey.overlayPlacement
    ).flatMap(OverlayPlacementPreference.init(rawValue:)) ?? .automatic
    dictionaryWords = defaults.stringArray(forKey: DefaultsKey.dictionary) ?? []
    microphonePermission = PermissionService.microphone
    accessibilityTrusted = PermissionService.accessibilityTrusted
    session = DictationSession(
      hasKey: !storedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    )
    phaseTitle = session.phaseTitle

    audioCapture.onChunk = { [weak self] data in
      Task { @MainActor [weak self] in self?.handleAudioChunk(data) }
    }
    audioCapture.onLevel = { [weak self] level in
      Task { @MainActor [weak self] in self?.overlayModel.record(level: level) }
    }
    audioCapture.onError = { [weak self] message in
      Task { @MainActor [weak self] in
        self?.apply(.localError(message: "Audio conversion failed: \(message)"))
      }
    }
    shortcutMonitor.onPress = { [weak self] in
      Task { @MainActor [weak self] in self?.handlePress() }
    }
    shortcutMonitor.onRelease = { [weak self] in
      Task { @MainActor [weak self] in self?.handleRelease() }
    }
    shortcutMonitor.onCancel = { [weak self] in
      Task { @MainActor [weak self] in self?.apply(.cancelRequested) }
    }
    shortcutMonitor.onEscape = { [weak self] in
      Task { @MainActor [weak self] in self?.apply(.cancelRequested) }
    }
  }

  func start() {
    guard !isStarted else { return }
    isStarted = true
    refreshPermissions()
    startShortcutIfPermitted()
    observeReconnectSignals()

    eventTask = Task { [weak self, events = client.events] in
      for await event in events {
        guard let self else { return }
        handle(event)
      }
    }
    Task { [weak self] in
      guard let self else { return }
      await client.start()
      await MainActor.run { self.apply(.connectRequested(force: false)) }
    }
  }

  func saveSettings() {
    settingsMessage = nil
    do {
      dictionaryWords = try DictionaryVocabulary.normalize(dictionaryWords)
      let apiKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
      if apiKey.isEmpty {
        try keychain.deleteAPIKey()
      } else {
        try keychain.writeAPIKey(apiKey)
      }
      defaults.set(language, forKey: DefaultsKey.language)
      defaults.set(prompt, forKey: DefaultsKey.prompt)
      defaults.set(dictionaryWords, forKey: DefaultsKey.dictionary)
      settingsMessage = apiKey.isEmpty
        ? "Add an OpenAI API key to connect."
        : "Saved. Reconnecting with the new vocabulary…"
      apply(.credentialsChanged(hasKey: !apiKey.isEmpty))
      apply(.connectRequested(force: true))
    } catch {
      settingsMessage = error.localizedDescription
    }
  }

  func addDictionaryWord() {
    settingsMessage = nil
    do {
      dictionaryWords = try DictionaryVocabulary.normalize(dictionaryWords + [newDictionaryWord])
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
    guard let presentation = session.presentation, presentation.canCopy else { return }
    insertionService.copy(presentation.transcript)
    apply(.copied)
  }

  func dismissOverlay() {
    apply(.dismissRequested)
  }

  private func apply(_ event: DictationSession.Event) {
    let effects = session.transition(event)
    for effect in effects {
      interpret(effect)
    }
    publishSessionState()
  }

  // This switch is a direct, exhaustive interpreter for the core effect enum.
  // swiftlint:disable:next cyclomatic_complexity
  private func interpret(_ effect: DictationSession.Effect) {
    switch effect {
    case .startCapture(let generation): startCapture(generation: generation)
    case .stopCapture: stopCaptureAfterGrace()
    case .replayAudio(let generation): client.outbound.replay(buffers[generation]?.chunks ?? [])
    case .commitAudio: client.outbound.commitAudio()
    case .clearAudio(let generation):
      if generation == streamingGeneration {
        client.outbound.clearAudio()
      }
    case .connect: enqueueConnect()
    case .disconnect: enqueueDisconnect()
    case .scheduleReconnect(let delay, let attempt):
      reconnectScheduler.schedule(after: delay) { [weak self] in
        self?.apply(.reconnectDelayElapsed(attempt: attempt))
      }
    case .cancelReconnect: reconnectScheduler.cancel()
    case .scheduleFinalizingTimeout(let generation, let delay):
      scheduleFinalizingTimeout(generation: generation, delay: delay)
    case .cancelFinalizingTimeout(let generation): cancelFinalizingTimeout(generation: generation)
    case .insert(let generation, let text): insert(generation: generation, text: text)
    case .scheduleDismiss(let delay):
      dismissScheduler.schedule(after: delay) { [weak self] in self?.apply(.dismissDelayElapsed) }
    case .cancelDismiss: dismissScheduler.cancel()
    case .discardSnippet(let generation): discardSnippet(generation: generation)
    }
  }

  private func publishSessionState() {
    phaseTitle = session.phaseTitle
    shortcutMonitor.capturesEscape = session.presentation != nil
    if let presentation = session.presentation {
      overlayModel.apply(presentation)
      overlayController?.show(
        anchor: currentAnchor,
        preference: overlayPlacement
      )
    } else {
      overlayController?.hide()
      currentAnchor = nil
    }
  }

  private func handlePress() {
    let hasKey = !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard hasKey else {
      apply(.pressed)
      return
    }
    guard microphonePermission == .authorized else {
      apply(.localError(message: "Allow Microphone access in Settings before dictating."))
      return
    }
    apply(.pressed)
  }

  private func handleRelease() {
    guard let recordingStartedAt else { return }
    let duration = Date().timeIntervalSince(recordingStartedAt)
    self.recordingStartedAt = nil
    apply(.released(heldDuration: duration))
  }

  private func handle(_ event: RealtimeTransportEvent) {
    switch event {
    case .server(.sessionReady):
      settingsMessage = "Connected with \(dictionaryWords.count) dictionary term\(dictionaryWords.count == 1 ? "" : "s")."
      apply(.sessionReady)
    case .server(let event): apply(.server(event))
    case .connectionLost(let message): apply(.connectionLost(message: message))
    }
  }

  private func handleAudioChunk(_ data: Data) {
    guard let generation = streamingGeneration, var buffer = buffers[generation] else { return }
    let result = buffer.append(data)
    buffers[generation] = buffer
    if result == .full {
      apply(.bufferFull(generation: generation))
    } else if session.connection == .ready {
      client.outbound.appendAudio(data)
    }
  }

  private func startCapture(generation: Int) {
    stopCaptureTask?.cancel()
    stopCaptureTask = nil
    let capturedFocus = insertionService.captureFocusedTarget()
    focus[generation] = capturedFocus
    currentAnchor = insertionService.captureAnchor(for: capturedFocus)
    buffers[generation] = AudioSnippetBuffer()
    streamingGeneration = generation
    recordingStartedAt = Date()
    overlayModel.beginListening()
    do {
      try audioCapture.start()
      startElapsedTimer()
    } catch {
      apply(.localError(message: error.localizedDescription))
    }
  }

  private func stopCaptureAfterGrace() {
    recordingStartedAt = nil
    let stoppingGeneration = streamingGeneration
    stopCaptureTask?.cancel()
    stopCaptureTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(100))
      guard !Task.isCancelled, let self, streamingGeneration == stoppingGeneration else { return }
      audioCapture.stop()
      streamingGeneration = nil
      elapsedTask?.cancel()
      elapsedTask = nil
    }
  }

  private func startElapsedTimer() {
    elapsedTask?.cancel()
    elapsedTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let startedAt = recordingStartedAt else { return }
        overlayModel.elapsed = Date().timeIntervalSince(startedAt)
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  private func scheduleFinalizingTimeout(generation: Int, delay: Duration) {
    cancelFinalizingTimeout(generation: generation)
    finalizingTimers[generation] = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.apply(.finalizingTimedOut(generation: generation))
    }
  }

  private func cancelFinalizingTimeout(generation: Int) {
    finalizingTimers.removeValue(forKey: generation)?.cancel()
  }

  private func discardSnippet(generation: Int) {
    buffers.removeValue(forKey: generation)
    focus.removeValue(forKey: generation)
    cancelFinalizingTimeout(generation: generation)
  }

  private func insert(generation: Int, text: String) {
    guard let target = focus[generation] else {
      apply(.insertionFinished(generation: generation, outcome: .rejected, reason: .noTarget))
      return
    }
    Task { [weak self] in
      guard let self else { return }
      let result = await insertionService.paste(text, into: target)
      apply(.insertionFinished(generation: generation, outcome: result.outcome, reason: result.reason))
    }
  }

  private func enqueueConnect() {
    let previous = transportTask
    transportTask = Task { [weak self] in
      _ = await previous?.value
      guard let self else { return }
      do {
        let keywords = try DictionaryVocabulary.normalize(dictionaryWords)
        try await client.connect(
          apiKey: apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines),
          configuration: RealtimeSessionConfiguration(
            language: language,
            prompt: prompt,
            keywords: keywords,
            delay: .low
          )
        )
      } catch is CancellationError {
        return
      } catch {
        apply(.connectionFailed(message: error.localizedDescription))
        settingsMessage = error.localizedDescription + " Debug log: \(DiagnosticLog.displayPath)"
      }
    }
  }

  private func enqueueDisconnect() {
    transportTask?.cancel()
    transportTask = Task { [weak self] in
      await self?.client.disconnect()
    }
  }

  private func observeReconnectSignals() {
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.apply(.connectRequested(force: false)) }
    }
    networkMonitor.pathUpdateHandler = { [weak self] path in
      guard path.status == .satisfied else { return }
      Task { @MainActor [weak self] in self?.apply(.connectRequested(force: false)) }
    }
    networkMonitor.start(queue: networkQueue)
  }

  private func startShortcutIfPermitted() {
    guard accessibilityTrusted, !isShortcutRunning else { return }
    do {
      try shortcutMonitor.start()
      isShortcutRunning = true
    } catch {
      settingsMessage = error.localizedDescription
      apply(.localError(message: error.localizedDescription))
    }
  }
}

private enum DefaultsKey {
  static let language = "transcription.language"
  static let prompt = "transcription.prompt"
  static let dictionary = "transcription.dictionary"
  static let overlayPlacement = "overlay.placement"
}
