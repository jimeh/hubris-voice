import Foundation

public enum LocalVocabularyStore {
  public enum StoreError: Error, Equatable {
    case invalidEncoding
    case invalidPayload
    case unsupportedVersion(Int)
  }

  public enum Key {
    public static let vocabulary = "localTranscription.vocabulary"
    public static let cloudSeedCompleted = "localTranscription.vocabulary.cloudSeedCompleted"
  }

  private struct Payload: Codable {
    let version: Int
    let entries: [LocalVocabularyEntry]
  }

  public static func load(from store: SettingsStore) throws -> [LocalVocabularyEntry] {
    guard store.contains(Key.vocabulary) else { return [] }
    guard let encoded = store.string(Key.vocabulary) else {
      throw StoreError.invalidPayload
    }
    guard let data = encoded.data(using: .utf8) else {
      throw StoreError.invalidPayload
    }
    let payload: Payload
    do {
      payload = try JSONDecoder().decode(Payload.self, from: data)
    } catch {
      throw StoreError.invalidPayload
    }
    guard payload.version == 1 else {
      throw StoreError.unsupportedVersion(payload.version)
    }
    return payload.entries
  }

  public static func save(_ entries: [LocalVocabularyEntry], to store: SettingsStore) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(Payload(version: 1, entries: entries))
    guard let encoded = String(bytes: data, encoding: .utf8) else {
      throw StoreError.invalidEncoding
    }
    store.set(encoded, for: Key.vocabulary)
  }

  @discardableResult
  public static func seedFromCloudIfNeeded(
    _ cloudCanonicalTexts: [String],
    in store: SettingsStore
  ) throws -> [LocalVocabularyEntry] {
    if store.bool(Key.cloudSeedCompleted) == true {
      return try load(from: store)
    }

    if !store.contains(Key.vocabulary) {
      let entries = cloudCanonicalTexts.map {
        LocalVocabularyEntry(canonicalText: $0)
      }
      try save(entries, to: store)
    }
    let entries = try load(from: store)
    store.set(true, for: Key.cloudSeedCompleted)
    return entries
  }
}
