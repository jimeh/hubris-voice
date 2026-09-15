@testable import HubrisVoiceCore
import XCTest

final class LocalVocabularyTests: XCTestCase {
  func testGeneratesDeterministicCamelAcronymAndUnderscoreAliases() {
    XCTAssertEqual(
      LocalVocabularyEntry(canonicalText: "URLSession").generatedAliases,
      ["U R L Session", "URL Session"]
    )
    XCTAssertEqual(
      LocalVocabularyEntry(canonicalText: "user_id").generatedAliases,
      ["user id", "user underscore id"]
    )
    XCTAssertEqual(
      LocalVocabularyEntry(canonicalText: "AXValue").generatedAliases,
      ["A X Value", "AX Value"]
    )
    XCTAssertEqual(
      LocalVocabularyEntry(canonicalText: "AXVisibleCharacterRange").generatedAliases,
      ["A X Visible Character Range", "AX Visible Character Range"]
    )
    XCTAssertEqual(
      LocalVocabularyEntry(canonicalText: "AppModel.swift").generatedAliases,
      ["App Model dot swift", "App Model.swift"]
    )
  }

  func testInvocationContextKeepsPermanentAndEphemeralEntriesSeparate() {
    let permanent = LocalVocabularyEntry(canonicalText: "HubrisVoice")
    let ephemeral = LocalVocabularyEntry(canonicalText: "private-window-sentinel")
    let context = LocalInvocationContext(
      permanentEntries: [permanent],
      ephemeralEntries: [ephemeral]
    )

    XCTAssertEqual(context.permanentEntries, [permanent])
    XCTAssertEqual(context.ephemeralEntries, [ephemeral])
    XCTAssertEqual(context.resolvedEntries.map(\.canonicalText), ["HubrisVoice", "private-window-sentinel"])
  }

  func testAmbiguousExplicitAliasIsRejected() {
    let context = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "user_id", explicitAliases: ["user ID"]),
      LocalVocabularyEntry(canonicalText: "userID", explicitAliases: ["user ID"]),
    ])

    XCTAssertFalse(context.resolvedEntries.flatMap(\.explicitAliases).contains("user ID"))
  }

  func testExplicitAliasTakesPrecedenceOverGeneratedCollision() {
    let context = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "URLSession"),
      LocalVocabularyEntry(canonicalText: "Networking", explicitAliases: ["URL session"]),
    ])

    XCTAssertEqual(
      context.resolvedEntries.first { $0.canonicalText == "Networking" }?.explicitAliases,
      ["URL session"]
    )
    XCTAssertFalse(
      context.resolvedEntries.first { $0.canonicalText == "URLSession" }?.explicitAliases
        .contains("URL Session") ?? true
    )
  }

  func testStoreRoundTripUsesVersionedLocalKey() throws {
    let store = MemoryLocalSettingsStore()
    let entries = [
      LocalVocabularyEntry(canonicalText: "user_id", explicitAliases: ["user underscore ID"]),
    ]

    try LocalVocabularyStore.save(entries, to: store)

    XCTAssertEqual(try LocalVocabularyStore.load(from: store), entries)
    XCTAssertEqual(store.string(LocalVocabularyStore.Key.vocabulary)?.contains("\"version\":1"), true)
  }

  func testCloudSeedRunsOnceAndNeverWritesTheCloudDictionaryKey() throws {
    let cloudKey = DictationSettings.Key.dictionary
    let store = MemoryLocalSettingsStore(values: [cloudKey: ["CloudOnly"]])

    XCTAssertEqual(
      try LocalVocabularyStore.seedFromCloudIfNeeded(["CloudOnly"], in: store),
      [LocalVocabularyEntry(canonicalText: "CloudOnly")]
    )
    try LocalVocabularyStore.save(
      [LocalVocabularyEntry(canonicalText: "LocalPrivate")],
      to: store
    )

    XCTAssertEqual(
      try LocalVocabularyStore.seedFromCloudIfNeeded(["NewCloudValue"], in: store),
      [LocalVocabularyEntry(canonicalText: "LocalPrivate")]
    )
    XCTAssertEqual(store.stringArray(cloudKey), ["CloudOnly"])
  }

  func testMalformedStorePayloadThrowsWithoutChangingPersistedData() {
    let encoded = "{not-json"
    let store = MemoryLocalSettingsStore(values: [
      LocalVocabularyStore.Key.vocabulary: encoded,
    ])

    XCTAssertThrowsError(try LocalVocabularyStore.load(from: store)) { error in
      XCTAssertEqual(error as? LocalVocabularyStore.StoreError, .invalidPayload)
    }
    XCTAssertEqual(store.string(LocalVocabularyStore.Key.vocabulary), encoded)
  }

  func testUnknownStoreVersionThrowsWithoutChangingPersistedData() {
    let encoded = "{\"version\":2,\"entries\":[]}"
    let store = MemoryLocalSettingsStore(values: [
      LocalVocabularyStore.Key.vocabulary: encoded,
    ])

    XCTAssertThrowsError(try LocalVocabularyStore.load(from: store)) { error in
      XCTAssertEqual(error as? LocalVocabularyStore.StoreError, .unsupportedVersion(2))
    }
    XCTAssertEqual(store.string(LocalVocabularyStore.Key.vocabulary), encoded)
  }

  func testInvalidExistingPayloadDoesNotCompleteOrOverwriteCloudSeed() {
    let encoded = "{not-json"
    let store = MemoryLocalSettingsStore(values: [
      LocalVocabularyStore.Key.vocabulary: encoded,
    ])

    XCTAssertThrowsError(try LocalVocabularyStore.seedFromCloudIfNeeded(["CloudOnly"], in: store))
    XCTAssertEqual(store.string(LocalVocabularyStore.Key.vocabulary), encoded)
    XCTAssertNil(store.bool(LocalVocabularyStore.Key.cloudSeedCompleted))
  }
}

private final class MemoryLocalSettingsStore: SettingsStore, @unchecked Sendable {
  private var values: [String: Any]

  init(values: [String: Any] = [:]) {
    self.values = values
  }

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
