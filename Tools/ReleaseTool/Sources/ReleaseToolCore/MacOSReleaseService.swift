import Foundation

public struct MacOSReleaseService: Sendable {
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

  public func validateSource() throws {
    let configuration = try SourceReleaseConfiguration(environment: environment)
    let actualSHA = try capture("git", ["rev-parse", "HEAD"]).trimmed
    guard actualSHA == configuration.sha.value else {
      throw ReleaseToolError.message(
        "Checked-out SHA \(actualSHA) does not match \(configuration.sha.value)"
      )
    }

    let plist = try readPropertyList(paths.infoPlist)
    let shortVersion = plist["CFBundleShortVersionString"] as? String
    let bundleVersion = plist["CFBundleVersion"] as? String
    guard shortVersion == configuration.version.value, bundleVersion == configuration.version.value else {
      throw ReleaseToolError.message("Info.plist versions must both equal \(configuration.version.value)")
    }
  }

  public func buildAdhoc() throws {
    try validateSource()
    try prepareSparkle()
    let publicKey = try readPublicKey()
    try ReleaseFiles.resetDirectory(paths.temporary, repository: paths.repository)
    try prepareApp(publicKey: publicKey)
    try adhocSignApp()
    print("Built and verified universal ad-hoc Sparkle bundle at \(paths.app.path)")
  }

  public func buildRelease() throws {
    try validateSource()

    // Resolve every credential before doing network work or compiling either architecture.
    let signing = try SigningConfiguration(environment: environment)
    try prepareSparkle()
    let publicKey = try readPublicKey()
    let source = try SourceReleaseConfiguration(environment: environment)
    let prefix = assetPrefix(version: source.version)
    let notarizationZip = paths.temporary.appending(path: "notarization.zip")
    let finalZip = paths.distribution.appending(path: "\(prefix).zip")
    let finalDMG = paths.distribution.appending(path: "\(prefix).dmg")
    let sbom = paths.distribution.appending(path: "\(prefix).spdx.json")

    try ReleaseFiles.resetDirectory(paths.temporary, repository: paths.repository)
    try ReleaseFiles.resetDirectory(paths.distribution, repository: paths.repository)
    try prepareApp(publicKey: publicKey)

    let keychain = try ReleaseKeychain.prepare(
      paths: paths,
      configuration: signing,
      runner: runner
    )
    defer { keychain.cleanupBestEffort() }

    try signApp(identity: keychain.identity, keychain: keychain.url, teamID: signing.teamID)
    try run(
      "ditto",
      ["-c", "-k", "--sequesterRsrc", "--keepParent", paths.app.path, notarizationZip.path]
    )
    try submitNotarization(notarizationZip, signing: signing)
    try run("xcrun", ["stapler", "staple", paths.app.path])
    try run("xcrun", ["stapler", "validate", paths.app.path])
    try run("codesign", ["--verify", "--deep", "--strict", "--verbose=4", paths.app.path])
    try run("spctl", ["--assess", "--type", "execute", "--verbose=4", paths.app.path])

    try run(
      "ditto",
      ["-c", "-k", "--sequesterRsrc", "--keepParent", paths.app.path, finalZip.path]
    )
    try createDMG(finalDMG, signing: signing, keychain: keychain)
    try run(
      "syft",
      [
        "scan", "dir:\(paths.app.path)",
        "--source-name", "Hubris Voice",
        "--source-version", source.version.value,
        "-o", "spdx-json=\(sbom.path)",
      ]
    )
    try validateSBOM(sbom)
    try run("pyspdxtools", ["-i", sbom.path])
    try writeChecksums(names: ["\(prefix).zip", "\(prefix).dmg", "\(prefix).spdx.json"])
    try keychain.cleanup()
    print("Prepared signed, notarized release assets in \(paths.distribution.path)")
  }

  public func generateAppcast() throws {
    try SparkleAppcastService(paths: paths, environment: environment, runner: runner).generate()
  }

  private func prepareSparkle() throws {
    try run(paths.repository.appending(path: "Scripts/prepare-sparkle.sh").path)
  }

  private func prepareApp(publicKey: String) throws {
    let stageApp = paths.temporary.appending(path: "Hubris Voice.app")
    let arm64Binary = try buildSlice(
      architecture: "arm64",
      triple: "arm64-apple-macosx15.0"
    )
    let x86Binary = try buildSlice(
      architecture: "x86_64",
      triple: "x86_64-apple-macosx15.0"
    )

    try FileManager.default.createDirectory(
      at: stageApp.appending(path: "Contents/MacOS"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: stageApp.appending(path: "Contents/Frameworks"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: stageApp.appending(path: "Contents/Resources"),
      withIntermediateDirectories: true
    )
    try run(
      "lipo",
      [
        "-create", arm64Binary.path, x86Binary.path,
        "-output", stageApp.appending(path: "Contents/MacOS/HubrisVoice").path,
      ]
    )

    try copyResourceBundles(
      from: arm64Binary.deletingLastPathComponent(),
      to: stageApp.appending(path: "Contents/Resources")
    )

    let stagedPlist = stageApp.appending(path: "Contents/Info.plist")
    var plist = try readPropertyList(paths.infoPlist)
    plist["SUFeedURL"] = "https://github.com/jimeh/hubris-voice/releases/latest/download/appcast.xml"
    plist["SUPublicEDKey"] = publicKey
    plist["SURequireSignedFeed"] = true
    plist["SUVerifyUpdateBeforeExtraction"] = true
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    try ReleaseFiles.write(plistData, to: stagedPlist)

    let framework = stageApp.appending(path: "Contents/Frameworks/Sparkle.framework")
    try run(
      "ditto",
      [paths.sparkleDistribution.appending(path: "Sparkle.framework").path, framework.path]
    )
    try ReleaseFiles.removeIfPresent(framework.appending(path: "XPCServices"))
    try ReleaseFiles.removeIfPresent(framework.appending(path: "Versions/B/XPCServices"))
    try ReleaseFiles.copy(
      paths.repository.appending(path: "third-party/sparkle/LICENSE"),
      to: stageApp.appending(path: "Contents/Resources/Sparkle-LICENSE")
    )

    let executable = stageApp.appending(path: "Contents/MacOS/HubrisVoice")
    try run("lipo", [executable.path, "-verify_arch", "arm64"])
    try run("lipo", [executable.path, "-verify_arch", "x86_64"])
    let linkedLibraries = try capture("otool", ["-L", executable.path])
    guard linkedLibraries.contains("@rpath/Sparkle.framework/Versions/B/Sparkle") else {
      throw ReleaseToolError.message("Release executable does not link the packaged Sparkle framework")
    }

    try FileManager.default.createDirectory(
      at: paths.app.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try ReleaseFiles.removeIfPresent(paths.app)
    try FileManager.default.moveItem(at: stageApp, to: paths.app)
  }

  private func copyResourceBundles(from binaryDirectory: URL, to resourcesDirectory: URL) throws {
    let resourceBundles = try FileManager.default.contentsOfDirectory(
      at: binaryDirectory,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "bundle" }
    for resourceBundle in resourceBundles {
      try ReleaseFiles.copy(
        resourceBundle,
        to: resourcesDirectory.appending(path: resourceBundle.lastPathComponent)
      )
    }
  }

  private func buildSlice(architecture: String, triple: String) throws -> URL {
    let scratch = paths.temporary.appending(path: "build-\(architecture)")
    let arguments = swiftBuildArguments(scratch: scratch, triple: triple)
    try run("swift", ["build"] + arguments)
    let binaryDirectory = try capture("swift", ["build"] + arguments + ["--show-bin-path"]).trimmed
    let executable = URL(fileURLWithPath: binaryDirectory).appending(path: "HubrisVoice")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw ReleaseToolError.message("SwiftPM did not produce the \(architecture) executable")
    }
    return executable
  }

  private func swiftBuildArguments(scratch: URL, triple: String) -> [String] {
    [
      "--configuration", "release",
      "--product", "HubrisVoice",
      "--scratch-path", scratch.path,
      "--triple", triple,
      "-Xswiftc", "-DHUBRIS_VOICE_SPARKLE",
      "-Xswiftc", "-F\(paths.sparkleDistribution.path)",
      "-Xlinker", "-F\(paths.sparkleDistribution.path)",
      "-Xlinker", "-rpath",
      "-Xlinker", "@executable_path/../Frameworks",
      "-Xlinker", "-framework",
      "-Xlinker", "Sparkle",
    ]
  }

  private func signApp(identity: String, keychain: URL, teamID: String) throws {
    let sparkle = paths.app.appending(path: "Contents/Frameworks/Sparkle.framework/Versions/B")
    let targets: [(URL, Bool)] = [
      (sparkle.appending(path: "Autoupdate"), false),
      (sparkle.appending(path: "Updater.app/Contents/MacOS/Updater"), false),
      (sparkle.appending(path: "Updater.app"), false),
      (sparkle.appending(path: "Sparkle"), false),
      (paths.app.appending(path: "Contents/Frameworks/Sparkle.framework"), false),
      (paths.app.appending(path: "Contents/MacOS/HubrisVoice"), true),
      (paths.app, true),
    ]
    for (target, includeEntitlements) in targets {
      try signTarget(
        target,
        identity: identity,
        keychain: keychain,
        includeEntitlements: includeEntitlements
      )
    }
    try run("codesign", ["--verify", "--deep", "--strict", "--verbose=4", paths.app.path])
    for (target, _) in targets {
      try verifySignature(target, teamID: teamID, requireRuntime: true)
    }
  }

  private func adhocSignApp() throws {
    let sparkle = paths.app.appending(path: "Contents/Frameworks/Sparkle.framework/Versions/B")
    let targets = [
      sparkle.appending(path: "Autoupdate"),
      sparkle.appending(path: "Updater.app/Contents/MacOS/Updater"),
      sparkle.appending(path: "Updater.app"),
      sparkle.appending(path: "Sparkle"),
      paths.app.appending(path: "Contents/Frameworks/Sparkle.framework"),
      paths.app.appending(path: "Contents/MacOS/HubrisVoice"),
      paths.app,
    ]
    for target in targets {
      try run("codesign", ["--force", "--sign", "-", target.path])
    }
    try run("codesign", ["--verify", "--deep", "--strict", "--verbose=4", paths.app.path])
  }

  private func signTarget(
    _ target: URL,
    identity: String,
    keychain: URL,
    includeEntitlements: Bool
  ) throws {
    var arguments = [
      "--force", "--sign", identity,
      "--keychain", keychain.path,
      "--options", "runtime",
      "--timestamp",
    ]
    if includeEntitlements {
      arguments += ["--entitlements", paths.entitlements.path]
    }
    arguments.append(target.path)
    try run("codesign", arguments, displayName: "codesign \(target.lastPathComponent)")
  }

  private func verifySignature(_ target: URL, teamID: String, requireRuntime: Bool) throws {
    try run("codesign", ["--verify", "--strict", "--verbose=2", target.path])
    let result = try runner.run(
      CommandInvocation(
        "codesign",
        ["-dvvv", target.path],
        outputMode: .captured,
        displayName: "codesign inspection"
      )
    )
    let details = result.standardOutput + result.standardError
    guard !details.contains("Signature=adhoc"),
          details.contains("Authority=Developer ID Application:"),
          details.contains("TeamIdentifier=\(teamID)"),
          details.contains("Timestamp="),
          !details.contains("Timestamp=none")
    else {
      throw ReleaseToolError.message("Developer ID signature verification failed for \(target.path)")
    }
    if requireRuntime, !details.contains("runtime") {
      throw ReleaseToolError.message("Hardened runtime is missing from \(target.path)")
    }
  }

  private func submitNotarization(_ submission: URL, signing: SigningConfiguration) throws {
    let result = try capture(
      "xcrun",
      [
        "notarytool", "submit", submission.path,
        "--wait",
        "--output-format", "json",
        "--key", paths.temporary.appending(path: "credentials/notary-key.p8").path,
        "--key-id", signing.notaryKeyID,
        "--issuer", signing.notaryIssuerID,
      ],
      displayName: "notarytool submit"
    )
    let response: NotaryResponse
    do {
      response = try JSONDecoder().decode(NotaryResponse.self, from: Data(result.utf8))
    } catch {
      throw ReleaseToolError.message("Could not decode notarytool response: \(error.localizedDescription)")
    }
    guard response.status == "Accepted" else {
      throw ReleaseToolError.message("Apple notarization finished with status \(response.status)")
    }
  }

  private func createDMG(
    _ destination: URL,
    signing: SigningConfiguration,
    keychain: ReleaseKeychain
  ) throws {
    let stage = paths.temporary.appending(path: "dmg")
    try ReleaseFiles.resetDirectory(stage, repository: paths.repository)
    try run("ditto", [paths.app.path, stage.appending(path: "Hubris Voice.app").path])
    try FileManager.default.createSymbolicLink(
      at: stage.appending(path: "Applications"),
      withDestinationURL: URL(fileURLWithPath: "/Applications")
    )
    try run(
      "hdiutil",
      [
        "create", "-fs", "HFS+", "-format", "UDZO",
        "-volname", "Hubris Voice", "-srcfolder", stage.path, destination.path,
      ]
    )
    try signTarget(destination, identity: keychain.identity, keychain: keychain.url, includeEntitlements: false)
    try verifySignature(destination, teamID: signing.teamID, requireRuntime: false)
    try submitNotarization(destination, signing: signing)
    try run("xcrun", ["stapler", "staple", destination.path])
    try run("xcrun", ["stapler", "validate", destination.path])
    try run(
      "spctl",
      ["--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=4", destination.path]
    )
  }

  private func validateSBOM(_ source: URL) throws {
    let document: SPDXDocument
    do {
      document = try JSONDecoder().decode(SPDXDocument.self, from: Data(contentsOf: source))
    } catch {
      throw ReleaseToolError.message("Could not decode generated SPDX SBOM: \(error.localizedDescription)")
    }
    guard document.spdxVersion == "SPDX-2.3", !document.packages.isEmpty else {
      throw ReleaseToolError.message("Generated SPDX SBOM is empty or has the wrong schema version")
    }
  }

  private func writeChecksums(names: [String]) throws {
    let contents = try names.map { name in
      let checksum = try ReleaseFiles.sha256(paths.distribution.appending(path: name))
      return "\(checksum)  \(name)"
    }.joined(separator: "\n") + "\n"
    try ReleaseFiles.write(
      Data(contents.utf8),
      to: paths.distribution.appending(path: "SHA256SUMS")
    )
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

  private func readPropertyList(_ source: URL) throws -> [String: Any] {
    let value = try PropertyListSerialization.propertyList(
      from: Data(contentsOf: source),
      options: [],
      format: nil
    )
    guard let dictionary = value as? [String: Any] else {
      throw ReleaseToolError.message("Property list is not a dictionary: \(source.path)")
    }
    return dictionary
  }

  private func assetPrefix(version: ReleaseVersion) -> String {
    "Hubris-Voice-\(version.value)-macOS-universal"
  }

  private func run(
    _ executable: String,
    _ arguments: [String] = [],
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

  private func capture(
    _ executable: String,
    _ arguments: [String] = [],
    displayName: String? = nil
  ) throws -> String {
    try runner.run(
      CommandInvocation(
        executable,
        arguments,
        outputMode: .captured,
        displayName: displayName
      )
    ).standardOutput
  }
}

private struct NotaryResponse: Decodable {
  let status: String
}

private struct SPDXDocument: Decodable {
  let spdxVersion: String
  let packages: [SPDXPackage]
}

private struct SPDXPackage: Decodable {}
