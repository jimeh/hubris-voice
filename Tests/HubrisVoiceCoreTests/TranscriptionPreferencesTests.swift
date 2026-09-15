import HubrisVoiceCore
import XCTest

final class TranscriptionPreferencesTests: XCTestCase {
  func testDefaultsKeepOpenAIAndEnableLocalCorrection() {
    let preferences = TranscriptionPreferences.load(from: PreferenceStore())
    XCTAssertEqual(preferences.engine, .openAI)
    XCTAssertTrue(preferences.correctionEnabled)
    XCTAssertFalse(preferences.activeWindowContextEnabled)
  }

  func testActiveWindowContextIsOptInAndPersistsIndependently() {
    let store = PreferenceStore()
    var preferences = TranscriptionPreferences(
      engine: .fluidAudio,
      correctionEnabled: false,
      activeWindowContextEnabled: true
    )
    preferences.save(to: store)

    preferences = TranscriptionPreferences.load(from: store)
    XCTAssertTrue(preferences.activeWindowContextEnabled)
    XCTAssertFalse(preferences.correctionEnabled)

    preferences.engine = .openAI
    preferences.save(to: store)
    XCTAssertTrue(TranscriptionPreferences.load(from: store).activeWindowContextEnabled)
  }

  func testLocalCorrectionDefaultsOnWithoutSavedPreference() {
    let store = PreferenceStore()
    store.set(TranscriptionEngineSelection.fluidAudio.rawValue, for: TranscriptionPreferences.Key.engine)
    XCTAssertTrue(TranscriptionPreferences.load(from: store).correctionEnabled)
    XCTAssertTrue(TranscriptionPreferences(engine: .fluidAudio).correctionEnabled)
  }

  func testExplicitlyDisabledCorrectionSurvivesEngineSwitches() {
    let store = PreferenceStore()
    var preferences = TranscriptionPreferences(engine: .fluidAudio, correctionEnabled: false)
    preferences.save(to: store)
    preferences = TranscriptionPreferences.load(from: store)
    preferences.engine = .openAI
    preferences.save(to: store)
    preferences = TranscriptionPreferences.load(from: store)
    preferences.engine = .fluidAudio
    preferences.save(to: store)
    XCTAssertFalse(TranscriptionPreferences.load(from: store).correctionEnabled)
  }

  func testValidEngineSelectionIsLoaded() {
    let store = PreferenceStore()
    store.set(TranscriptionEngineSelection.openAI.rawValue, for: TranscriptionPreferences.Key.engine)

    XCTAssertEqual(TranscriptionPreferences.load(from: store).engine, .openAI)
  }

  func testUnknownEngineSelectionFallsBackToLocal() {
    let store = PreferenceStore()
    store.set("retired-engine", for: TranscriptionPreferences.Key.engine)

    XCTAssertEqual(TranscriptionPreferences.load(from: store).engine, .fluidAudio)
  }

  func testWrongTypedEngineSelectionFallsBackToLocal() {
    let store = PreferenceStore()
    store.set(42, for: TranscriptionPreferences.Key.engine)

    XCTAssertEqual(TranscriptionPreferences.load(from: store).engine, .fluidAudio)
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

  func contains(_ key: String) -> Bool {
    values.keys.contains(key)
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
