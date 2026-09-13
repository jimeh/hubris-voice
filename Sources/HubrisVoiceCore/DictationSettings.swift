import Foundation

public protocol SettingsStore: AnyObject, Sendable {
  func string(_ key: String) -> String?
  func stringArray(_ key: String) -> [String]?
  func bool(_ key: String) -> Bool?
  func set(_ value: Any?, for key: String)
}

public struct DictationSettings: Equatable, Sendable {
  public enum Key {
    public static let language = "transcription.language"
    public static let prompt = "transcription.prompt"
    public static let dictionary = "transcription.dictionary"
    public static let overlayPlacement = "overlay.placement"
    public static let smartLeadingSpace = "insertion.smartLeadingSpace"
    public static let trailingSpace = "insertion.trailingSpace"
    public static let adjustCaseAfterComma = "insertion.adjustCaseAfterComma"
    public static let inputDeviceUID = "audio.inputDeviceUID"
    public static let launchAtLogin = "app.launchAtLogin"
    public static let shortcuts = "shortcuts.bindings"
    public static let tapToLock = "shortcuts.tapToLock"
  }

  public static let defaultPrompt =
    "Transcribe natural dictation. Preserve the spelling and capitalization of dictionary terms. Add punctuation suitable for prose."

  public var languages: [String]
  public var prompt: String
  public var dictionary: [String]
  public var overlayPlacement: OverlayPlacementPreference
  public var smartLeadingSpace: Bool
  public var trailingSpace: Bool
  public var adjustCaseAfterComma: Bool
  public var inputDeviceUID: String?
  public var launchAtLogin: Bool
  public var shortcuts: ShortcutSet
  public var tapToLock: Bool

  public init(
    languages: [String] = ["en"],
    prompt: String = Self.defaultPrompt,
    dictionary: [String] = [],
    overlayPlacement: OverlayPlacementPreference = .automatic,
    smartLeadingSpace: Bool = true,
    trailingSpace: Bool = true,
    adjustCaseAfterComma: Bool = false,
    inputDeviceUID: String? = nil,
    launchAtLogin: Bool = false,
    shortcuts: ShortcutSet = .init(),
    tapToLock: Bool = false
  ) {
    self.languages = languages
    self.prompt = prompt
    self.dictionary = dictionary
    self.overlayPlacement = overlayPlacement
    self.smartLeadingSpace = smartLeadingSpace
    self.trailingSpace = trailingSpace
    self.adjustCaseAfterComma = adjustCaseAfterComma
    self.inputDeviceUID = inputDeviceUID
    self.launchAtLogin = launchAtLogin
    self.shortcuts = shortcuts
    self.tapToLock = tapToLock
  }

  public static func load(from store: SettingsStore) -> DictationSettings {
    let languages = store.stringArray(Key.language)
      ?? store.string(Key.language).map { [$0] }
      ?? ["en"]
    let shortcuts = store.string(Key.shortcuts)
      .flatMap { $0.data(using: .utf8) }
      .flatMap { try? JSONDecoder().decode(ShortcutSet.self, from: $0) }
      ?? ShortcutSet()
    return DictationSettings(
      languages: languages,
      prompt: store.string(Key.prompt) ?? defaultPrompt,
      dictionary: store.stringArray(Key.dictionary) ?? [],
      overlayPlacement: store.string(Key.overlayPlacement)
        .flatMap(OverlayPlacementPreference.init(rawValue:)) ?? .automatic,
      smartLeadingSpace: store.bool(Key.smartLeadingSpace) ?? true,
      trailingSpace: store.bool(Key.trailingSpace) ?? true,
      adjustCaseAfterComma: store.bool(Key.adjustCaseAfterComma) ?? false,
      inputDeviceUID: store.string(Key.inputDeviceUID),
      launchAtLogin: store.bool(Key.launchAtLogin) ?? false,
      shortcuts: shortcuts,
      tapToLock: store.bool(Key.tapToLock) ?? false
    )
  }

  public func save(to store: SettingsStore) {
    store.set(languages, for: Key.language)
    store.set(prompt, for: Key.prompt)
    store.set(dictionary, for: Key.dictionary)
    store.set(overlayPlacement.rawValue, for: Key.overlayPlacement)
    store.set(smartLeadingSpace, for: Key.smartLeadingSpace)
    store.set(trailingSpace, for: Key.trailingSpace)
    store.set(adjustCaseAfterComma, for: Key.adjustCaseAfterComma)
    store.set(inputDeviceUID, for: Key.inputDeviceUID)
    store.set(launchAtLogin, for: Key.launchAtLogin)
    let encodedShortcuts = try? JSONEncoder().encode(shortcuts)
    store.set(encodedShortcuts.flatMap { String(data: $0, encoding: .utf8) }, for: Key.shortcuts)
    store.set(tapToLock, for: Key.tapToLock)
  }

  public var sessionConfiguration: RealtimeSessionConfiguration {
    RealtimeSessionConfiguration(
      languages: languages,
      prompt: prompt,
      keywords: dictionary,
      delay: .low
    )
  }
}

public struct ConfigurationUpdatePolicy: Equatable, Sendable {
  public enum Decision: Equatable, Sendable {
    case reconnect
    case sessionUpdate
    case nothing
  }

  public init() {}

  public func decision(
    from old: DictationSettings,
    to new: DictationSettings,
    apiKeyChanged: Bool
  ) -> Decision {
    if apiKeyChanged {
      return .reconnect
    }
    if old.sessionConfiguration != new.sessionConfiguration {
      return .sessionUpdate
    }
    return .nothing
  }
}
