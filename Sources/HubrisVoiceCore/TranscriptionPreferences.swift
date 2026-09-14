import Foundation

public enum TranscriptionEngineSelection: String, CaseIterable, Sendable {
  case openAI
  case fluidAudio

  public var title: String {
    switch self {
    case .openAI: "OpenAI"
    case .fluidAudio: "On-device · FluidAudio"
    }
  }

  public var format: TranscriptionPCMFormat {
    self == .openAI ? .openAI : .local
  }
}

/// Device selection is independent of installation and in-memory model state.
public struct TranscriptionPreferences: Equatable, Sendable {
  public enum Key {
    public static let engine = "transcription.engine"
    public static let localModel = "transcription.local.model"
    public static let correctionEnabled = "transcription.local.correctionEnabled"
  }

  public static let defaultLocalModel = "parakeet-unified-en-320ms"
  public var engine: TranscriptionEngineSelection
  public var localModel: String
  public var correctionEnabled: Bool

  public init(
    engine: TranscriptionEngineSelection = .openAI,
    localModel: String = Self.defaultLocalModel,
    correctionEnabled: Bool = true
  ) {
    self.engine = engine
    self.localModel = localModel
    self.correctionEnabled = correctionEnabled
  }

  public static func load(from store: SettingsStore) -> Self {
    Self(
      engine: store.string(Key.engine).flatMap(TranscriptionEngineSelection.init(rawValue:))
        ?? (store.contains(Key.engine) ? .fluidAudio : .openAI),
      localModel: store.string(Key.localModel) ?? defaultLocalModel,
      correctionEnabled: store.bool(Key.correctionEnabled) ?? true
    )
  }

  public func save(to store: SettingsStore) {
    store.set(engine.rawValue, for: Key.engine)
    store.set(localModel, for: Key.localModel)
    store.set(correctionEnabled, for: Key.correctionEnabled)
  }
}
