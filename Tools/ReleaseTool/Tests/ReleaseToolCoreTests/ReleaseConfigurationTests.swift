import Foundation
@testable import ReleaseToolCore
import XCTest

final class ReleaseConfigurationTests: XCTestCase {
  func testSigningConfigurationRejectsMissingP12BeforeBuildWork() throws {
    let fixture = try RepositoryFixture()
    defer { fixture.cleanup() }
    let sha = "7483e436c9d1512c3fe66c143bd3bda38a5d8aea"
    let environment = ReleaseEnvironment([
      "MACOS_TEAM_ID": "5HX66GF82Z",
      "RELEASE_SHA": sha,
      "RELEASE_VERSION": "0.1.0",
    ])
    let runner = RecordingRunner(outputs: ["git": CommandOutput(standardOutput: "\(sha)\n")])
    let paths = try ReleasePaths(repository: fixture.root, environment: environment)
    let service = MacOSReleaseService(paths: paths, environment: environment, runner: runner)

    XCTAssertThrowsError(try service.buildRelease()) { error in
      XCTAssertEqual(error as? ReleaseToolError, .message("MACOS_SIGN_P12 is required"))
    }
    XCTAssertEqual(runner.executables, ["git"])
  }

  func testSigningConfigurationDecodesCredentialFiles() throws {
    let environment = ReleaseEnvironment([
      "MACOS_NOTARY_ISSUER_ID": "05f4dda7-88b8-4dd1-baf4-efcc382b5890",
      "MACOS_NOTARY_KEY": Data("notary".utf8).base64EncodedString(),
      "MACOS_NOTARY_KEY_ID": "Y36T77AF9B",
      "MACOS_SIGN_P12": Data("certificate".utf8).base64EncodedString(),
      "MACOS_SIGN_PASSWORD": "password",
      "MACOS_TEAM_ID": "5HX66GF82Z",
    ])

    let configuration = try SigningConfiguration(environment: environment)

    XCTAssertEqual(configuration.p12, Data("certificate".utf8))
    XCTAssertEqual(configuration.notaryKey, Data("notary".utf8))
  }

  func testGitHubMetadataDecodesSnakeCaseAPIFields() throws {
    let data = Data(
      """
      {
        "id": 42,
        "draft": true,
        "tag_name": "v0.1.0",
        "assets": [
          {"name": "appcast.xml", "digest": "sha256:abc"}
        ]
      }
      """.utf8
    )

    let release = try JSONDecoder().decode(GitHubReleaseMetadata.self, from: data)

    XCTAssertEqual(release.databaseID, 42)
    XCTAssertTrue(release.draft)
    XCTAssertEqual(release.tagName, "v0.1.0")
    XCTAssertEqual(release.assets, [GitHubReleaseAsset(name: "appcast.xml", digest: "sha256:abc")])
  }

  func testDraftValidationResolvesTheReleaseIDBeforeUsingTheRESTAPI() throws {
    let fixture = try RepositoryFixture()
    defer { fixture.cleanup() }
    let sha = "7483e436c9d1512c3fe66c143bd3bda38a5d8aea"
    let environment = ReleaseEnvironment([
      "GH_TOKEN": "test-token",
      "GITHUB_REPOSITORY": "jimeh/hubris-voice",
      "RELEASE_SHA": sha,
      "RELEASE_TAG": "v0.1.0",
      "RELEASE_VERSION": "0.1.0",
    ])
    let runner = RecordingRunner { invocation in
      switch (invocation.executable, invocation.arguments.first) {
      case ("git", _):
        CommandOutput(standardOutput: "\(sha)\n")
      case ("gh", "release"):
        CommandOutput(standardOutput: "{\"databaseId\":42}\n")
      case ("gh", "api"):
        CommandOutput(
          standardOutput: "{\"id\":42,\"draft\":true,\"tag_name\":\"v0.1.0\",\"assets\":[]}\n"
        )
      default:
        throw ReleaseToolError.message("Unexpected command \(invocation.executable)")
      }
    }
    let paths = try ReleasePaths(repository: fixture.root, environment: environment)
    let service = GitHubReleaseService(paths: paths, environment: environment, runner: runner)

    try service.validateDraft()

    let apiInvocation = try XCTUnwrap(
      runner.invocations.first { $0.executable == "gh" && $0.arguments.first == "api" }
    )
    XCTAssertEqual(apiInvocation.arguments, ["api", "repos/jimeh/hubris-voice/releases/42"])
    XCTAssertFalse(apiInvocation.arguments.joined(separator: " ").contains("/releases/tags/"))
  }

  func testUploadRejectsMissingAssetsWithTheReleaseDiagnostic() throws {
    let fixture = try RepositoryFixture()
    defer { fixture.cleanup() }
    let sha = "7483e436c9d1512c3fe66c143bd3bda38a5d8aea"
    let environment = ReleaseEnvironment([
      "GH_TOKEN": "test-token",
      "GITHUB_REPOSITORY": "jimeh/hubris-voice",
      "RELEASE_DIST_DIR": fixture.root.appending(path: "dist").path,
      "RELEASE_SHA": sha,
      "RELEASE_TAG": "v0.1.0",
      "RELEASE_VERSION": "0.1.0",
    ])
    let runner = draftReleaseRunner(sha: sha)
    let paths = try ReleasePaths(repository: fixture.root, environment: environment)
    let service = GitHubReleaseService(paths: paths, environment: environment, runner: runner)

    XCTAssertThrowsError(try service.uploadAssets()) { error in
      XCTAssertEqual(
        error as? ReleaseToolError,
        .message("Missing or empty release asset Hubris-Voice-0.1.0-macOS-universal.zip")
      )
    }
    XCTAssertFalse(runner.invocations.contains { invocation in
      invocation.executable == "gh" && invocation.arguments.prefix(2) == ["release", "upload"]
    })
  }

  func testKeychainPreparationFailureRestoresUserStateAndRemovesCredentials() throws {
    let fixture = try RepositoryFixture()
    defer { fixture.cleanup() }
    let temporary = fixture.root.appending(path: "release-temporary")
    let environment = ReleaseEnvironment([
      "MACOS_NOTARY_ISSUER_ID": "05f4dda7-88b8-4dd1-baf4-efcc382b5890",
      "MACOS_NOTARY_KEY": Data("notary".utf8).base64EncodedString(),
      "MACOS_NOTARY_KEY_ID": "Y36T77AF9B",
      "MACOS_SIGN_P12": Data("certificate".utf8).base64EncodedString(),
      "MACOS_SIGN_PASSWORD": "password",
      "MACOS_TEAM_ID": "5HX66GF82Z",
      "RELEASE_TEMP_DIR": temporary.path,
    ])
    let runner = RecordingRunner { invocation in
      if invocation.arguments.prefix(3) == ["default-keychain", "-d", "user"] {
        return CommandOutput(standardOutput: "\"/Users/test/Library/Keychains/login.keychain-db\"\n")
      }
      if invocation.arguments.prefix(3) == ["list-keychains", "-d", "user"] {
        return CommandOutput(
          standardOutput: "\"/Users/test/Library/Keychains/login.keychain-db\"\n\"/Library/Keychains/System.keychain\"\n"
        )
      }
      if invocation.arguments.first == "find-identity" {
        return CommandOutput(standardOutput: "0 valid identities found\n")
      }
      return CommandOutput()
    }
    let paths = try ReleasePaths(repository: fixture.root, environment: environment)
    let configuration = try SigningConfiguration(environment: environment)

    XCTAssertThrowsError(
      try ReleaseKeychain.prepare(paths: paths, configuration: configuration, runner: runner)
    )

    XCTAssertTrue(runner.invocations.contains { invocation in
      invocation.arguments == [
        "default-keychain", "-d", "user", "-s",
        "/Users/test/Library/Keychains/login.keychain-db",
      ]
    })
    XCTAssertTrue(runner.invocations.contains { invocation in
      invocation.arguments == [
        "list-keychains", "-d", "user", "-s",
        "/Users/test/Library/Keychains/login.keychain-db",
        "/Library/Keychains/System.keychain",
      ]
    })
    XCTAssertTrue(runner.invocations.contains { invocation in
      invocation.arguments == ["delete-keychain", temporary.appending(path: "release.keychain-db").path]
    })
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: temporary.appending(path: "credentials").path)
    )
  }

  func testDerivesSparklePublicKey() throws {
    let privateKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    XCTAssertEqual(
      try SparkleSigningKey.publicKey(from: privateKey),
      "O2onvM62pC1io6jQKm8Nc2UyFXcd4kOmOsBIoYtZ2ik="
    )
  }

  func testSelectsTheOnlyDeveloperIDForTheConfiguredTeam() throws {
    let output = """
      1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Example (5HX66GF82Z)"
      2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Apple Development: Example (5HX66GF82Z)"
      2 valid identities found
    """

    XCTAssertEqual(
      try SigningIdentityParser.developerID(in: output, teamID: "5HX66GF82Z"),
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    )
  }

  func testRejectsAmbiguousDeveloperIDs() {
    let output = """
      1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: One (5HX66GF82Z)"
      2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Two (5HX66GF82Z)"
    """

    XCTAssertThrowsError(
      try SigningIdentityParser.developerID(in: output, teamID: "5HX66GF82Z")
    )
  }

  private func draftReleaseRunner(sha: String) -> RecordingRunner {
    RecordingRunner { invocation in
      switch (invocation.executable, invocation.arguments.first) {
      case ("git", _):
        CommandOutput(standardOutput: "\(sha)\n")
      case ("gh", "release"):
        CommandOutput(standardOutput: "{\"databaseId\":42}\n")
      case ("gh", "api"):
        CommandOutput(
          standardOutput: "{\"id\":42,\"draft\":true,\"tag_name\":\"v0.1.0\",\"assets\":[]}\n"
        )
      default:
        throw ReleaseToolError.message("Unexpected command \(invocation.executable)")
      }
    }
  }
}

private final class RecordingRunner: CommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private let handler: @Sendable (CommandInvocation) throws -> CommandOutput
  private var recordedInvocations: [CommandInvocation] = []

  init(outputs: [String: CommandOutput]) {
    handler = { invocation in outputs[invocation.executable] ?? CommandOutput() }
  }

  init(handler: @escaping @Sendable (CommandInvocation) throws -> CommandOutput) {
    self.handler = handler
  }

  var executables: [String] {
    invocations.map(\.executable)
  }

  var invocations: [CommandInvocation] {
    lock.withLock { recordedInvocations }
  }

  func run(_ invocation: CommandInvocation) throws -> CommandOutput {
    lock.withLock { recordedInvocations.append(invocation) }
    return try handler(invocation)
  }
}

private final class RepositoryFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "hubris-release-tool-tests-\(UUID().uuidString)")
    let support = root.appending(path: "Support")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try Data("// fixture\n".utf8).write(to: root.appending(path: "Package.swift"))
    let plist: [String: Any] = [
      "CFBundleShortVersionString": "0.1.0",
      "CFBundleVersion": "0.1.0",
    ]
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    try plistData.write(to: support.appending(path: "Info.plist"))
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}
