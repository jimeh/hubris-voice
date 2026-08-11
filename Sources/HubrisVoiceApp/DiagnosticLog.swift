import Foundation
import HubrisVoiceCore
import OSLog

actor DiagnosticLog {
  enum Level: String, Sendable {
    case info = "INFO"
    case error = "ERROR"
  }

  nonisolated static let displayPath =
    "~/Library/Logs/HubrisVoice/realtime.log"
  static let shared = DiagnosticLog()

  private let systemLogger = Logger(
    subsystem: "com.jimeh.HubrisVoice",
    category: "Realtime"
  )
  private let fileURL: URL
  private let dateFormatter: ISO8601DateFormatter

  private init() {
    fileURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/HubrisVoice", isDirectory: true)
      .appendingPathComponent("realtime.log")
    dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [
      .withInternetDateTime,
      .withFractionalSeconds,
    ]
  }

  func record(_ message: String, level: Level = .info) {
    let message = RealtimeDiagnosticFormatter.sanitize(message)
    switch level {
    case .info:
      systemLogger.info("\(message, privacy: .public)")
    case .error:
      systemLogger.error("\(message, privacy: .public)")
    }

    let line =
      "\(dateFormatter.string(from: Date())) "
        + "[\(level.rawValue)] \(message)\n"
    appendToFile(line)
  }

  private func appendToFile(_ line: String) {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if !FileManager.default.fileExists(atPath: fileURL.path) {
        _ = FileManager.default.createFile(
          atPath: fileURL.path,
          contents: nil
        )
      }

      let handle = try FileHandle(forWritingTo: fileURL)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(line.utf8))
      try handle.close()
    } catch {
      let errorSummary = RealtimeDiagnosticFormatter.errorSummary(error)
      systemLogger.error(
        "Failed to write diagnostic log: \(errorSummary, privacy: .public)"
      )
    }
  }
}
