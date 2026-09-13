import Foundation

// The public `id` names are part of the milestone API contract.
// swiftlint:disable identifier_name

public struct TranscriptEntry: Equatable, Codable, Identifiable, Sendable {
  public enum Outcome: String, Codable, Sendable {
    case pasted
    case attempted
    case rejected
    case timedOut
    case copied
    case cancelled
  }

  public let id: UUID
  public let text: String
  public let recordedAt: Date
  public let targetBundleID: String?
  public var outcome: Outcome

  public init(
    id: UUID = UUID(),
    text: String,
    recordedAt: Date = Date(),
    targetBundleID: String?,
    outcome: Outcome
  ) {
    self.id = id
    self.text = text
    self.recordedAt = recordedAt
    self.targetBundleID = targetBundleID
    self.outcome = outcome
  }
}

public struct TranscriptHistory: Equatable, Codable, Sendable {
  public private(set) var entries: [TranscriptEntry]

  private let limit: Int

  public init(limit: Int = 50) {
    precondition(limit >= 0)
    self.limit = limit
    entries = []
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    limit = try container.decode(Int.self, forKey: .limit)
    guard limit >= 0 else {
      throw DecodingError.dataCorruptedError(forKey: .limit, in: container, debugDescription: "Negative history limit")
    }
    entries = try Array(container.decode([TranscriptEntry].self, forKey: .entries).prefix(limit))
  }

  public var latest: TranscriptEntry? {
    entries.first
  }

  public mutating func record(_ entry: TranscriptEntry) {
    entries.insert(entry, at: 0)
    if entries.count > limit {
      entries.removeLast(entries.count - limit)
    }
  }

  public mutating func update(id: UUID, outcome: TranscriptEntry.Outcome) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[index].outcome = outcome
  }

  public mutating func remove(id: UUID) {
    entries.removeAll { $0.id == id }
  }

  public mutating func clear() {
    entries.removeAll()
  }

  public func search(_ query: String) -> [TranscriptEntry] {
    guard !query.isEmpty else { return entries }
    return entries.filter {
      $0.text.range(
        of: query,
        options: [.caseInsensitive, .diacriticInsensitive]
      ) != nil
    }
  }
}

// swiftlint:enable identifier_name
