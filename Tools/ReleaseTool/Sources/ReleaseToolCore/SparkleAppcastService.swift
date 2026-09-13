import Foundation

struct SparkleAppcastService: Sendable {
  let paths: ReleasePaths
  let environment: ReleaseEnvironment
  let runner: any CommandRunning

  func generate() throws {
    try MacOSReleaseService(paths: paths, environment: environment, runner: runner).validateSource()
    let configuration = try TaggedReleaseConfiguration(environment: environment)
    let privateKey = try environment.required("SPARKLE_EDDSA_PRIVATE_KEY")
    guard try SparkleSigningKey.publicKey(from: privateKey) == readPublicKey() else {
      throw ReleaseToolError.message("Sparkle private key does not match the committed public key")
    }

    let prefix = "Hubris-Voice-\(configuration.source.version.value)-macOS-universal"
    let zipName = "\(prefix).zip"
    let sourceZip = paths.distribution.appending(path: zipName)
    guard FileManager.default.fileExists(atPath: sourceZip.path) else {
      throw ReleaseToolError.message("Missing release ZIP \(sourceZip.path)")
    }

    try FileManager.default.createDirectory(at: paths.temporary, withIntermediateDirectories: true)
    let workingDirectory = try ReleaseFiles.makeTemporaryDirectory(inside: paths.temporary, prefix: "appcast")
    defer { try? ReleaseFiles.removeIfPresent(workingDirectory) }
    let workingZip = workingDirectory.appending(path: zipName)
    let appcast = workingDirectory.appending(path: "appcast.xml")
    try ReleaseFiles.copy(sourceZip, to: workingZip)

    try generateFeed(
      at: appcast,
      workingDirectory: workingDirectory,
      privateKey: privateKey,
      configuration: configuration
    )
    try verifyFeed(at: appcast, zip: workingZip, privateKey: privateKey, configuration: configuration)
    try ReleaseFiles.copy(appcast, to: paths.distribution.appending(path: "appcast.xml"))
    try writeChecksums(prefix: prefix)
    print("Generated signed appcast and final checksums")
  }

  private func generateFeed(
    at appcast: URL,
    workingDirectory: URL,
    privateKey: String,
    configuration: TaggedReleaseConfiguration
  ) throws {
    try run(
      paths.sparkleDistribution.appending(path: "bin/generate_appcast").path,
      [
        "--ed-key-file", "-",
        "--download-url-prefix",
        "https://github.com/jimeh/hubris-voice/releases/download/\(configuration.tag.value)/",
        "--link", "https://github.com/jimeh/hubris-voice/releases/tag/\(configuration.tag.value)",
        "--versions", configuration.source.version.value,
        "--maximum-versions", "1",
        "--maximum-deltas", "0",
        "--disable-signing-warning",
        "-o", appcast.path,
        workingDirectory.path,
      ],
      standardInput: Data(privateKey.utf8),
      displayName: "generate_appcast"
    )
  }

  private func verifyFeed(
    at appcast: URL,
    zip: URL,
    privateKey: String,
    configuration: TaggedReleaseConfiguration
  ) throws {
    let keyInput = Data(privateKey.utf8)
    let signUpdate = paths.sparkleDistribution.appending(path: "bin/sign_update").path
    try run(
      signUpdate,
      ["--verify", "--ed-key-file", "-", appcast.path],
      standardInput: keyInput,
      displayName: "sign_update appcast verification"
    )

    let signature = try enclosureSignature(in: appcast)
    guard signature.wholeMatch(of: /[A-Za-z0-9+\/]{86}==/) != nil else {
      throw ReleaseToolError.message("Generated appcast does not contain a signed ZIP enclosure")
    }
    try run(
      signUpdate,
      ["--verify", "--ed-key-file", "-", zip.path, signature],
      standardInput: keyInput,
      displayName: "sign_update ZIP verification"
    )

    let contents = try ReleaseFiles.string(at: appcast)
    let expectedURL =
      "https://github.com/jimeh/hubris-voice/releases/download/\(configuration.tag.value)/\(zip.lastPathComponent)"
    guard contents.contains(expectedURL) else {
      throw ReleaseToolError.message("Generated appcast does not reference the exact release ZIP")
    }
    guard contents.contains("<!-- sparkle-signatures:") else {
      throw ReleaseToolError.message("Generated appcast feed does not contain a Sparkle signature")
    }
  }

  private func enclosureSignature(in appcast: URL) throws -> String {
    let document = try XMLDocument(contentsOf: appcast)
    let nodes = try document.nodes(
      forXPath: "//*[local-name()='enclosure']/@*[local-name()='edSignature']"
    )
    return nodes.first?.stringValue ?? ""
  }

  private func readPublicKey() throws -> String {
    guard FileManager.default.fileExists(atPath: paths.sparklePublicKey.path) else {
      throw ReleaseToolError.message(
        "The production Sparkle public key is missing: \(paths.sparklePublicKey.path)"
      )
    }
    let key = try ReleaseFiles.string(at: paths.sparklePublicKey)
      .components(separatedBy: .whitespacesAndNewlines)
      .joined()
    guard key.wholeMatch(of: /[A-Za-z0-9+\/]{43}=/) != nil,
          Data(base64Encoded: key)?.count == 32
    else {
      throw ReleaseToolError.message("The Sparkle public key must be a canonical 32-byte base64 key")
    }
    return key
  }

  private func writeChecksums(prefix: String) throws {
    let names = ["\(prefix).zip", "\(prefix).dmg", "\(prefix).spdx.json", "appcast.xml"]
    let contents = try names.map { name in
      let checksum = try ReleaseFiles.sha256(paths.distribution.appending(path: name))
      return "\(checksum)  \(name)"
    }.joined(separator: "\n") + "\n"
    try ReleaseFiles.write(
      Data(contents.utf8),
      to: paths.distribution.appending(path: "SHA256SUMS")
    )
  }

  private func run(
    _ executable: String,
    _ arguments: [String],
    standardInput: Data? = nil,
    displayName: String? = nil
  ) throws {
    _ = try runner.run(
      CommandInvocation(
        executable,
        arguments,
        standardInput: standardInput,
        displayName: displayName
      )
    )
  }
}
