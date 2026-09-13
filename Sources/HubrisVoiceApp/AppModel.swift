import AppKit
import Combine
import Foundation
import HubrisVoiceCore
import Network
import SwiftUI

// The effect interpreter and its platform integrations are intentionally kept together.
// swiftlint:disable file_length type_body_length

@MainActor
final class AppModel: ObservableObject {
  enum ConfigurationState: Equatable {
    case applied
    case pending
    case failed(String)
  }

  @Published private(set) var phaseTitle: String
  @Published private(set) var history: TranscriptHistory
  @Published var apiKeyDraft: String
  @Published var languages: [String] {
    didSet {
      guard languages != oldValue else { return }
      updateSettings { $0.languages = languages }
    }
  }

  @Published var prompt: String {
    didSet {
      guard prompt != oldValue else { return }
      updateSettings { $0.prompt = prompt }
    }
  }

  @Published var overlayPlacement: OverlayPlacementPreference {
    didSet {
      guard overlayPlacement != oldValue else { return }
      updateSettings { $0.overlayPlacement = overlayPlacement }
      if session.presentation != nil {
        overlayController?.show(
          anchor: currentAnchor,
          preference: overlayPlacement
        )
      }
    }
  }

  @Published var smartLeadingSpace: Bool {
    didSet {
      guard smartLeadingSpace != oldValue else { return }
      updateSettings { $0.smartLeadingSpace = smartLeadingSpace }
    }
  }

  @Published var trailingSpace: Bool {
    didSet {
      guard trailingSpace != oldValue else { return }
      updateSettings { $0.trailingSpace = trailingSpace }
    }
  }

  @Published var adjustCaseAfterComma: Bool {
    didSet {
      guard adjustCaseAfterComma != oldValue else { return }
      updateSettings { $0.adjustCaseAfterComma = adjustCaseAfterComma }
    }
  }

  @Published private(set) var dictionaryWords: [String] {
    didSet {
      guard dictionaryWords != oldValue else { return }
      updateSettings { $0.dictionary = dictionaryWords }
    }
  }

  @Published var newDictionaryWord = ""
  @Published private(set) var settingsMessage: String?
  @Published private(set) var configurationState = ConfigurationState.applied
  @Published private(set) var microphonePermission: MicrophonePermission
  @Published private(set) var accessibilityTrusted: Bool
  @Published private(set) var inputMonitoring: Bool
  @Published private(set) var inputDevices: [(uid: String, name: String)]
  @Published var inputDeviceUID: String? {
    didSet {
      guard inputDeviceUID != oldValue else { return }
      updateSettings { $0.inputDeviceUID = inputDeviceUID }
      audioCapture.preferredDeviceUID = inputDeviceUID
    }
  }

  @Published var launchAtLogin: Bool {
    didSet {
      guard launchAtLogin != oldValue, !isRefreshingLoginItemStatus else { return }
      updateSettings { $0.launchAtLogin = launchAtLogin }
      updateLoginItem(enabled: launchAtLogin)
    }
  }

  @Published var shortcuts: ShortcutSet {
    didSet {
      guard shortcuts != oldValue else { return }
      updateSettings { $0.shortcuts = shortcuts }
      applyShortcutSet(shortcuts)
    }
  }

  @Published var tapToLock: Bool {
    didSet {
      guard tapToLock != oldValue else { return }
      updateSettings { $0.tapToLock = tapToLock }
      session.setTapToLock(tapToLock)
    }
  }

  @Published var dictationEnabled: Bool {
    didSet {
      guard dictationEnabled != oldValue else { return }
      updateSettings { $0.dictationEnabled = dictationEnabled }
      if !dictationEnabled, session.listening != nil {
        apply(.cancelRequested)
      }
    }
  }

  @Published var historyPersistenceEnabled: Bool {
    didSet {
      guard historyPersistenceEnabled != oldValue else { return }
      updateSettings { $0.history.persist = historyPersistenceEnabled }
      if historyPersistenceEnabled {
        scheduleHistoryPersistence()
      } else {
        historyPersistenceScheduler.cancel()
        deletePersistedHistory()
      }
    }
  }

  @Published var startStopSoundsEnabled: Bool {
    didSet {
      guard startStopSoundsEnabled != oldValue else { return }
      updateSettings { $0.sounds.startStop = startStopSoundsEnabled }
    }
  }

  @Published var pastedSoundEnabled: Bool {
    didSet {
      guard pastedSoundEnabled != oldValue else { return }
      updateSettings { $0.sounds.pasted = pastedSoundEnabled }
    }
  }

  @Published var rejectedSoundEnabled: Bool {
    didSet {
      guard rejectedSoundEnabled != oldValue else { return }
      updateSettings { $0.sounds.rejected = rejectedSoundEnabled }
    }
  }

  @Published private(set) var requiresApproval: Bool
  @Published private(set) var lastConfirmedAt: Date?
  @Published private(set) var shortcutConflict: String?
  @Published private(set) var lastAttentionAt: Date?

  let overlayModel = OverlayViewModel()
  weak var overlayController: OverlayController?

  var lastTranscript: String? {
    history.latest?.text
  }

  var connectionSummary: String {
    switch session.connection {
    case .unconfigured:
      "Add an API key"
    case .connecting, .disconnected:
      "Reconnecting…"
    case .ready:
      "Connected · \(dictionaryTermSummary) · \(languageSummary)"
    }
  }

  var menuSystemImage: String {
    if !dictationEnabled {
      return "waveform.slash"
    }
    if lastAttentionAt != nil {
      return "exclamationmark.circle"
    }
    if lastConfirmedAt != nil {
      return "checkmark.circle"
    }
    return switch session.presentation?.mode {
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
  private let shortcutMonitor = ShortcutMonitor()
  private let insertionService = TextInsertionService()
  private let soundCues = SoundCues()
  private let keychain = KeychainStore()
  private let loginItemService = LoginItemService()
  private let defaults: UserDefaults
  private let reconnectScheduler = DelayedActionScheduler()
  private let dismissScheduler = DelayedActionScheduler()
  private let configurationScheduler = DelayedActionScheduler()
  private let historyPersistenceScheduler = DelayedActionScheduler()
  private let historyStore: TranscriptHistoryStore
  private let networkMonitor = NWPathMonitor()
  private let networkQueue = DispatchQueue(label: "com.jimeh.HubrisVoice.network")

  private var session: DictationSession
  private(set) var settings: DictationSettings
  private var buffers: [Int: AudioSnippetBuffer] = [:]
  private var focus: [Int: CapturedFocus] = [:]
  private var currentAnchor: OverlayAnchor?
  private var streamingGeneration: Int?
  private var finalizingTimers: [Int: Task<Void, Never>] = [:]
  private var eventTask: Task<Void, Never>?
  private var elapsedTask: Task<Void, Never>?
  private var stopCaptureTask: Task<Void, Never>?
  private var permissionPollingTask: Task<Void, Never>?
  private var transportTask: Task<Void, Never>?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var recordingStartedAt: Date?
  private var releasedAt: [Int: Date] = [:]
  private var isStarted = false
  private var isShortcutRunning = false
  private var savedAPIKey: String
  private var configurationUpdateDeferred = false
  private var configurationUpdateScheduled = false
  private var pendingConfigurationAcks = 0
  private var isRefreshingLoginItemStatus = false
  private var didWarnForFnBinding = false
  private var pasteLastInsertionGenerations: Set<Int> = []
  private var historyEntryIDs: [Int: UUID] = [:]
  private var presentedHistoryEntryID: UUID?

  // swiftlint:disable:next function_body_length
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let historyStore = TranscriptHistoryStore()
    self.historyStore = historyStore
    let storedAPIKey = (try? keychain.readAPIKey()) ?? ""
    let loginItemStatus = LoginItemService().status
    var settings = DictationSettings.load(from: defaults)
    if loginItemStatus == .enabled {
      settings.launchAtLogin = true
    }
    self.settings = settings
    history = settings.history.persist
      ? (try? historyStore.load()) ?? TranscriptHistory()
      : TranscriptHistory()
    savedAPIKey = storedAPIKey
    apiKeyDraft = storedAPIKey
    languages = settings.languages
    prompt = settings.prompt
    overlayPlacement = settings.overlayPlacement
    smartLeadingSpace = settings.smartLeadingSpace
    trailingSpace = settings.trailingSpace
    adjustCaseAfterComma = settings.adjustCaseAfterComma
    dictionaryWords = settings.dictionary
    microphonePermission = PermissionService.microphone
    accessibilityTrusted = PermissionService.accessibilityTrusted
    inputMonitoring = PermissionService.inputMonitoring
    inputDevices = AudioCapture.availableInputDevices()
    inputDeviceUID = settings.inputDeviceUID
    launchAtLogin = loginItemStatus == .enabled
    shortcuts = settings.shortcuts
    tapToLock = settings.tapToLock
    dictationEnabled = true
    historyPersistenceEnabled = settings.history.persist
    startStopSoundsEnabled = settings.sounds.startStop
    pastedSoundEnabled = settings.sounds.pasted
    rejectedSoundEnabled = settings.sounds.rejected
    requiresApproval = loginItemStatus == .requiresApproval
    lastConfirmedAt = nil
    shortcutConflict = Self.conflictMessage(for: settings.shortcuts)
    lastAttentionAt = nil
    session = DictationSession(
      configuration: .init(tapToLock: settings.tapToLock),
      hasKey: !storedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    )
    phaseTitle = session.phaseTitle
    settings.save(to: defaults)
    audioCapture.preferredDeviceUID = settings.inputDeviceUID

    audioCapture.onChunk = { [weak self] data in
      Task { @MainActor [weak self] in self?.handleAudioChunk(data) }
    }
    audioCapture.onLevel = { [weak self] level in
      Task { @MainActor [weak self] in self?.overlayModel.record(level: level) }
    }
    audioCapture.onError = { [weak self] message in
      Task { @MainActor [weak self] in
        self?.apply(.localError(message: message))
      }
    }
    audioCapture.onDevicesChanged = { [weak self] in
      Task { @MainActor [weak self] in self?.refreshInputDevices() }
    }
    shortcutMonitor.onAction = { [weak self] role, action in
      Task { @MainActor [weak self] in self?.handleShortcut(role: role, action: action) }
    }
    shortcutMonitor.onEscape = { [weak self] in
      Task { @MainActor [weak self] in self?.apply(.cancelRequested) }
    }
    shortcutMonitor.onReturn = { [weak self] in
      Task { @MainActor [weak self] in self?.handleReturn() }
    }
    shortcutMonitor.onTapDisabled = { [weak self] in
      Task { @MainActor [weak self] in self?.cancelLockedRecording() }
    }
    applyShortcutSet(settings.shortcuts)
  }

  func start() {
    guard !isStarted else { return }
    isStarted = true
    refreshPermissions()
    refreshInputDevices()
    refreshLoginItemStatus()
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

  func saveAPIKey() {
    settingsMessage = nil
    do {
      let apiKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
      if apiKey.isEmpty {
        try keychain.deleteAPIKey()
      } else {
        try keychain.writeAPIKey(apiKey)
      }
      let previousAPIKey = savedAPIKey
      let apiKeyChanged = apiKey != previousAPIKey
      savedAPIKey = apiKey
      settingsMessage = apiKey.isEmpty
        ? "Add an OpenAI API key to connect."
        : apiKeyChanged ? "Saved. Reconnecting…" : "Saved."
      guard apiKeyChanged else { return }
      apply(.credentialsChanged(hasKey: !apiKey.isEmpty))
      if !previousAPIKey.isEmpty, !apiKey.isEmpty {
        apply(.connectRequested(force: true))
      }
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

  func requestInputMonitoringPermission() {
    PermissionService.requestInputMonitoring()
    refreshPermissions()
    startShortcutIfPermitted()
  }

  func openSystemSettings(
    for permission: PermissionService.SystemPermission
  ) {
    PermissionService.openSystemSettings(for: permission)
  }

  func refreshPermissions() {
    microphonePermission = PermissionService.microphone
    accessibilityTrusted = PermissionService.accessibilityTrusted
    inputMonitoring = PermissionService.inputMonitoring
    // The active event tap needs Accessibility. Input Monitoring is shown in
    // Settings but must not gate the shortcut: its preflight can report false
    // on setups where the tap already works.
    if accessibilityTrusted, isStarted {
      startShortcutIfPermitted()
    } else if isShortcutRunning {
      shortcutMonitor.stop()
      isShortcutRunning = false
    }
  }

  func startPermissionPolling() {
    guard permissionPollingTask == nil else { return }
    refreshPermissions()
    refreshInputDevices()
    refreshLoginItemStatus()
    permissionPollingTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(2))
        } catch {
          return
        }
        guard let self else { return }
        refreshPermissions()
        refreshLoginItemStatus()
      }
    }
  }

  func stopPermissionPolling() {
    permissionPollingTask?.cancel()
    permissionPollingTask = nil
  }

  func refreshInputDevices() {
    inputDevices = AudioCapture.availableInputDevices()
  }

  func refreshLoginItemStatus() {
    let status = loginItemService.status
    isRefreshingLoginItemStatus = true
    launchAtLogin = status == .enabled
    requiresApproval = status == .requiresApproval
    isRefreshingLoginItemStatus = false
  }

  func reconnect() {
    apply(.connectRequested(force: true))
  }

  func openDiagnosticLog() {
    let url = URL(fileURLWithPath: (DiagnosticLog.displayPath as NSString).expandingTildeInPath)
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func toggleDictation() {
    dictationEnabled.toggle()
  }

  func copyTranscript(_ entry: TranscriptEntry) {
    insertionService.copy(entry.text)
    updateHistory(id: entry.id, outcome: .copied)
  }

  func removeHistoryEntry(id entryID: UUID) {
    history.remove(id: entryID)
    historyEntryIDs = historyEntryIDs.filter { $0.value != entryID }
    if presentedHistoryEntryID == entryID {
      presentedHistoryEntryID = nil
    }
    historyDidChange()
  }

  func clearHistory() {
    history.clear()
    historyEntryIDs.removeAll()
    presentedHistoryEntryID = nil
    historyDidChange()
  }

  func copyResult() {
    guard let presentation = session.presentation, presentation.canCopy else { return }
    insertionService.copy(presentation.transcript)
    apply(.copied)
  }

  func dismissOverlay() {
    apply(.dismissRequested)
  }

  func pasteHere() {
    apply(.pasteHereRequested)
  }

  func setShortcut(_ binding: ShortcutBinding?, for role: ShortcutRole) {
    var updated = shortcuts
    switch role {
    case .pushToTalk:
      guard let binding else { return }
      updated.pushToTalk = binding
    case .pasteLastTranscript:
      updated.pasteLastTranscript = binding
    }
    shortcuts = updated
  }

  private func updateSettings(
    _ update: (inout DictationSettings) -> Void
  ) {
    let oldSettings = settings
    update(&settings)
    settings.save(to: defaults)
    switch ConfigurationUpdatePolicy().decision(
      from: oldSettings,
      to: settings,
      apiKeyChanged: false
    ) {
    case .reconnect:
      apply(.connectRequested(force: true))
    case .sessionUpdate:
      scheduleConfigurationUpdate()
    case .nothing:
      break
    }
  }

  private func scheduleConfigurationUpdate() {
    configurationState = .pending
    configurationUpdateDeferred = false
    configurationUpdateScheduled = true
    configurationScheduler.schedule(after: .milliseconds(500)) { [weak self] in
      self?.sendConfigurationUpdateWhenIdle()
    }
  }

  private func sendConfigurationUpdateWhenIdle() {
    configurationUpdateScheduled = false
    guard session.listening == nil, session.pending.isEmpty else {
      configurationUpdateDeferred = true
      return
    }
    configurationUpdateDeferred = false
    configurationState = .pending
    pendingConfigurationAcks += 1
    let configuration = settings.sessionConfiguration
    Task { [weak self] in
      guard let self else { return }
      let sent = await client.updateSession(configuration)
      if !sent {
        pendingConfigurationAcks = max(
          0,
          pendingConfigurationAcks - 1
        )
      }
    }
  }

  private func resumeDeferredConfigurationUpdateIfIdle() {
    guard
      configurationUpdateDeferred,
      session.listening == nil,
      session.pending.isEmpty
    else {
      return
    }
    sendConfigurationUpdateWhenIdle()
  }

  // swiftlint:disable:next cyclomatic_complexity
  private func prepareHistory(
    for event: DictationSession.Event
  ) -> UUID? {
    switch event {
    case .insertionFinished(let generation, let outcome, _):
      guard
        session.inserting.contains(where: { $0.generation == generation }),
        let entryID = historyEntryIDs.removeValue(forKey: generation)
      else {
        return nil
      }
      updateHistory(id: entryID, outcome: outcome.historyOutcome)
      presentedHistoryEntryID = outcome == .confirmed ? nil : entryID
    case .finalizingTimedOut(let generation):
      guard
        let snippet = session.pending.first(where: { $0.generation == generation }),
        !snippet.transcript.isEmpty
      else {
        return nil
      }
      let entryID = recordTranscript(
        generation: generation,
        text: snippet.transcript,
        outcome: .timedOut
      )
      presentedHistoryEntryID = entryID
    case .copied:
      if let presentedHistoryEntryID {
        updateHistory(id: presentedHistoryEntryID, outcome: .copied)
      }
    case .cancelRequested:
      if let listening = session.listening {
        recordCancelledTranscript(listening)
      } else if session.presented != nil {
        presentedHistoryEntryID = nil
      } else {
        for snippet in session.pending where !snippet.transcript.isEmpty {
          recordCancelledTranscript(snippet)
        }
      }
    case .localError:
      if let listening = session.listening {
        presentedHistoryEntryID = recordCancelledTranscript(listening)
      }
    case .server(.error):
      if let listening = session.listening {
        presentedHistoryEntryID = recordCancelledTranscript(listening)
      }
    case .dismissRequested, .dismissDelayElapsed:
      presentedHistoryEntryID = nil
    case .pasteHereRequested:
      return presentedHistoryEntryID
    case .pasteLastRequested(let text):
      return history.latest?.text == text ? history.latest?.id : nil
    default:
      break
    }
    return nil
  }

  @discardableResult
  private func recordTranscript(
    generation: Int,
    text: String,
    outcome: TranscriptEntry.Outcome
  ) -> UUID? {
    guard !text.isEmpty else { return nil }
    if let entryID = historyEntryIDs[generation] {
      updateHistory(id: entryID, outcome: outcome)
      return entryID
    }
    let entry = TranscriptEntry(
      text: text,
      targetBundleID: focus[generation]?.targetBundleID,
      outcome: outcome
    )
    history.record(entry)
    historyEntryIDs[generation] = entry.id
    historyDidChange()
    return entry.id
  }

  @discardableResult
  private func recordCancelledTranscript(
    _ snippet: DictationSession.Snippet
  ) -> UUID? {
    guard !snippet.transcript.isEmpty else { return nil }
    return recordTranscript(
      generation: snippet.generation,
      text: snippet.transcript,
      outcome: .cancelled
    )
  }

  private func updateHistory(
    id entryID: UUID,
    outcome: TranscriptEntry.Outcome
  ) {
    history.update(id: entryID, outcome: outcome)
    historyDidChange()
  }

  private func historyDidChange() {
    guard historyPersistenceEnabled else { return }
    let snapshot = history
    historyPersistenceScheduler.schedule(after: .seconds(1)) { [historyStore] in
      do {
        try historyStore.save(snapshot)
      } catch {
        Task {
          await DiagnosticLog.shared.record(
            "history persistence failed \(RealtimeDiagnosticFormatter.errorSummary(error))",
            level: .error
          )
        }
      }
    }
  }

  private func scheduleHistoryPersistence() {
    historyDidChange()
  }

  private func deletePersistedHistory() {
    do {
      try historyStore.delete()
    } catch {
      Task {
        await DiagnosticLog.shared.record(
          "history deletion failed \(RealtimeDiagnosticFormatter.errorSummary(error))",
          level: .error
        )
      }
    }
  }

  private func apply(_ event: DictationSession.Event) {
    let insertionGeneration = session.nextGeneration
    let historyEntryForNewInsertion = prepareHistory(for: event)
    let rejectedPasteLastText: String? =
      if case .insertionFinished(let generation, .rejected, _) = event,
      pasteLastInsertionGenerations.contains(generation) {
        session.inserting.first { $0.generation == generation }?.transcript
      } else {
        nil
      }
    let insertionTelemetry: InsertionTelemetry? =
      if case .insertionFinished(let generation, let outcome, _) = event,
      session.inserting.contains(where: { $0.generation == generation }) {
        InsertionTelemetry(
          outcome: outcome,
          releasedAt: releasedAt[generation]
        )
      } else {
        nil
      }
    if case .released = event, let generation = session.listening?.generation {
      releasedAt[generation] = Date()
    }
    if case .bufferFull(let generation) = event,
       session.listening?.generation == generation
    {
      releasedAt[generation] = Date()
    }
    let effects = session.transition(event)
    if
      let historyEntryForNewInsertion,
      session.inserting.contains(where: { $0.generation == insertionGeneration })
    {
      historyEntryIDs[insertionGeneration] = historyEntryForNewInsertion
      presentedHistoryEntryID = nil
    }
    for effect in effects {
      interpret(effect)
    }
    if let rejectedPasteLastText {
      insertionService.copy(rejectedPasteLastText)
    }
    if case .insertionFinished(let generation, _, _) = event {
      pasteLastInsertionGenerations.remove(generation)
    }
    if let insertionTelemetry {
      if insertionTelemetry.outcome == .confirmed {
        flashConfirmed()
      }
      playInsertionSound(for: insertionTelemetry.outcome)
      if let releasedAt = insertionTelemetry.releasedAt {
        let latency = max(0, Int(Date().timeIntervalSince(releasedAt) * 1_000))
        Task {
          await DiagnosticLog.shared.record(
            "insert latency=\(latency) outcome=\(insertionTelemetry.outcome.diagnosticName)"
          )
        }
      }
    }
    publishSessionState()
    resumeDeferredConfigurationUpdateIfIdle()
  }

  // This switch is a direct, exhaustive interpreter for the core effect enum.
  // swiftlint:disable:next cyclomatic_complexity
  private func interpret(_ effect: DictationSession.Effect) {
    switch effect {
    case .startCapture(let generation):
      if startStopSoundsEnabled {
        soundCues.playStart()
      }
      startCapture(generation: generation)
    case .stopCapture:
      if startStopSoundsEnabled {
        soundCues.playStop()
      }
      stopCaptureAfterGrace()
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
    case .recordTranscript(let generation, let text):
      recordTranscript(generation: generation, text: text, outcome: .attempted)
    case .insert(let generation, let text): insert(generation: generation, text: text)
    case .insertAtCurrentFocus(let generation, let text):
      releasedAt[generation] = Date()
      insertAtCurrentFocus(generation: generation, text: text)
    case .scheduleDismiss(let delay):
      dismissScheduler.schedule(after: delay) { [weak self] in self?.apply(.dismissDelayElapsed) }
    case .cancelDismiss: dismissScheduler.cancel()
    case .discardSnippet(let generation): discardSnippet(generation: generation)
    }
  }

  private func publishSessionState() {
    phaseTitle = session.phaseTitle
    shortcutMonitor.capturesEscape = session.presentation != nil
    shortcutMonitor.capturesReturn = session.presentation?.mode == .attention
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
    if session.isLocked {
      apply(.pressed)
      return
    }
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

  /// Set while the Settings window is capturing a new binding so that the
  /// keys being recorded do not also trigger dictation.
  var isRecordingShortcut = false

  private func handleShortcut(
    role: ShortcutRole,
    action: ShortcutGesture.Action
  ) {
    guard !isRecordingShortcut, dictationEnabled else { return }
    switch (role, action) {
    case (.pushToTalk, .pressed):
      handlePress()
    case (.pushToTalk, .released):
      handleRelease()
    case (.pushToTalk, .cancelled):
      apply(.cancelRequested)
    case (.pasteLastTranscript, .pressed):
      pasteLastTranscriptAtCurrentFocus()
    case (_, .ignored), (_, .consumed), (.pasteLastTranscript, .released),
         (.pasteLastTranscript, .cancelled):
      break
    }
  }

  private func pasteLastTranscriptAtCurrentFocus() {
    guard let lastTranscript else {
      flashAttention()
      return
    }
    let generation = session.nextGeneration
    apply(.pasteLastRequested(text: lastTranscript))
    if session.inserting.contains(where: { $0.generation == generation }) {
      pasteLastInsertionGenerations.insert(generation)
    }
  }

  private func handleRelease() {
    guard let recordingStartedAt else { return }
    let duration = Date().timeIntervalSince(recordingStartedAt)
    self.recordingStartedAt = nil
    apply(.released(heldDuration: duration))
  }

  private func flashConfirmed() {
    let confirmedAt = Date()
    lastConfirmedAt = confirmedAt
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(1_200))
      guard let self, lastConfirmedAt == confirmedAt else { return }
      lastConfirmedAt = nil
    }
  }

  private func cancelLockedRecording() {
    guard session.isLocked else { return }
    apply(.cancelRequested)
  }

  private func flashAttention() {
    let attentionAt = Date()
    lastAttentionAt = attentionAt
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(1_200))
      guard let self, lastAttentionAt == attentionAt else { return }
      lastAttentionAt = nil
    }
  }

  private func handleReturn() {
    if session.presentation?.canPasteHere == true {
      apply(.pasteHereRequested)
    } else {
      copyResult()
    }
  }

  private func handle(_ event: RealtimeTransportEvent) {
    switch event {
    case .server(.sessionReady):
      pendingConfigurationAcks = max(
        0,
        pendingConfigurationAcks - 1
      )
      if
        pendingConfigurationAcks == 0,
        !configurationUpdateScheduled,
        !configurationUpdateDeferred
      {
        configurationState = .applied
      }
      settingsMessage = "Connected with \(dictionaryWords.count) dictionary term\(dictionaryWords.count == 1 ? "" : "s")."
      apply(.sessionReady)
    case .server(.error(let message)):
      if configurationState == .pending {
        pendingConfigurationAcks = 0
        configurationState = .failed(message)
      }
      apply(.server(.error(message: message)))
    case .server(let event):
      apply(.server(event))
    case .connectionLost(let message):
      pendingConfigurationAcks = 0
      apply(.connectionLost(message: message))
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
    releasedAt.removeValue(forKey: generation)
    historyEntryIDs.removeValue(forKey: generation)
    cancelFinalizingTimeout(generation: generation)
  }

  private func insert(generation: Int, text: String) {
    guard let target = focus[generation] else {
      apply(.insertionFinished(generation: generation, outcome: .rejected, reason: .noTarget))
      return
    }
    let formatted = InsertionFormatter.format(
      text,
      context: insertionService.currentTextContext(for: target),
      options: insertionOptions
    )
    Task { [weak self] in
      guard let self else { return }
      let result = await insertionService.paste(
        formatted,
        into: target,
        expected: formatted
      )
      apply(.insertionFinished(generation: generation, outcome: result.outcome, reason: result.reason))
    }
  }

  private func insertAtCurrentFocus(generation: Int, text: String) {
    guard let target = insertionService.captureFocusedTarget() else {
      apply(.insertionFinished(generation: generation, outcome: .rejected, reason: .noTarget))
      return
    }
    let formatted = InsertionFormatter.format(
      text,
      context: insertionService.currentTextContext(for: target),
      options: insertionOptions
    )
    Task { [weak self] in
      guard let self else { return }
      let result = await insertionService.pasteAtCurrentFocus(formatted)
      apply(.insertionFinished(generation: generation, outcome: result.outcome, reason: result.reason))
    }
  }

  private var insertionOptions: InsertionFormatter.Options {
    .init(
      smartLeadingSpace: smartLeadingSpace,
      trailingSpace: trailingSpace,
      adjustCaseAfterComma: adjustCaseAfterComma,
      protectedTerms: dictionaryWords
    )
  }

  private var dictionaryTermSummary: String {
    let count = dictionaryWords.count
    return "\(count) dictionary term\(count == 1 ? "" : "s")"
  }

  private var languageSummary: String {
    let names = languages.compactMap { code in
      RealtimeSessionConfiguration.supportedLanguages.first {
        $0.code == code
      }?.name
    }
    return names.isEmpty ? "Auto language" : names.joined(separator: ", ")
  }

  private func playInsertionSound(for outcome: PasteOutcome) {
    switch outcome {
    case .confirmed where pastedSoundEnabled:
      soundCues.playPasted()
    case .attempted where rejectedSoundEnabled,
         .rejected where rejectedSoundEnabled:
      soundCues.playRejected()
    default:
      break
    }
  }

  private func enqueueConnect() {
    let previous = transportTask
    transportTask = Task { [weak self] in
      _ = await previous?.value
      guard let self else { return }
      do {
        try await client.connect(
          apiKey: savedAPIKey,
          configuration: settings.sessionConfiguration
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
    let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.apply(.connectRequested(force: false)) }
    }
    let sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.shortcutMonitor.cancelAll()
        self?.cancelLockedRecording()
      }
    }
    workspaceObservers = [wakeObserver, sleepObserver]
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

  private func applyShortcutSet(_ shortcuts: ShortcutSet) {
    shortcutConflict = Self.conflictMessage(for: shortcuts)
    var applied = shortcuts
    if shortcutConflict != nil {
      applied.pasteLastTranscript = nil
    }
    shortcutMonitor.apply(applied)
    guard !didWarnForFnBinding, shortcuts.containsFnBinding else { return }
    didWarnForFnBinding = true
    Task {
      await DiagnosticLog.shared.record(
        "Fn shortcut configured; macOS or keyboard firmware may route Fn before the event tap"
      )
    }
  }

  private static func conflictMessage(for shortcuts: ShortcutSet) -> String? {
    shortcuts.conflicts().isEmpty
      ? nil
      : "Push to Talk and Paste Last Transcript use the same shortcut."
  }

  private func updateLoginItem(enabled: Bool) {
    settingsMessage = nil
    do {
      if enabled {
        try loginItemService.register()
      } else {
        try loginItemService.unregister()
      }
    } catch {
      settingsMessage = error.localizedDescription
    }
    refreshLoginItemStatus()
  }
}

private extension ShortcutSet {
  var containsFnBinding: Bool {
    if pushToTalk == .modifier(.fn) {
      return true
    }
    return pasteLastTranscript == .modifier(.fn)
  }
}

extension UserDefaults: SettingsStore {
  public func string(_ key: String) -> String? {
    string(forKey: key)
  }

  public func stringArray(_ key: String) -> [String]? {
    stringArray(forKey: key)
  }

  public func bool(_ key: String) -> Bool? {
    object(forKey: key) as? Bool
  }

  public func set(_ value: Any?, for key: String) {
    set(value, forKey: key)
  }
}

private extension PasteOutcome {
  var historyOutcome: TranscriptEntry.Outcome {
    switch self {
    case .confirmed: .pasted
    case .attempted: .attempted
    case .rejected: .rejected
    }
  }

  var diagnosticName: String {
    switch self {
    case .confirmed: "confirmed"
    case .attempted: "attempted"
    case .rejected: "rejected"
    }
  }
}

private struct InsertionTelemetry {
  let outcome: PasteOutcome
  let releasedAt: Date?
}

// swiftlint:enable file_length type_body_length
