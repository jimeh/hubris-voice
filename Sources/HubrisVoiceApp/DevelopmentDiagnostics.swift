import Foundation

/// Opt-in diagnostics for local debug builds. Never enabled by saved preferences.
enum DevelopmentDiagnostics {
  static let traceEnabled = enabled("--development-trace")

  static func enabled(_ flag: String, arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
    #if DEBUG
      arguments.contains(flag)
    #else
      false
    #endif
  }
}

/// Deliberately unsanitized insertion trace, separate from the normal diagnostic log.
/// Call sites must never pass credentials, audio, or previous clipboard contents.
@MainActor
final class DevelopmentTrace {
  static let shared = DevelopmentTrace()
  private var handle: FileHandle?
  var localTranscriptionSelected = false

  func record(_ message: @autoclosure () -> String) {
    guard DevelopmentDiagnostics.traceEnabled, !localTranscriptionSelected else { return }
    do {
      if handle == nil {
        let directory = FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("Library/Logs/HubrisVoice", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "development-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).log"
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.createFile(
          atPath: url.path,
          contents: nil,
          attributes: [.posixPermissions: 0o600]
        ) else { return }
        handle = try FileHandle(forWritingTo: url)
      }
      let line = "\(Date().ISO8601Format()) [TRACE] \(message())\n"
      try handle?.write(contentsOf: Data(line.utf8))
    } catch {
      reportFailure(error)
    }
  }

  private func reportFailure(_ error: Error) {
    // Report only to stderr; raw trace data never enters the unified log.
    let message = "Development trace write failed: \(error.localizedDescription)\n"
    try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
  }
}
