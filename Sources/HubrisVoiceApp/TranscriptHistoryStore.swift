import Foundation
import HubrisVoiceCore

struct TranscriptHistoryStore: Sendable {
  static let displayPath =
    "~/Library/Application Support/HubrisVoice/history.json"

  let fileURL: URL

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/HubrisVoice", isDirectory: true)
      .appendingPathComponent("history.json")
  }

  func load() throws -> TranscriptHistory {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return TranscriptHistory()
    }
    return try JSONDecoder().decode(
      TranscriptHistory.self,
      from: Data(contentsOf: fileURL)
    )
  }

  func save(_ history: TranscriptHistory) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try JSONEncoder().encode(history)
    try data.write(to: fileURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
  }

  func delete() throws {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    try FileManager.default.removeItem(at: fileURL)
  }
}
