import Foundation

public struct KeyModifiers: OptionSet, Equatable, Sendable {
  public let rawValue: UInt

  public init(rawValue: UInt) {
    self.rawValue = rawValue
  }

  public static let control = KeyModifiers(rawValue: 1 << 0)
  public static let shift = KeyModifiers(rawValue: 1 << 1)
  public static let command = KeyModifiers(rawValue: 1 << 2)
  public static let option = KeyModifiers(rawValue: 1 << 3)
}

public struct GlobalShortcut: Equatable, Sendable {
  private static let significantModifiers: KeyModifiers = [
    .control,
    .shift,
    .command,
    .option,
  ]

  public static let pushToTalkDefault = GlobalShortcut(
    keyCode: 49,
    modifiers: [.control, .shift]
  )

  public let keyCode: UInt16
  public let modifiers: KeyModifiers

  public init(keyCode: UInt16, modifiers: KeyModifiers) {
    self.keyCode = keyCode
    self.modifiers = modifiers
  }

  public func matches(keyCode: UInt16, modifiers: KeyModifiers) -> Bool {
    self.keyCode == keyCode
      && modifiers.intersection(Self.significantModifiers) == self.modifiers
  }
}

public struct PushToTalkGesture: Sendable {
  public enum Action: Equatable, Sendable {
    case ignored
    case consumed
    case pressed
    case released
  }

  private let shortcut: GlobalShortcut
  private var isHeld = false

  public init(shortcut: GlobalShortcut) {
    self.shortcut = shortcut
  }

  public mutating func handle(
    isKeyDown: Bool,
    keyCode: UInt16,
    modifiers: KeyModifiers,
    isRepeat: Bool
  ) -> Action {
    if isKeyDown {
      guard shortcut.matches(keyCode: keyCode, modifiers: modifiers) else {
        return .ignored
      }
      guard !isRepeat, !isHeld else {
        return .consumed
      }
      isHeld = true
      return .pressed
    }

    guard isHeld, keyCode == shortcut.keyCode else {
      return .ignored
    }
    isHeld = false
    return .released
  }

  public mutating func cancel() -> Action {
    guard isHeld else {
      return .ignored
    }
    isHeld = false
    return .released
  }
}

public struct SnippetPolicy: Equatable, Sendable {
  public let minimumDuration: TimeInterval

  public init(minimumDuration: TimeInterval = 0.2) {
    self.minimumDuration = minimumDuration
  }

  public func shouldCommit(duration: TimeInterval) -> Bool {
    duration >= minimumDuration
  }
}

public struct FocusSnapshot: Equatable, Sendable {
  public let processID: Int32
  public let elementToken: String
  public let isSecure: Bool

  public init(processID: Int32, elementToken: String, isSecure: Bool) {
    self.processID = processID
    self.elementToken = elementToken
    self.isSecure = isSecure
  }
}

public enum PasteSafety {
  public static func canPaste(
    captured: FocusSnapshot,
    current: FocusSnapshot
  ) -> Bool {
    !captured.isSecure
      && !current.isSecure
      && captured.processID == current.processID
      && captured.elementToken == current.elementToken
  }
}
