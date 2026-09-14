import Foundation
@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

final class UserDefaultsSettingsStoreTests: XCTestCase {
  func testMissingValuesRemainDistinctFromExplicitFalseAndZero() throws {
    let suite = "HubrisVoice.SettingsStoreTest.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsSettingsStore(defaults)
    XCTAssertNil(store.bool("enabled"))
    XCTAssertNil(store.integer("count"))
    store.set(false, for: "enabled")
    store.set(0, for: "count")
    XCTAssertFalse(try XCTUnwrap(store.bool("enabled")))
    XCTAssertEqual(store.integer("count"), 0)
    store.set(nil, for: "enabled")
    XCTAssertNil(store.bool("enabled"))
  }

  func testEngineAndVocabularyRoundTripThroughExistingDefaultsKeys() throws {
    let suite = "HubrisVoice.SettingsStoreTest.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsSettingsStore(defaults)
    let preferences = TranscriptionPreferences(engine: .fluidAudio, correctionEnabled: true)
    preferences.save(to: store)
    XCTAssertEqual(TranscriptionPreferences.load(from: UserDefaultsSettingsStore(defaults)), preferences)
    store.set(["PostgreSQL"], for: DictationSettings.Key.dictionary)
    XCTAssertEqual(store.stringArray(DictationSettings.Key.dictionary), ["PostgreSQL"])
  }
}
