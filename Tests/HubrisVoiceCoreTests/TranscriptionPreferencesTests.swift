import HubrisVoiceCore
import XCTest

final class TranscriptionPreferencesTests: XCTestCase {
  func testDefaultsKeepOpenAIAndCorrectionOff() {
    let preferences = TranscriptionPreferences.load(from: PreferenceStore())
    XCTAssertEqual(preferences.engine, .openAI)
    XCTAssertFalse(preferences.correctionEnabled)
  }

  func testSwitchingToCloudSerializesOnlyTheCloudVocabulary() throws {
    let store = PreferenceStore()
    DictationSettings(dictionary: ["CloudVocabulary"]).save(to: store)
    try LocalVocabularyStore.save([
      LocalVocabularyEntry(canonicalText: "PrivateCanonicalSentinel", explicitAliases: ["private alias sentinel"]),
    ], to: store)
    TranscriptionPreferences(engine: .fluidAudio, correctionEnabled: true).save(to: store)
    TranscriptionPreferences(engine: .openAI).save(to: store)
    let configuration = DictationSettings.load(from: store).sessionConfiguration
    let data = try RealtimeClientEvent.sessionUpdate(configuration).encoded()
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(json.contains("CloudVocabulary"))
    XCTAssertFalse(json.contains("PrivateCanonicalSentinel"))
    XCTAssertFalse(json.contains("private alias sentinel"))
    XCTAssertEqual(try LocalVocabularyStore.load(from: store).count, 1)
  }

  func testLocalSelectionSurvivesWithoutInstallationAndDoesNotChangeCloudSettings() {
    let store = PreferenceStore()
    store.set(["CloudOnly"], for: DictationSettings.Key.dictionary)
    let expected = TranscriptionPreferences(engine: .fluidAudio, correctionEnabled: true)
    expected.save(to: store)
    XCTAssertEqual(TranscriptionPreferences.load(from: store), expected)
    XCTAssertEqual(DictationSettings.load(from: store).dictionary, ["CloudOnly"])
  }
}

private final class PreferenceStore: SettingsStore, @unchecked Sendable {
  private var values: [String: Any] = [:]
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
