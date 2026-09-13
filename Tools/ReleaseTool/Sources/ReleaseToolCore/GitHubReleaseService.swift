import Foundation

public struct GitHubReleaseService: Sendable {
  private let paths: ReleasePaths
  private let environment: ReleaseEnvironment
  private let runner: any CommandRunning

  public init(
    paths: ReleasePaths,
    environment: ReleaseEnvironment = ReleaseEnvironment(),
    runner: any CommandRunning = SystemCommandRunner()
  ) {
    self.paths = paths
    self.environment = environment
    self.runner = runner
  }

  public func validateDraft() throws {
    _ = try loadDraft()
  }

  public func uploadAssets() throws {
    let context = try context()
    let release = try loadDraft(context: context)
    try validateInventory(release: release, allowMissing: true, version: context.release.source.version)

    let assets = expectedAssetNames(version: context.release.source.version)
    let files = try assets.map { name -> URL in
      let file = paths.distribution.appending(path: name)
      guard FileManager.default.fileExists(atPath: file.path) else {
        throw ReleaseToolError.message("Missing or empty release asset \(name)")
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      guard let size = attributes[.size] as? NSNumber, size.intValue > 0 else {
        throw ReleaseToolError.message("Missing or empty release asset \(name)")
      }
      return file
    }
    try run(
      "gh",
      ["release", "upload", context.release.tag.value]
        + files.map(\.path)
        + ["--clobber", "--repo", context.repository.value]
    )

    let uploaded = try fetchRelease(releaseID: release.databaseID, repository: context.repository)
    try validateInventory(release: uploaded, allowMissing: false, version: context.release.source.version)
    for name in assets {
      let expected = try "sha256:\(ReleaseFiles.sha256(paths.distribution.appending(path: name)))"
      let remote = uploaded.assets.first(where: { $0.name == name })?.digest
      guard remote == expected else {
        throw ReleaseToolError.message("Remote digest for \(name) does not match the local asset")
      }
    }
    print("Uploaded and verified release assets for \(context.release.tag.value)")
  }

  public func publish() throws {
    let context = try context()
    let release = try loadDraft(context: context)
    try validateInventory(release: release, allowMissing: false, version: context.release.source.version)
    try run(
      "gh",
      [
        "release", "edit", context.release.tag.value,
        "--draft=false", "--latest", "--repo", context.repository.value,
      ]
    )
    let published = try fetchRelease(releaseID: release.databaseID, repository: context.repository)
    guard !published.draft else {
      throw ReleaseToolError.message("Release \(context.release.tag.value) remained a draft")
    }
    print("Published \(context.release.tag.value)")
  }

  public func expectedAssetNames(version: ReleaseVersion) -> [String] {
    let prefix = "Hubris-Voice-\(version.value)-macOS-universal"
    return [
      "\(prefix).zip",
      "\(prefix).dmg",
      "\(prefix).spdx.json",
      "appcast.xml",
      "SHA256SUMS",
    ]
  }

  private func context() throws -> GitHubReleaseContext {
    let release = try TaggedReleaseConfiguration(environment: environment)
    let repositoryValue = try environment.required("GITHUB_REPOSITORY")
    guard let repository = GitHubRepository(repositoryValue) else {
      throw ReleaseToolError.message("GITHUB_REPOSITORY is malformed")
    }
    _ = try environment.required("GH_TOKEN")
    return GitHubReleaseContext(release: release, repository: repository)
  }

  private func loadDraft() throws -> GitHubReleaseMetadata {
    try loadDraft(context: context())
  }

  private func loadDraft(context: GitHubReleaseContext) throws -> GitHubReleaseMetadata {
    let tagSHA = try capture("git", ["rev-list", "-n", "1", context.release.tag.value]).trimmed
    guard tagSHA == context.release.source.sha.value else {
      throw ReleaseToolError.message(
        "Tag \(context.release.tag.value) resolves to \(tagSHA), expected \(context.release.source.sha.value)"
      )
    }

    let identifierData = try capture(
      "gh",
      [
        "release", "view", context.release.tag.value,
        "--repo", context.repository.value,
        "--json", "databaseId",
      ]
    )
    let identifier: GitHubReleaseIdentifier = try decode(
      identifierData,
      description: "GitHub release identifier"
    )
    let release = try fetchRelease(releaseID: identifier.databaseID, repository: context.repository)
    guard release.draft, release.tagName == context.release.tag.value else {
      throw ReleaseToolError.message(
        "Release \(context.release.tag.value) must be the exact draft target"
      )
    }
    return release
  }

  private func fetchRelease(releaseID: Int, repository: GitHubRepository) throws -> GitHubReleaseMetadata {
    let data = try capture("gh", ["api", "repos/\(repository.value)/releases/\(releaseID)"])
    return try decode(data, description: "GitHub release metadata")
  }

  private func validateInventory(
    release: GitHubReleaseMetadata,
    allowMissing: Bool,
    version: ReleaseVersion
  ) throws {
    let expected = Set(expectedAssetNames(version: version))
    let actual = Set(release.assets.map(\.name))
    if allowMissing {
      guard actual.isSubset(of: expected) else {
        let unexpected = actual.subtracting(expected).sorted().joined(separator: ", ")
        throw ReleaseToolError.message("Draft release contains unexpected assets: \(unexpected)")
      }
    } else if actual != expected {
      throw ReleaseToolError.message("Draft release asset inventory does not match the expected set")
    }
  }

  private func decode<Value: Decodable>(_ source: String, description: String) throws -> Value {
    do {
      return try JSONDecoder().decode(Value.self, from: Data(source.utf8))
    } catch {
      throw ReleaseToolError.message("Could not decode \(description): \(error.localizedDescription)")
    }
  }

  private func run(_ executable: String, _ arguments: [String]) throws {
    _ = try runner.run(CommandInvocation(executable, arguments))
  }

  private func capture(_ executable: String, _ arguments: [String]) throws -> String {
    try runner.run(
      CommandInvocation(executable, arguments, outputMode: .captured)
    ).standardOutput
  }
}

private struct GitHubReleaseContext: Sendable {
  let release: TaggedReleaseConfiguration
  let repository: GitHubRepository
}

struct GitHubReleaseIdentifier: Decodable, Equatable, Sendable {
  let databaseID: Int

  private enum CodingKeys: String, CodingKey {
    case databaseID = "databaseId"
  }
}

struct GitHubReleaseMetadata: Decodable, Equatable, Sendable {
  let databaseID: Int
  let draft: Bool
  let tagName: String
  let assets: [GitHubReleaseAsset]

  private enum CodingKeys: String, CodingKey {
    case databaseID = "id"
    case draft
    case tagName = "tag_name"
    case assets
  }
}

struct GitHubReleaseAsset: Decodable, Equatable, Sendable {
  let name: String
  let digest: String?
}
