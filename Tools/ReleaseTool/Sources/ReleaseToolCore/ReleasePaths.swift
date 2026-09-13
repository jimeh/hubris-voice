import CryptoKit
import Foundation

public struct ReleasePaths: Sendable {
  public let repository: URL
  public let infoPlist: URL
  public let entitlements: URL
  public let sparkleDistribution: URL
  public let sparklePublicKey: URL
  public let distribution: URL
  public let temporary: URL
  public let app: URL

  public init(
    repository: URL,
    environment: ReleaseEnvironment = ReleaseEnvironment()
  ) throws {
    let repository = repository.standardizedFileURL.resolvingSymlinksInPath()
    guard FileManager.default.fileExists(atPath: repository.appending(path: "Package.swift").path),
          FileManager.default.fileExists(atPath: repository.appending(path: "Support/Info.plist").path)
    else {
      throw ReleaseToolError.message("Release tool must run from the Hubris Voice repository root")
    }

    let runnerTemporary = environment.optional("RUNNER_TEMP") ?? "/private/tmp"
    self.repository = repository
    infoPlist = repository.appending(path: "Support/Info.plist")
    entitlements = repository.appending(path: "Support/HubrisVoice.entitlements")
    sparkleDistribution = repository.appending(path: ".native/sparkle/distribution")
    sparklePublicKey = URL(
      fileURLWithPath: environment.optional("SPARKLE_PUBLIC_KEY_FILE")
        ?? repository.appending(path: "Support/SparklePublicKey").path
    ).standardizedFileURL
    distribution = URL(
      fileURLWithPath: environment.optional("RELEASE_DIST_DIR")
        ?? repository.appending(path: "dist").path
    ).standardizedFileURL
    temporary = URL(
      fileURLWithPath: environment.optional("RELEASE_TEMP_DIR")
        ?? URL(fileURLWithPath: runnerTemporary).appending(path: "hubris-voice-release").path
    ).standardizedFileURL
    app = repository.appending(path: ".build/artifacts/Hubris Voice.app")
  }

  public static func current(environment: ReleaseEnvironment = ReleaseEnvironment()) throws -> ReleasePaths {
    try ReleasePaths(
      repository: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
      environment: environment
    )
  }
}

enum ReleaseFiles {
  static func resetDirectory(_ directory: URL, repository: URL) throws {
    let target = directory.standardizedFileURL.resolvingSymlinksInPath()
    let repository = repository.standardizedFileURL.resolvingSymlinksInPath()
    let forbidden = Set([
      "/", "/Users", "/private", "/private/tmp", "/tmp",
      repository.path, repository.deletingLastPathComponent().path,
    ])
    guard !forbidden.contains(target.path), target.path.count >= 12 else {
      throw ReleaseToolError.message("Refusing to reset unsafe directory: \(target.path)")
    }
    try removeIfPresent(target)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
  }

  static func removeIfPresent(_ target: URL) throws {
    do {
      try FileManager.default.removeItem(at: target)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
  }

  static func copy(_ source: URL, to destination: URL) throws {
    try removeIfPresent(destination)
    try FileManager.default.copyItem(at: source, to: destination)
  }

  static func write(_ data: Data, to destination: URL, permissions: Int? = nil) throws {
    try data.write(to: destination, options: .atomic)
    if let permissions {
      try FileManager.default.setAttributes(
        [.posixPermissions: permissions],
        ofItemAtPath: destination.path
      )
    }
  }

  static func string(at source: URL) throws -> String {
    try String(contentsOf: source, encoding: .utf8)
  }

  static func sha256(_ source: URL) throws -> String {
    let digest = try SHA256.hash(data: Data(contentsOf: source))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func makeTemporaryDirectory(inside parent: URL, prefix: String) throws -> URL {
    let directory = parent.appending(path: "\(prefix).\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

extension String {
  var trimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
