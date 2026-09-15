import Foundation
import HubrisVoiceCore

@MainActor
final class LocalModelsController: ObservableObject {
  enum LoadState: Equatable {
    case unloaded, loading, loaded
    case failed(String)

    var title: String {
      switch self {
      case .unloaded: "Unloaded"
      case .loading: "Loading model…"
      case .loaded: "Loaded"
      case .failed(let message): message
      }
    }
  }

  @Published var engine: TranscriptionEngineSelection {
    didSet { configurationChanged() }
  }

  @Published var correctionEnabled: Bool {
    didSet { configurationChanged() }
  }

  @Published var activeWindowContextEnabled: Bool {
    didSet { configurationChanged() }
  }

  @Published var entries: [LocalVocabularyEntry] {
    didSet {
      // Published assignments re-enter this observer, so rollback must bypass persistence.
      if restoringEntries {
        restoringEntries = false
        return
      }
      guard dictionaryError == nil else {
        restoringEntries = true
        entries = oldValue
        return
      }
      do {
        try LocalVocabularyStore.save(entries, to: settings)
      } catch {
        dictionaryError = "The local dictionary could not be saved. Its previous contents were left unchanged."
        restoringEntries = true
        entries = oldValue
        return
      }
      onConfigurationChanged?()
    }
  }

  @Published private(set) var dictionaryError: String?
  @Published private(set) var installedIDs: Set<String> = []
  @Published private(set) var downloadingID: String?
  @Published private(set) var progress: LocalModelProgress?
  @Published private(set) var checking = false
  @Published var message: String?
  @Published var loadState: LoadState = .unloaded
  @Published var pendingConfiguration = false
  @Published var isDictating = false

  let store: LocalModelStore
  @Published var modelID: String {
    didSet { configurationChanged() }
  }

  var onConfigurationChanged: (() -> Void)?
  var onLoad: (() -> Void)?
  var onUnload: (() async -> Void)?
  var onPrepareSupplementalRemoval: (() async -> Bool)?
  var onSupplementalRemovalFinished: ((Bool) -> Void)?
  private let settings: any SettingsStore
  private var downloadTask: Task<Void, Never>?
  private var restoringEntries = false

  var isDictionaryAvailable: Bool {
    dictionaryError == nil
  }

  static var hardwareSupported: Bool {
    #if arch(arm64)
      true
    #else
      false
    #endif
  }

  init(settings: any SettingsStore, store: LocalModelStore = LocalModelStore()) {
    self.settings = settings
    self.store = store
    let preferences = TranscriptionPreferences.load(from: settings)
    modelID = preferences.localModel
    engine = preferences.engine
    correctionEnabled = preferences.correctionEnabled
    activeWindowContextEnabled = preferences.activeWindowContextEnabled
    do {
      entries = try LocalVocabularyStore.seedFromCloudIfNeeded(
        settings.stringArray(DictationSettings.Key.dictionary) ?? [], in: settings
      )
      dictionaryError = nil
    } catch LocalVocabularyStore.StoreError.unsupportedVersion {
      entries = []
      dictionaryError =
        "The local dictionary was created by a newer version of Hubris Voice. "
          + "Update the app to edit it. The saved dictionary was left unchanged."
    } catch {
      entries = []
      dictionaryError =
        "The saved local dictionary could not be read. Restore or remove it before editing. The saved dictionary was left unchanged."
    }
  }

  func refresh() async {
    guard !checking else { return }
    checking = true
    defer { checking = false }
    var verified: Set<String> = []
    for model in LocalModelCatalog.models {
      do {
        if try await store.installed(model.id) {
          verified.insert(model.id)
        }
      } catch {
        message = "Model files could not be verified. Remove and download the affected model again."
      }
    }
    installedIDs = verified
  }

  func download(_ modelID: String) {
    guard downloadTask == nil else { return }
    downloadingID = modelID
    message = nil
    progress = nil
    downloadTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await store.install(modelID) { [weak self] progress in
          Task { @MainActor [weak self] in self?.progress = progress }
        }
        message = "Download verified and installed."
      } catch is CancellationError {
        message = "Download cancelled. Retry keeps files already verified."
      } catch let error as URLError where error.code == .cancelled {
        message = "Download cancelled. Retry keeps files already verified."
      } catch {
        message = "The model could not be downloaded or verified. Check free disk space and your connection, then retry."
      }
      downloadingID = nil
      progress = nil
      downloadTask = nil
      await refresh()
      if engine == .fluidAudio {
        onConfigurationChanged?()
      }
    }
  }

  func cancelDownload() {
    downloadTask?.cancel()
  }

  func load() {
    onLoad?()
  }

  func unload() {
    guard !isDictating else { return }
    Task { await onUnload?() }
  }

  func remove(_ modelID: String) {
    guard !isDictating, downloadTask == nil else { return }
    Task {
      let restoreSupplementalReadiness: Bool
      if modelID == LocalModelCatalog.primaryID {
        await onUnload?()
        restoreSupplementalReadiness = false
      } else if modelID == LocalModelCatalog.correctionID {
        restoreSupplementalReadiness = await onPrepareSupplementalRemoval?() ?? false
      } else {
        restoreSupplementalReadiness = false
      }
      do {
        try await store.remove(modelID)
        message = "Model files removed."
      } catch {
        message = "Model files could not be removed. Unload the model and retry."
      }
      await refresh()
      if modelID == LocalModelCatalog.primaryID {
        if engine == .fluidAudio {
          onLoad?()
        }
      } else if modelID == LocalModelCatalog.correctionID {
        onSupplementalRemovalFinished?(restoreSupplementalReadiness)
      }
    }
  }

  private func configurationChanged() {
    TranscriptionPreferences(
      engine: engine,
      localModel: modelID,
      correctionEnabled: correctionEnabled,
      activeWindowContextEnabled: activeWindowContextEnabled
    )
    .save(to: settings)
    onConfigurationChanged?()
  }
}
