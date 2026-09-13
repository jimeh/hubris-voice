import Darwin
import Foundation
import ReleaseToolCore

@main
struct HubrisVoiceReleaseTool {
  static func main() {
    do {
      let arguments = CommandLine.arguments.dropFirst()
      guard arguments.count == 1, let value = arguments.first, let command = ReleaseCommand(rawValue: value) else {
        throw ReleaseToolError.message(
          "Usage: hubris-voice-release {\(ReleaseCommand.usage)}"
        )
      }

      let environment = ReleaseEnvironment()
      let paths = try ReleasePaths.current(environment: environment)
      let macOS = MacOSReleaseService(paths: paths, environment: environment)
      let github = GitHubReleaseService(paths: paths, environment: environment)

      switch command {
      case .build:
        try macOS.buildRelease()
      case .buildAdhoc:
        try macOS.buildAdhoc()
      case .generateAppcast:
        try macOS.generateAppcast()
      case .publish:
        try github.publish()
      case .uploadAssets:
        try github.uploadAssets()
      case .validateDraft:
        try github.validateDraft()
      case .validateSource:
        try macOS.validateSource()
      }
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      FileHandle.standardError.write(Data("\(message)\n".utf8))
      exit(1)
    }
  }
}
