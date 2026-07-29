import Foundation
import Security

struct KeychainStore: Sendable {
  enum StoreError: Error, LocalizedError {
    case unexpectedData
    case status(OSStatus)

    var errorDescription: String? {
      switch self {
      case .unexpectedData:
        return "The API key in Keychain is not valid UTF-8."
      case .status(let status):
        if let message = SecCopyErrorMessageString(status, nil) {
          return message as String
        }
        return "Keychain returned status \(status)."
      }
    }
  }

  private let service = "com.jimeh.HubrisVoice"
  private let account = "openai-api-key"

  func readAPIKey() throws -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw StoreError.status(status)
    }
    guard
      let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      throw StoreError.unexpectedData
    }
    return value
  }

  func writeAPIKey(_ apiKey: String) throws {
    let data = Data(apiKey.utf8)
    let updateStatus = SecItemUpdate(
      baseQuery as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )

    if updateStatus == errSecItemNotFound {
      var query = baseQuery
      query[kSecValueData as String] = data
      let addStatus = SecItemAdd(query as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw StoreError.status(addStatus)
      }
      return
    }

    guard updateStatus == errSecSuccess else {
      throw StoreError.status(updateStatus)
    }
  }

  func deleteAPIKey() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw StoreError.status(status)
    }
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
  }
}
