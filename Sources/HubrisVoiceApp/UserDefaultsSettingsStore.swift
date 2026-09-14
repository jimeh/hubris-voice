import Foundation
import HubrisVoiceCore

/// UserDefaults synchronizes its own access. The wrapper owns no other mutable state.
final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
  private let defaults: UserDefaults

  init(_ defaults: UserDefaults) {
    self.defaults = defaults
  }

  func contains(_ key: String) -> Bool {
    defaults.object(forKey: key) != nil
  }

  func string(_ key: String) -> String? {
    defaults.string(forKey: key)
  }

  func stringArray(_ key: String) -> [String]? {
    defaults.stringArray(forKey: key)
  }

  func bool(_ key: String) -> Bool? {
    defaults.object(forKey: key) as? Bool
  }

  func integer(_ key: String) -> Int? {
    defaults.object(forKey: key) as? Int
  }

  func set(_ value: Any?, for key: String) {
    defaults.set(value, forKey: key)
  }
}
