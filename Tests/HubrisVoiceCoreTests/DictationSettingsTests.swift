@testable import HubrisVoiceCore
import XCTest

final class DictationSettingsTests: XCTestCase {
  func testLegacyJavaneseCodeMigrates() {
    for value: Any in ["jw", ["en", "jw"]] {
      let store = MemorySettingsStore(values: [DictationSettings.Key.language: value])
      let languages = DictationSettings.load(from: store).languages
      XCTAssertTrue(languages.contains("jv"))
      XCTAssertFalse(languages.contains("jw"))
    }
  }

  func testLoadDefaultsFromEmptyStore() {
    let settings = DictationSettings.load(from: MemorySettingsStore())

    XCTAssertEqual(settings, DictationSettings())
    XCTAssertEqual(settings.overlayLineCap, 3)
  }

  func testOverlayLineCapClampsStoredValues() {
    XCTAssertEqual(
      DictationSettings.load(
        from: MemorySettingsStore(values: [DictationSettings.Key.overlayLineCap: 0])
      ).overlayLineCap,
      1
    )
    XCTAssertEqual(
      DictationSettings.load(
        from: MemorySettingsStore(values: [DictationSettings.Key.overlayLineCap: 9])
      ).overlayLineCap,
      6
    )
  }

  func testRoundTripPreservesEverySetting() {
    let expected = DictationSettings(
      languages: ["en", "fr"],
      prompt: "Names matter.",
      dictionary: ["Hucode"],
      overlayPlacement: .topOfScreen,
      overlayLineCap: 6,
      smartLeadingSpace: false,
      trailingSpace: false,
      adjustCaseAfterComma: true,
      inputDeviceUID: "microphone-1",
      launchAtLogin: true,
      shortcuts: ShortcutSet(
        pushToTalk: .modifier(.rightCommand),
        pasteLastTranscript: .chord(
          GlobalShortcut(keyCode: 8, modifiers: [.control, .option])
        )
      ),
      tapToLock: true,
      history: HistorySettings(persist: true),
      sounds: SoundCueSettings(startStop: true, pasted: true, rejected: true)
    )
    let store = MemorySettingsStore()

    expected.save(to: store)

    XCTAssertEqual(DictationSettings.load(from: store), expected)
  }

  func testDictationEnabledAlwaysResetsAtLaunch() {
    let settings = DictationSettings(dictationEnabled: false)
    let store = MemorySettingsStore()

    settings.save(to: store)

    XCTAssertTrue(DictationSettings.load(from: store).dictationEnabled)
  }

  func testInvalidShortcutJSONFallsBackToDefault() {
    let store = MemorySettingsStore(values: [
      DictationSettings.Key.shortcuts: "not-json",
    ])

    XCTAssertEqual(DictationSettings.load(from: store).shortcuts, ShortcutSet())
  }

  func testLoadMigratesTheExistingSingularLanguageValue() {
    let store = MemorySettingsStore(values: [DictationSettings.Key.language: "fr"])

    XCTAssertEqual(DictationSettings.load(from: store).languages, ["fr"])
  }

  func testSessionConfigurationMapsTranscriptionFields() {
    let settings = DictationSettings(
      languages: ["de", "en"],
      prompt: "Prompt",
      dictionary: ["Hubris"]
    )

    XCTAssertEqual(
      settings.sessionConfiguration,
      RealtimeSessionConfiguration(
        languages: ["de", "en"],
        prompt: "Prompt",
        keywords: ["Hubris"],
        delay: .low
      )
    )
  }
}

private final class MemorySettingsStore: SettingsStore, @unchecked Sendable {
  private var values: [String: Any]

  init(values: [String: Any] = [:]) {
    self.values = values
  }

  func string(_ key: String) -> String? {
    values[key] as? String
  }

  func stringArray(_ key: String) -> [String]? {
    values[key] as? [String]
  }

  func bool(_ key: String) -> Bool? {
    values[key] as? Bool
  }

  func integer(_ key: String) -> Int? {
    values[key] as? Int
  }

  func set(_ value: Any?, for key: String) {
    values[key] = value
  }
}
