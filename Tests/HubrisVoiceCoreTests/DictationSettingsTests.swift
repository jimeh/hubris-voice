@testable import HubrisVoiceCore
import XCTest

final class DictationSettingsTests: XCTestCase {
  func testLoadDefaultsFromEmptyStore() {
    XCTAssertEqual(DictationSettings.load(from: MemorySettingsStore()), DictationSettings())
  }

  func testRoundTripPreservesEverySetting() {
    let expected = DictationSettings(
      languages: ["en", "fr"],
      prompt: "Names matter.",
      dictionary: ["Hucode"],
      overlayPlacement: .topOfScreen,
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
      tapToLock: true
    )
    let store = MemorySettingsStore()

    expected.save(to: store)

    XCTAssertEqual(DictationSettings.load(from: store), expected)
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

  func set(_ value: Any?, for key: String) {
    values[key] = value
  }
}
