import CryptoKit
import Foundation

public enum ReleaseToolError: Error, Equatable, LocalizedError, Sendable {
  case message(String)

  public var errorDescription: String? {
    switch self {
    case .message(let message): message
    }
  }
}

public struct ReleaseVersion: Equatable, Sendable {
  public let value: String

  public init?(_ value: String) {
    guard value.wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+/) != nil else {
      return nil
    }
    self.value = value
  }
}

public struct ReleaseSHA: Equatable, Sendable {
  public let value: String

  public init?(_ value: String) {
    guard value.wholeMatch(of: /[0-9a-f]{40}/) != nil else {
      return nil
    }
    self.value = value
  }
}

public struct ReleaseTag: Equatable, Sendable {
  public let value: String

  public init?(_ value: String, version: ReleaseVersion) {
    guard value == "v\(version.value)" else {
      return nil
    }
    self.value = value
  }
}

public struct GitHubRepository: Equatable, Sendable {
  public let value: String

  public init?(_ value: String) {
    guard value.wholeMatch(of: /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/) != nil else {
      return nil
    }
    self.value = value
  }
}

public struct ReleaseEnvironment: Sendable {
  private let values: [String: String]

  public init(_ values: [String: String] = ProcessInfo.processInfo.environment) {
    self.values = values
  }

  public func optional(_ name: String) -> String? {
    guard let value = values[name], !value.isEmpty else {
      return nil
    }
    return value
  }

  public func required(_ name: String) throws -> String {
    guard let value = optional(name) else {
      throw ReleaseToolError.message("\(name) is required")
    }
    return value
  }
}

public struct SourceReleaseConfiguration: Equatable, Sendable {
  public let sha: ReleaseSHA
  public let version: ReleaseVersion

  public init(environment: ReleaseEnvironment) throws {
    let shaValue = try environment.required("RELEASE_SHA")
    let versionValue = try environment.required("RELEASE_VERSION")
    guard let sha = ReleaseSHA(shaValue) else {
      throw ReleaseToolError.message("RELEASE_SHA must be a lowercase 40-character commit SHA")
    }
    guard let version = ReleaseVersion(versionValue) else {
      throw ReleaseToolError.message("Release version must contain three numeric components")
    }
    self.sha = sha
    self.version = version
  }
}

public struct TaggedReleaseConfiguration: Equatable, Sendable {
  public let source: SourceReleaseConfiguration
  public let tag: ReleaseTag

  public init(environment: ReleaseEnvironment) throws {
    let source = try SourceReleaseConfiguration(environment: environment)
    let tagValue = try environment.required("RELEASE_TAG")
    guard let tag = ReleaseTag(tagValue, version: source.version) else {
      throw ReleaseToolError.message("Release tag must equal v\(source.version.value)")
    }
    self.source = source
    self.tag = tag
  }
}

public struct SigningConfiguration: Equatable, Sendable {
  public let teamID: String
  public let p12: Data
  public let password: String
  public let notaryKey: Data
  public let notaryKeyID: String
  public let notaryIssuerID: String

  public init(environment: ReleaseEnvironment) throws {
    let teamID = try environment.required("MACOS_TEAM_ID")
    let p12Value = try environment.required("MACOS_SIGN_P12")
    let password = try environment.required("MACOS_SIGN_PASSWORD")
    let notaryKeyValue = try environment.required("MACOS_NOTARY_KEY")
    let notaryKeyID = try environment.required("MACOS_NOTARY_KEY_ID")
    let notaryIssuerID = try environment.required("MACOS_NOTARY_ISSUER_ID")

    guard teamID.wholeMatch(of: /[A-Z0-9]{10}/) != nil,
          notaryKeyID.wholeMatch(of: /[A-Z0-9]{10}/) != nil,
          notaryIssuerID.wholeMatch(of: /[0-9A-Fa-f-]{36}/) != nil
    else {
      throw ReleaseToolError.message("Apple signing or notarization identifiers are malformed")
    }
    guard let p12 = Data(base64Encoded: p12Value, options: .ignoreUnknownCharacters), !p12.isEmpty else {
      throw ReleaseToolError.message("MACOS_SIGN_P12 is not valid base64 data")
    }
    guard let notaryKey = Data(base64Encoded: notaryKeyValue, options: .ignoreUnknownCharacters),
          !notaryKey.isEmpty
    else {
      throw ReleaseToolError.message("MACOS_NOTARY_KEY is not valid base64 data")
    }

    self.teamID = teamID
    self.p12 = p12
    self.password = password
    self.notaryKey = notaryKey
    self.notaryKeyID = notaryKeyID
    self.notaryIssuerID = notaryIssuerID
  }
}

public enum ReleaseCommand: String, CaseIterable, Sendable {
  case build
  case buildAdhoc = "build-adhoc"
  case generateAppcast = "generate-appcast"
  case publish
  case uploadAssets = "upload-assets"
  case validateDraft = "validate-draft"
  case validateSource = "validate-source"

  public static var usage: String {
    allCases.map(\.rawValue).joined(separator: "|")
  }
}

enum SparkleSigningKey {
  static func publicKey(from encodedPrivateKey: String) throws -> String {
    let key = encodedPrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: key), data.count == 32,
          data.base64EncodedString() == key
    else {
      throw ReleaseToolError.message("Invalid Sparkle Ed25519 private key")
    }
    do {
      return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        .publicKey.rawRepresentation.base64EncodedString()
    } catch {
      throw ReleaseToolError.message("Invalid Sparkle Ed25519 private key")
    }
  }
}
