#!/usr/bin/env swift

import CryptoKit
import Foundation

let encodedPrivateKey = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
  .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

guard
  let privateKeyData = Data(base64Encoded: encodedPrivateKey),
  privateKeyData.count == 32,
  privateKeyData.base64EncodedString() == encodedPrivateKey,
  let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
else {
  FileHandle.standardError.write(Data("Invalid Sparkle Ed25519 private key\n".utf8))
  exit(1)
}

print(privateKey.publicKey.rawRepresentation.base64EncodedString())
