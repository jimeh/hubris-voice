import Foundation

final class ReleaseKeychain: @unchecked Sendable {
  let url: URL
  let identity: String

  private let originalDefault: String
  private let originalSearchList: [String]
  private let runner: any CommandRunning
  private var cleanedUp = false

  private init(
    url: URL,
    identity: String,
    originalDefault: String,
    originalSearchList: [String],
    runner: any CommandRunning
  ) {
    self.url = url
    self.identity = identity
    self.originalDefault = originalDefault
    self.originalSearchList = originalSearchList
    self.runner = runner
  }

  static func prepare(
    paths: ReleasePaths,
    configuration: SigningConfiguration,
    runner: any CommandRunning
  ) throws -> ReleaseKeychain {
    let credentials = paths.temporary.appending(path: "credentials")
    let p12 = credentials.appending(path: "developer-id.p12")
    let notaryKey = credentials.appending(path: "notary-key.p8")
    try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
    try ReleaseFiles.write(configuration.p12, to: p12, permissions: 0o600)
    try ReleaseFiles.write(configuration.notaryKey, to: notaryKey, permissions: 0o600)

    let keychain = paths.temporary.appending(path: "release.keychain-db")
    let password = "hubris-voice-\(UUID().uuidString)"
    var originalDefault = ""
    var originalSearchList: [String] = []
    do {
      originalDefault = try runner.run(
        CommandInvocation("security", ["default-keychain", "-d", "user"], outputMode: .captured)
      ).standardOutput.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      let searchOutput = try runner.run(
        CommandInvocation("security", ["list-keychains", "-d", "user"], outputMode: .captured)
      ).standardOutput
      originalSearchList = parseSearchList(searchOutput)

      _ = try runner.run(CommandInvocation("security", ["create-keychain", "-p", password, keychain.path]))
      _ = try runner.run(CommandInvocation("security", ["set-keychain-settings", "-lut", "21600", keychain.path]))
      _ = try runner.run(CommandInvocation("security", ["unlock-keychain", "-p", password, keychain.path]))
      _ = try runner.run(CommandInvocation("security", ["default-keychain", "-d", "user", "-s", keychain.path]))
      _ = try runner.run(CommandInvocation("security", ["list-keychains", "-d", "user", "-s", keychain.path]))
      _ = try runner.run(
        CommandInvocation(
          "security",
          ["import", p12.path, "-k", keychain.path, "-P", configuration.password, "-T", "/usr/bin/codesign"],
          displayName: "security import Developer ID certificate"
        )
      )
      _ = try runner.run(
        CommandInvocation(
          "security",
          [
            "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
            "-s", "-k", password, keychain.path,
          ],
          displayName: "security configure signing key"
        )
      )

      let identities = try runner.run(
        CommandInvocation(
          "security",
          ["find-identity", "-v", "-p", "codesigning", keychain.path],
          outputMode: .captured
        )
      ).standardOutput
      let identity = try SigningIdentityParser.developerID(
        in: identities,
        teamID: configuration.teamID
      )

      return ReleaseKeychain(
        url: keychain,
        identity: identity,
        originalDefault: originalDefault,
        originalSearchList: originalSearchList,
        runner: runner
      )
    } catch {
      _ = cleanupResources(
        originalDefault: originalDefault,
        originalSearchList: originalSearchList,
        keychain: keychain,
        credentials: credentials,
        runner: runner
      )
      throw error
    }
  }

  func cleanup() throws {
    guard !cleanedUp else {
      return
    }
    if let error = Self.cleanupResources(
      originalDefault: originalDefault,
      originalSearchList: originalSearchList,
      keychain: url,
      credentials: url.deletingLastPathComponent().appending(path: "credentials"),
      runner: runner
    ) {
      throw error
    }
    cleanedUp = true
  }

  func cleanupBestEffort() {
    try? cleanup()
  }

  private static func cleanupResources(
    originalDefault: String,
    originalSearchList: [String],
    keychain: URL,
    credentials: URL,
    runner: any CommandRunning
  ) -> Error? {
    var firstError: Error?
    func attempt(_ operation: () throws -> Void) {
      do {
        try operation()
      } catch {
        firstError = firstError ?? error
      }
    }

    if !originalDefault.isEmpty {
      attempt {
        _ = try runner.run(
          CommandInvocation("security", ["default-keychain", "-d", "user", "-s", originalDefault])
        )
      }
    }
    if !originalSearchList.isEmpty {
      attempt {
        _ = try runner.run(
          CommandInvocation("security", ["list-keychains", "-d", "user", "-s"] + originalSearchList)
        )
      }
    }
    attempt {
      _ = try runner.run(CommandInvocation("security", ["delete-keychain", keychain.path]))
    }
    attempt {
      try ReleaseFiles.removeIfPresent(credentials)
    }
    return firstError
  }

  private static func parseSearchList(_ output: String) -> [String] {
    output.split(separator: "\n").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
  }
}

enum SigningIdentityParser {
  static func developerID(in output: String, teamID: String) throws -> String {
    let escapedTeamID = NSRegularExpression.escapedPattern(for: teamID)
    let expression = try NSRegularExpression(
      pattern: "(?m)^[ \\t]*[0-9]+\\)[ \\t]+([0-9A-F]{40}).*Developer ID Application:.*\\(\(escapedTeamID)\\)"
    )
    let range = NSRange(output.startIndex..., in: output)
    let matches = expression.matches(in: output, range: range)
    guard matches.count == 1,
          let match = matches.first,
          let identityRange = Range(match.range(at: 1), in: output)
    else {
      throw ReleaseToolError.message("Expected exactly one Developer ID Application identity for \(teamID)")
    }
    return String(output[identityRange])
  }
}
