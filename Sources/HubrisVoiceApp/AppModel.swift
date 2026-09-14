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

  @Published var overlayLineCap: Int {
    didSet {
      guard overlayLineCap != oldValue else { return }
      updateSettings { $0.overlayLineCap = overlayLineCap }
      overlayController?.lineCap = overlayLineCap
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
      shortcutMonitor.isSuspended = !dictationEnabled || isRecordingShortcut
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
  let localModels: LocalModelsController
  weak var overlayController: OverlayController? {
    didSet { overlayController?.lineCap = overlayLineCap }
  }

  var lastTranscript: String? {
    history.latest?.text
  }

  var connectionSummary: String {
    if activeEngine == .fluidAudio {
      return "On-device · \(localModels.loadState.title) · \(localDictionaryTermSummary)"
    }
    return switch session.readiness {
    case .unavailable:
      "Add an API key"
    case .preparing, .recovering:
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
    case nil:
      switch session.readiness {
      case .preparing, .recovering: "ellipsis.circle"
      case .ready, .unavailable: "waveform.circle"
      }
    }
  }

  var statusColor: Color {
    switch session.presentation?.mode {
    case .listening: .signalBlue
    case .finalizing, .attention: .voiceCoral
    case nil:
      switch session.readiness {
      case .ready: .completionMint
      case .preparing, .recovering: .voiceCoral
      case .unavailable: .secondary
      }
    }
  }

  var errorMessage: String? {
    guard case .error(let message, _) = session.presented else { return nil }
    return message
  }

  private var backend: OpenAITranscriptionBackend?
  private var localBackend: FluidAudioTranscriptionBackend?
  private var activeEngine: TranscriptionEngineSelection
  private var activeLocalEntries: [LocalVocabularyEntry]
  private var changingEngine = false
  private var localModelManuallyUnloaded = false
  private let engine: TranscriptionEngineCoordinator
  private let audioCapture = AudioCapture()
  private let shortcutMonitor = ShortcutMonitor()
  private let insertionService = TextInsertionService()
  private let soundCues = SoundCues()
  private let keychain = KeychainStore()
  private let loginItemService = LoginItemService()
  private let updater = NativeUpdater()
  private let settingsStore: UserDefaultsSettingsStore
  private let dismissScheduler = DelayedActionScheduler()
  private let configurationScheduler = DelayedActionScheduler()
  private let historyPersistenceScheduler = DelayedActionScheduler()
  private let historyStore: TranscriptHistoryStore
  private let networkMonitor = NWPathMonitor()
  private let networkQueue = DispatchQueue(
    label: "\(AppIdentity.bundleIdentifier).network"
  )

  private var session: DictationSession
  private(set) var settings: DictationSettings
  private var buffers: [Int: AudioSnippetBuffer] = [:]
  private var currentAnchor: OverlayAnchor?
  private var streamingGeneration: Int?
  private var audioSequences: [Int: Int] = [:]
  private var finalizingTimers: [Int: Task<Void, Never>] = [:]
  private var eventTask: Task<Void, Never>?
  private var configurationEventTask: Task<Void, Never>?
  private let captureFinalizer = CaptureFinalizer()
  private let capturedAudioMailbox = CapturedAudioMailbox()
  private let insertionQueue = InsertionQueue()
  private var permissionPollingTask: Task<Void, Never>?
  private var workspaceObservers: [NSObjectProtocol] = []
  private var recordingStartedAt: Date?
  private var releasedAt: [Int: Date] = [:]
  private var isStarted = false
  private var isShortcutRunning = false
  private var savedAPIKey: String
  private var configurationNeedsReconnect = false
  private var configurationUpdateDeferred = false
  private var configurationUpdateScheduled = false
  private var pendingConfigurationAcks = 0
  private var isRefreshingLoginItemStatus = false
  private var didWarnForFnBinding = false
  private var historyEntryIDs: [Int: UUID] = [:]
  private var presentedHistoryEntryID: UUID?

  // swiftlint:disable:next function_body_length
  init(defaults: UserDefaults = .standard) {
    let settingsStore = UserDefaultsSettingsStore(defaults)
    self.settingsStore = settingsStore
    localModels = LocalModelsController(settings: settingsStore)
    let historyStore = TranscriptHistoryStore()
    self.historyStore = historyStore
    let storedAPIKey = localModels.engine == .openAI ? (try? keychain.readAPIKey()) ?? "" : ""
    let loginItemStatus = LoginItemService().status
    var settings = DictationSettings.load(from: settingsStore)
    if loginItemStatus == .enabled {
      settings.launchAtLogin = true
    }
    self.settings = settings
    activeEngine = localModels.engine
    activeLocalEntries = localModels.entries
    let runtime: any TranscriptionEngineRuntime
    if activeEngine == .openAI {
      let cloud = OpenAITranscriptionBackend(apiKey: storedAPIKey, configuration: settings.sessionConfiguration)
      backend = cloud
      runtime = cloud
    } else {
      let local = FluidAudioTranscriptionBackend(
        store: localModels.store,
        context: LocalInvocationContext(permanentEntries: localModels.entries),
        correctionPolicy: localModels.correctionEnabled ? .strict : .disabled
      )
      localBackend = local
      runtime = local
    }
    engine = TranscriptionEngineCoordinator(runtime: runtime, epoch: .init(0))
    history = settings.history.persist
      ? (try? historyStore.load()) ?? TranscriptHistory()
      : TranscriptHistory()
    savedAPIKey = storedAPIKey
    apiKeyDraft = storedAPIKey
    languages = settings.languages
    prompt = settings.prompt
    overlayPlacement = settings.overlayPlacement
    overlayLineCap = settings.overlayLineCap
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
      configuration: .init(tapToLock: settings.tapToLock, format: activeEngine.format),
      readiness: activeEngine == .fluidAudio
        ? .preparing(message: "Loading local model…")
        : storedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? .unavailable(reason: "Add an OpenAI API key before dictating.", action: nil)
        : .preparing(message: "Connecting…")
    )
    phaseTitle = session.phaseTitle
    settings.save(to: settingsStore)
    audioCapture.preferredDeviceUID = settings.inputDeviceUID

    audioCapture.onChunk = { [weak self] data in
      guard let self else { return }
      switch capturedAudioMailbox.enqueue(data) {
      case .scheduled:
        Task { @MainActor [weak self] in self?.drainCapturedAudio() }
      case .full(let generation):
        Task { @MainActor [weak self] in self?.apply(.bufferFull(generation: generation)) }
      case .queued, .inactive:
        break
      }
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
    shortcutMonitor.onTapDisabled = { [weak self] in
      Task { @MainActor [weak self] in self?.cancelLockedRecording() }
    }
    applyShortcutSet(settings.shortcuts)
    shortcutMonitor.isSuspended = !dictationEnabled
    DevelopmentTrace.shared.localTranscriptionSelected = activeEngine == .fluidAudio
    localModels.onConfigurationChanged = { [weak self] in self?.requestEngineConfiguration() }
    localModels.onLoad = { [weak self] in self?.loadLocalModel() }
    localModels.onUnload = { [weak self] in await self?.unloadLocalModel() }
    localModels.onPrepareSupplementalRemoval = { [weak self] in
      await self?.prepareSupplementalModelRemoval() ?? false
    }
    localModels.onSupplementalRemovalFinished = { [weak self] restoreReadiness in
      self?.finishSupplementalModelRemoval(restoreReadiness: restoreReadiness)
    }
  }

  func start() {
    guard !isStarted else { return }
    isStarted = true
    refreshPermissions()
    refreshInputDevices()
    refreshLoginItemStatus()
    startShortcutIfPermitted()
    observeReconnectSignals()

    eventTask = Task { [weak self, events = engine.events] in
      for await event in events {
        guard let self else { return }
        handleEngineEvent(event)
      }
    }
    observeCloudConfiguration()
    Task { [weak self] in
      guard let self else { return }
      await localModels.refresh()
      prepareSelectedEngine()
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
      Task { [backend] in await backend?.updateCredentials(apiKey) }
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
    Task { [backend] in await backend?.requestReconnect() }
  }

  var updatesAvailable: Bool {
    updater.isAvailable
  }

  func checkForUpdates() {
    updater.checkForUpdates()
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
    settings.save(to: settingsStore)
    guard activeEngine == .openAI else {
      configurationState = .applied
      return
    }
    switch ConfigurationUpdatePolicy().decision(
      from: oldSettings,
      to: settings,
      apiKeyChanged: false
    ) {
    case .reconnect:
      configurationNeedsReconnect = true
      scheduleConfigurationUpdate()
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
    guard activeEngine == .openAI, let backend else { return }
    guard session.readiness == .ready, isQuiescent else {
      configurationUpdateDeferred = true
      return
    }
    configurationUpdateDeferred = false
    configurationState = .pending
    if configurationNeedsReconnect {
      configurationNeedsReconnect = false
      pendingConfigurationAcks = 0
      let configuration = settings.sessionConfiguration
      Task { [weak self, backend] in
        let sent = await backend.updateConfiguration(configuration, reconnect: true)
        guard let self, !sent else { return }
        configurationUpdateDeferred = true
      }
      return
    }
    pendingConfigurationAcks += 1
    let configuration = settings.sessionConfiguration
    Task { [weak self] in
      guard let self, let backend = self.backend else { return }
      let sent = await backend.updateConfiguration(configuration, reconnect: false)
      if !sent {
        configurationUpdateDeferred = true
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
      presentedHistoryEntryID = outcome == .rejected ? entryID : nil
    case .engine(.failure(_, let invocationID?, _)):
      let generation = invocationID.generation
      guard let snippet = session.pending.first(where: { $0.generation == generation }) else { return nil }
      presentedHistoryEntryID = recordUnfinishedTranscript(
        snippet,
        outcome: .rejected
      )
    case .finalizingTimedOut(let generation):
      guard
        let snippet = session.pending.first(where: { $0.generation == generation }),
        !snippet.transcript.isEmpty
      else {
        return nil
      }
      let entryID = recordUnfinishedTranscript(
        snippet,
        outcome: .timedOut
      )
      presentedHistoryEntryID = entryID
    case .cancelRequested:
      if let listening = session.listening {
        recordCancelledTranscript(listening)
      } else {
        let cancellable = session.pending + session.inserting.filter { !$0.isInsertionStarted }
        if cancellable.isEmpty, session.presented != nil {
          presentedHistoryEntryID = nil
        }
        for snippet in cancellable where !snippet.transcript.isEmpty {
          recordCancelledTranscript(snippet)
        }
      }
    case .localError:
      if let listening = session.listening {
        presentedHistoryEntryID = recordCancelledTranscript(listening)
      }
    case .engine(.failure(_, nil, _)):
      if let listening = session.listening {
        presentedHistoryEntryID = recordCancelledTranscript(listening)
      }
    case .dismissRequested, .dismissDelayElapsed:
      presentedHistoryEntryID = nil
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
    outcome: TranscriptEntry.Outcome,
    targetBundleID: String? = nil
  ) -> UUID? {
    guard !text.isEmpty else { return nil }
    if let entryID = historyEntryIDs[generation] {
      updateHistory(id: entryID, outcome: outcome)
      return entryID
    }
    let entry = TranscriptEntry(
      text: text,
      targetBundleID: targetBundleID,
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
    recordUnfinishedTranscript(snippet, outcome: .cancelled)
  }

  @discardableResult
  private func recordUnfinishedTranscript(
    _ snippet: DictationSession.Snippet,
    outcome: TranscriptEntry.Outcome
  ) -> UUID? {
    if let entryID = historyEntryIDs[snippet.generation] {
      updateHistory(id: entryID, outcome: outcome)
      return entryID
    }
    guard activeEngine == .openAI, !snippet.transcript.isEmpty else { return nil }
    return recordTranscript(
      generation: snippet.generation,
      text: snippet.transcript,
      outcome: outcome
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
    if let insertionTelemetry {
      if insertionTelemetry.outcome == .confirmed || insertionTelemetry.outcome == .attempted {
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
    localModels.isDictating = !isQuiescent
    if localModels.pendingConfiguration, isQuiescent, !changingEngine {
      Task { [weak self] in await self?.replaceSelectedEngine() }
    }
  }

  // This switch is a direct, exhaustive interpreter for the core effect enum.
  // swiftlint:disable:next cyclomatic_complexity
  private func interpret(_ effect: DictationSession.Effect) {
    switch effect {
    case .startCapture(let invocation):
      if startStopSoundsEnabled {
        soundCues.playStart()
      }
      startCapture(invocation: invocation)
    case .stopCapture:
      if startStopSoundsEnabled {
        soundCues.playStop()
      }
      stopCaptureAfterGrace()
    case .beginTranscription(let invocation):
      // A rapid press must flush the previous generation's grace audio and
      // finish command before this begin can change the backend input owner.
      audioCapture.finishSegment()
      for chunk in capturedAudioMailbox.transition(to: invocation.id.generation) {
        handleAudioChunk(chunk.data, generation: chunk.generation)
      }
      captureFinalizer.finish(keepingCaptureRunning: true)
      submitEngineCommand(.begin(invocation))
    case .finishTranscription(let invocationID):
      captureFinalizer.commitAfterStop(generation: invocationID.generation) { [weak self] in
        guard let self,
              session.pending.contains(where: { $0.id == invocationID })
        else { return }
        submitEngineCommand(.finish(id: invocationID))
      }
    case .cancelTranscription(let invocationID): submitEngineCommand(.cancel(id: invocationID))
    case .scheduleFinalizingTimeout(let generation, let delay):
      scheduleFinalizingTimeout(generation: generation, delay: delay)
    case .cancelFinalizingTimeout(let generation): cancelFinalizingTimeout(generation: generation)
    case .recordTranscript(let generation, let text):
      recordTranscript(
        generation: generation,
        text: text,
        outcome: .attempted,
        targetBundleID: insertionService.captureFocusedTarget()?.targetBundleID
      )
    case .insert(let generation, let text): insert(generation: generation, text: text)
    case .insertAtCurrentFocus(let generation, let text):
      releasedAt[generation] = Date()
      insert(generation: generation, text: text)
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
      // Only promise recovery when the presented text is exactly what paste-last will use.
      let hint = AppModelCoordinationPolicy.recoveryHint(
        presentedHistoryEntryID: presentedHistoryEntryID,
        latestEntry: history.latest,
        presentedText: presentation.transcript,
        shortcutDisplayName: shortcuts.pasteLastTranscript?.displayName
      )
      let overlayPresentation = if presentation.mode == .attention, let hint {
        OverlayPresentation(
          mode: presentation.mode,
          transcript: presentation.transcript,
          message: "\(presentation.message) · \(hint)",
          pendingCount: presentation.pendingCount,
          isLocked: presentation.isLocked
        )
      } else {
        presentation
      }
      overlayModel.apply(overlayPresentation)
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
    guard AppModelCoordinationPolicy.acceptsNewInsertion(
      changingEngine: changingEngine,
      pendingConfiguration: localModels.pendingConfiguration
    ) else {
      apply(.localError(message: "Waiting for the engine change to finish."))
      return
    }
    if activeEngine == .fluidAudio, localModels.loadState == .unloaded {
      loadLocalModel()
    }
    guard session.readiness.permitsBoundedCapture else {
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
  @Published private(set) var recordingShortcutRole: ShortcutRole?
  var isRecordingShortcut: Bool {
    recordingShortcutRole != nil
  }

  func beginShortcutRecording(for role: ShortcutRole) -> Bool {
    guard recordingShortcutRole == nil else { return false }
    if session.listening != nil {
      apply(.cancelRequested)
    }
    recordingShortcutRole = role
    shortcutMonitor.isSuspended = true
    return true
  }

  func endShortcutRecording(for role: ShortcutRole) {
    guard recordingShortcutRole == role else { return }
    recordingShortcutRole = nil
    shortcutMonitor.isSuspended = !dictationEnabled
  }

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
    guard AppModelCoordinationPolicy.acceptsNewInsertion(
      changingEngine: changingEngine,
      pendingConfiguration: localModels.pendingConfiguration
    ) else {
      apply(.localError(message: "Waiting for the engine change to finish."))
      return
    }
    guard let lastTranscript else {
      flashAttention()
      return
    }
    apply(.pasteLastRequested(text: lastTranscript))
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

  private func handleConfigurationEvent(_ event: OpenAIConfigurationEvent) {
    switch event {
    case .applied:
      pendingConfigurationAcks = max(0, pendingConfigurationAcks - 1)
      if pendingConfigurationAcks == 0,
         !configurationUpdateScheduled,
         !configurationUpdateDeferred
      {
        configurationState = .applied
      }
      settingsMessage = "Connected with \(dictionaryWords.count) dictionary term\(dictionaryWords.count == 1 ? "" : "s")."
    case .failed(let message):
      pendingConfigurationAcks = 0
      configurationState = .failed(message)
    }
  }

  private func drainCapturedAudio() {
    for chunk in capturedAudioMailbox.drain() {
      handleAudioChunk(chunk.data, generation: chunk.generation)
    }
  }

  private func handleAudioChunk(_ data: Data, generation: Int) {
    let snippet = ([session.listening].compactMap(\.self) + session.pending)
      .first { $0.generation == generation }
    guard generation == streamingGeneration, var buffer = buffers[generation],
          let snippet
    else { return }
    let result = buffer.append(data)
    buffers[generation] = buffer
    if result == .stored {
      let sequence = audioSequences[generation, default: 0]
      audioSequences[generation] = sequence + 1
      submitEngineCommand(.append(id: snippet.id, sequence: sequence, audio: data))
    }
    if buffer.isFull {
      apply(.bufferFull(generation: generation))
    }
  }

  private func startCapture(invocation: TranscriptionInvocation) {
    let generation = invocation.id.generation
    let capturedFocus = insertionService.captureFocusedTarget()
    currentAnchor = insertionService.captureAnchor(for: capturedFocus)
    buffers[generation] = AudioSnippetBuffer(sampleRate: invocation.format.sampleRate)
    audioSequences[generation] = 0
    streamingGeneration = generation
    recordingStartedAt = Date()
    overlayModel.beginListening()
    do {
      try audioCapture.start(sampleRate: Double(invocation.format.sampleRate))
    } catch {
      apply(.localError(message: error.localizedDescription))
    }
  }

  private func stopCaptureAfterGrace() {
    recordingStartedAt = nil
    guard let stoppingGeneration = streamingGeneration else { return }
    captureFinalizer.schedule(generation: stoppingGeneration) { [weak self] in
      guard let self, streamingGeneration == stoppingGeneration else { return }
      audioCapture.stop()
      drainCapturedAudio()
      capturedAudioMailbox.deactivate(generation: stoppingGeneration)
      streamingGeneration = nil
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
    audioSequences.removeValue(forKey: generation)
    releasedAt.removeValue(forKey: generation)
    historyEntryIDs.removeValue(forKey: generation)
    cancelFinalizingTimeout(generation: generation)
  }

  private func insert(generation: Int, text: String) {
    let expectedEpoch = session.epoch
    insertionQueue.enqueue { [weak self] in
      guard let self else { return }
      guard session.epoch == expectedEpoch,
            session.inserting.contains(where: {
              $0.id == .init(epoch: expectedEpoch, generation: generation)
            })
      else { return }
      apply(.insertionStarted(generation: generation))
      let context = insertionService.captureFocusedTarget().map {
        insertionService.currentTextContext(for: $0)
      } ?? InsertionFormatter.Context(textBeforeCaret: nil, textAfterCaret: nil)
      let formatted = InsertionFormatter.format(
        text,
        context: context,
        options: insertionOptions
      )
      let result = await insertionService.insert(formatted, expected: formatted)
      apply(.insertionFinished(generation: generation, outcome: result.outcome, reason: result.reason))
    }
  }

  private var insertionOptions: InsertionFormatter.Options {
    .init(
      smartLeadingSpace: smartLeadingSpace,
      trailingSpace: trailingSpace,
      adjustCaseAfterComma: adjustCaseAfterComma,
      protectedTerms: activeEngine == .fluidAudio ? activeLocalEntries.map(\.canonicalText) : dictionaryWords
    )
  }

  private var dictionaryTermSummary: String {
    let count = dictionaryWords.count
    return "\(count) dictionary term\(count == 1 ? "" : "s")"
  }

  private var localDictionaryTermSummary: String {
    let count = localModels.entries.count
    return "\(count) local dictionary term\(count == 1 ? "" : "s")"
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
    case .confirmed where pastedSoundEnabled,
         .attempted where pastedSoundEnabled:
      soundCues.playPasted()
    case .rejected where rejectedSoundEnabled:
      soundCues.playRejected()
    default:
      break
    }
  }

  private func submitEngineCommand(_ command: TranscriptionEngineCommand) {
    AppModelCoordinationPolicy.submitEngineCommand(
      command,
      submit: { [engine] in engine.submit($0) },
      handleRejection: apply
    )
  }

  private func observeReconnectSignals() {
    let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { [weak self] in await self?.backend?.requestReconnect() }
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
      Task { [weak self] in await self?.backend?.requestReconnect() }
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

// swiftlint:enable type_body_length

private extension AppModel {
  var isQuiescent: Bool {
    session.listening == nil && session.pending.isEmpty && session.inserting.isEmpty
  }

  func observeCloudConfiguration() {
    configurationEventTask?.cancel()
    guard let backend else { return }
    let epoch = engine.epoch
    configurationEventTask = Task { [weak self, events = backend.configurationEvents] in
      for await event in events {
        guard let self, activeEngine == .openAI, engine.epoch == epoch else { continue }
        handleConfigurationEvent(event)
      }
    }
  }

  func handleEngineEvent(_ event: TranscriptionEngineEvent) {
    let epoch: TranscriptionBackendEpoch = switch event {
    case .readiness(let epoch, _), .failure(let epoch, _, _): epoch
    case .preview(let invocation, _), .final(let invocation, _): invocation.epoch
    }
    guard epoch == engine.epoch else { return }
    if activeEngine == .fluidAudio {
      switch event {
      case .readiness(_, .ready): localModels.loadState = .loaded
      case .readiness(_, .preparing): localModels.loadState = .loading
      case .readiness(_, .unavailable(let reason, _)):
        localModels.loadState = .failed(reason)
      case .final(_, let result) where result.correction == .degraded:
        localModels.message = "Dictionary correction was unavailable. The uncorrected transcript was used."
      default: break
      }
    }
    apply(.engine(event))
  }

  func prepareSelectedEngine() {
    if activeEngine == .fluidAudio {
      loadLocalModel()
    } else {
      _ = engine.submit(.prepare(epoch: engine.epoch))
    }
  }

  func loadLocalModel() {
    guard activeEngine == .fluidAudio, !changingEngine else { return }
    guard localModels.modelID == LocalModelCatalog.primaryID else {
      apply(.engine(.readiness(epoch: engine.epoch, state: .unavailable(
        reason: "The selected local model is not supported by this app version.", action: nil
      ))))
      return
    }
    guard LocalModelsController.hardwareSupported else {
      apply(.engine(.readiness(epoch: engine.epoch, state: .unavailable(
        reason: "On-device transcription requires Apple Silicon.", action: nil
      ))))
      return
    }
    guard localModels.installedIDs.contains(LocalModelCatalog.primaryID) else {
      apply(.engine(.readiness(epoch: engine.epoch, state: .unavailable(
        reason: "The local model is not installed.", action: "Download it in Settings > Models."
      ))))
      return
    }
    guard localModels.loadState != .loaded, localModels.loadState != .loading else { return }
    localModelManuallyUnloaded = false
    localModels.loadState = .loading
    apply(.engine(.readiness(epoch: engine.epoch, state: .preparing(message: "Loading local model…"))))
    _ = engine.submit(.prepare(epoch: engine.epoch))
  }

  func requestEngineConfiguration() {
    if localModels.engine != activeEngine {
      localModelManuallyUnloaded = false
    }
    localModels.pendingConfiguration = true
    guard isStarted, isQuiescent, !changingEngine else { return }
    Task { [weak self] in await self?.replaceSelectedEngine() }
  }

  func unloadLocalModel() async {
    guard activeEngine == .fluidAudio, isQuiescent, !changingEngine else { return }
    localModelManuallyUnloaded = true
    await replaceSelectedEngine(prewarm: false)
  }

  private func prepareSupplementalModelRemoval() async -> Bool {
    guard
      activeEngine == .fluidAudio,
      localModels.loadState == .loaded,
      isQuiescent,
      !changingEngine
    else {
      return false
    }
    let restoreReadiness = !localModelManuallyUnloaded
    await replaceSelectedEngine(prewarm: false)
    return restoreReadiness && localModels.loadState == .unloaded && !changingEngine
  }

  private func finishSupplementalModelRemoval(restoreReadiness: Bool) {
    guard
      activeEngine == .fluidAudio,
      localModels.engine == .fluidAudio,
      restoreReadiness
    else {
      return
    }
    prepareSelectedEngine()
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  func replaceSelectedEngine(prewarm: Bool = true) async {
    guard isQuiescent, !changingEngine else { return }
    changingEngine = true
    localModels.isDictating = true
    localModels.pendingConfiguration = false
    let selection = localModels.engine
    let context = LocalInvocationContext(permanentEntries: localModels.entries)
    let policy: LocalCorrectionPolicy = localModels.correctionEnabled ? .strict : .disabled
    if prewarm, selection == .fluidAudio, activeEngine == .fluidAudio,
       localModels.modelID == LocalModelCatalog.primaryID, let localBackend
    {
      let configurationResult: AppModelCoordinationPolicy.LocalConfigurationResult
      do {
        configurationResult = try await AppModelCoordinationPolicy.applyLocalConfiguration {
          try await localBackend.updateConfiguration(
            context: context,
            correctionPolicy: policy
          )
        }
      } catch is CancellationError {
        localModels.pendingConfiguration = true
        changingEngine = false
        localModels.isDictating = false
        return
      } catch {
        changingEngine = false
        localModels.isDictating = false
        localModels.message = "The local transcription settings could not be applied."
        if localModels.pendingConfiguration {
          await replaceSelectedEngine()
        }
        return
      }
      if configurationResult == .applied {
        activeLocalEntries = context.permanentEntries
        changingEngine = false
        localModels.isDictating = false
        if localModels.pendingConfiguration {
          await replaceSelectedEngine()
        } else if !localModelManuallyUnloaded {
          prepareSelectedEngine()
        }
        return
      }
      // A persistently busy backend falls through to the full replacement path below.
    }
    captureFinalizer.finish()
    configurationEventTask?.cancel()
    configurationScheduler.cancel()
    configurationUpdateDeferred = false
    configurationNeedsReconnect = false
    pendingConfigurationAcks = 0
    await backend?.shutdown()
    backend = nil
    await localBackend?.unload()
    localBackend = nil
    guard isQuiescent else {
      localModels.pendingConfiguration = true
      changingEngine = false
      localModels.isDictating = true
      return
    }
    let runtime: any TranscriptionEngineRuntime
    let replacementBackend: OpenAITranscriptionBackend?
    let replacementLocalBackend: FluidAudioTranscriptionBackend?
    let replacementAPIKey: String?
    if selection == .openAI {
      let apiKey = (try? keychain.readAPIKey()) ?? ""
      let cloud = OpenAITranscriptionBackend(apiKey: apiKey, configuration: settings.sessionConfiguration)
      runtime = cloud
      replacementBackend = cloud
      replacementLocalBackend = nil
      replacementAPIKey = apiKey
    } else {
      let local = FluidAudioTranscriptionBackend(store: localModels.store, context: context, correctionPolicy: policy)
      runtime = local
      replacementBackend = nil
      replacementLocalBackend = local
      replacementAPIKey = nil
    }
    let epoch = TranscriptionBackendEpoch(engine.epoch.rawValue + 1)
    let readiness = TranscriptionEngineReadiness.unavailable(
      reason: selection == .fluidAudio ? "Local model unloaded." : "Preparing OpenAI…",
      action: nil
    )
    let replacementApplied = AppModelCoordinationPolicy.applyEngineReplacement(
      session: &session,
      replacement: .init(
        coordinatorEpoch: engine.epoch,
        newEpoch: epoch,
        previousFormat: activeEngine.format,
        newFormat: selection.format,
        readiness: readiness
      )
    ) {
      engine.replace(runtime: runtime, epoch: epoch)
    }
    guard replacementApplied else {
      changingEngine = false
      localModels.isDictating = !isQuiescent
      localModels.pendingConfiguration = true
      localModels.message = "The transcription engine change could not be applied."
      publishSessionState()
      return
    }
    activeEngine = selection
    activeLocalEntries = context.permanentEntries
    backend = replacementBackend
    localBackend = replacementLocalBackend
    savedAPIKey = replacementAPIKey ?? savedAPIKey
    apiKeyDraft = replacementAPIKey ?? apiKeyDraft
    DevelopmentTrace.shared.localTranscriptionSelected = selection == .fluidAudio
    publishSessionState()
    localModels.loadState = .unloaded
    changingEngine = false
    localModels.isDictating = false
    observeCloudConfiguration()
    if localModels.pendingConfiguration {
      await replaceSelectedEngine()
    } else if prewarm, !localModelManuallyUnloaded {
      prepareSelectedEngine()
    }
  }
}

// swiftlint:enable file_length
