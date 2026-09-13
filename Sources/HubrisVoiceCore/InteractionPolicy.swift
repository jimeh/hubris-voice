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
    case cancelled
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
    return .cancelled
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
  public let elementToken: String?
  public let isSecure: Bool

  public init(
    processID: Int32,
    elementToken: String?,
    isSecure: Bool
  ) {
    self.processID = processID
    self.elementToken = elementToken
    self.isSecure = isSecure
  }
}

public enum PasteDecision: Equatable, Sendable {
  case exactElement
  case sameApplication
  case rejected
}

public enum PasteOutcome: Equatable, Sendable {
  case confirmed
  case attempted
  case rejected
}

public enum PasteSafety {
  public static func decision(
    captured: FocusSnapshot,
    current: FocusSnapshot
  ) -> PasteDecision {
    guard
      !captured.isSecure,
      !current.isSecure,
      captured.processID == current.processID
    else {
      return .rejected
    }

    guard let capturedElementToken = captured.elementToken else {
      return .sameApplication
    }
    guard current.elementToken == capturedElementToken else {
      return .rejected
    }
    return .exactElement
  }

  public static func canPaste(
    captured: FocusSnapshot,
    current: FocusSnapshot
  ) -> Bool {
    decision(captured: captured, current: current) != .rejected
  }
}

public struct AccessibleTextState: Equatable, Sendable {
  public let value: String?
  public let selectionLocation: Int?
  public let selectionLength: Int?

  public init(
    value: String?,
    selectionLocation: Int?,
    selectionLength: Int?
  ) {
    self.value = value
    self.selectionLocation = selectionLocation
    self.selectionLength = selectionLength
  }
}

public enum PasteConfirmation {
  public static func outcome(
    before: AccessibleTextState?,
    after: AccessibleTextState?
  ) -> PasteOutcome {
    guard let before, let after, before != after else {
      return .attempted
    }
    return .confirmed
  }
}

public enum SingleInstancePolicy {
  public static func shouldTerminate(
    currentProcessID: Int32,
    runningProcessIDs: [Int32]
  ) -> Bool {
    runningProcessIDs.contains { $0 != currentProcessID }
  }
}
