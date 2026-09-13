import Foundation

public struct KeyModifiers: OptionSet, Codable, Equatable, Sendable {
  public let rawValue: UInt

  public init(rawValue: UInt) {
    self.rawValue = rawValue
  }

  public static let control = KeyModifiers(rawValue: 1 << 0)
  public static let shift = KeyModifiers(rawValue: 1 << 1)
  public static let command = KeyModifiers(rawValue: 1 << 2)
  public static let option = KeyModifiers(rawValue: 1 << 3)
  // swiftlint:disable:next identifier_name
  public static let fn = KeyModifiers(rawValue: 1 << 4)
}

public struct GlobalShortcut: Codable, Equatable, Sendable {
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

  public var displayName: String {
    let modifierName = [
      (KeyModifiers.control, "⌃"),
      (.option, "⌥"),
      (.shift, "⇧"),
      (.command, "⌘"),
    ].compactMap { modifier, glyph in
      modifiers.contains(modifier) ? glyph : nil
    }.joined()
    return modifierName + Self.keyName(for: keyCode)
  }
}

public enum ModifierKey: String, CaseIterable, Codable, Sendable {
  // swiftlint:disable:next identifier_name
  case fn
  case rightCommand
  case rightOption
  case rightControl
  case rightShift

  public var keyCode: UInt16 {
    switch self {
    case .fn: 63
    case .rightCommand: 54
    case .rightOption: 61
    case .rightControl: 62
    case .rightShift: 60
    }
  }

  public var displayName: String {
    switch self {
    case .fn: "Fn"
    case .rightCommand: "Right ⌘"
    case .rightOption: "Right ⌥"
    case .rightControl: "Right ⌃"
    case .rightShift: "Right ⇧"
    }
  }

  var modifier: KeyModifiers {
    switch self {
    case .fn: .fn
    case .rightCommand: .command
    case .rightOption: .option
    case .rightControl: .control
    case .rightShift: .shift
    }
  }

  var alternateKeyCode: UInt16? {
    switch self {
    case .fn: nil
    case .rightCommand: 55
    case .rightOption: 58
    case .rightControl: 59
    case .rightShift: 56
    }
  }
}

public enum ShortcutBinding: Codable, Equatable, Sendable {
  case chord(GlobalShortcut)
  case modifier(ModifierKey)

  public var displayName: String {
    switch self {
    case .chord(let shortcut): shortcut.displayName
    case .modifier(let modifier): modifier.displayName
    }
  }
}

public enum ShortcutRole: String, CaseIterable, Codable, Sendable {
  case pushToTalk
  case pasteLastTranscript
}

public struct ShortcutSet: Codable, Equatable, Sendable {
  public var pushToTalk: ShortcutBinding
  public var pasteLastTranscript: ShortcutBinding?

  public init(
    pushToTalk: ShortcutBinding = .chord(.pushToTalkDefault),
    pasteLastTranscript: ShortcutBinding? = nil
  ) {
    self.pushToTalk = pushToTalk
    self.pasteLastTranscript = pasteLastTranscript
  }

  public func conflicts() -> [(ShortcutRole, ShortcutRole)] {
    guard pasteLastTranscript == pushToTalk else { return [] }
    return [(.pushToTalk, .pasteLastTranscript)]
  }
}

public struct ShortcutGesture: Sendable {
  public enum Action: Equatable, Sendable {
    case ignored
    case consumed
    case pressed
    case released
    case cancelled
  }

  public let binding: ShortcutBinding
  public private(set) var isHeld = false
  private var isAlternateModifierHeld = false

  public init(binding: ShortcutBinding) {
    self.binding = binding
  }

  public mutating func handleKey(
    isKeyDown: Bool,
    keyCode: UInt16,
    modifiers: KeyModifiers,
    isRepeat: Bool
  ) -> Action {
    switch binding {
    case .chord(let shortcut):
      return handleChord(
        shortcut,
        isKeyDown: isKeyDown,
        keyCode: keyCode,
        modifiers: modifiers,
        isRepeat: isRepeat
      )
    case .modifier(let modifier):
      guard isKeyDown, isHeld, keyCode != modifier.keyCode else {
        return .ignored
      }
      isHeld = false
      return .cancelled
    }
  }

  public mutating func handleFlagsChanged(
    keyCode: UInt16,
    modifiers: KeyModifiers
  ) -> Action {
    guard case .modifier(let modifier) = binding else {
      return .ignored
    }
    if keyCode == modifier.alternateKeyCode {
      isAlternateModifierHeld = modifiers.contains(modifier.modifier)
        ? !isAlternateModifierHeld
        : false
      return .ignored
    }
    guard keyCode == modifier.keyCode else { return .ignored }
    if modifiers.contains(modifier.modifier) {
      if isHeld, isAlternateModifierHeld {
        isHeld = false
        return .released
      }
      guard !isHeld else { return .ignored }
      isHeld = true
      return .pressed
    }
    guard isHeld else { return .ignored }
    isHeld = false
    isAlternateModifierHeld = false
    return .released
  }

  public mutating func cancel() -> Action {
    guard isHeld else {
      return .ignored
    }
    isHeld = false
    isAlternateModifierHeld = false
    return .cancelled
  }

  private mutating func handleChord(
    _ shortcut: GlobalShortcut,
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
}

private extension GlobalShortcut {
  static func keyName(for keyCode: UInt16) -> String {
    let names: [UInt16: String] = [
      0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
      8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
      16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
      23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
      30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
      37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
      44: "/", 45: "N", 46: "M", 47: ".", 49: "Space", 50: "`", 53: "Escape", 64: "F17",
      79: "F18", 80: "F19", 90: "F20",
      96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
      103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10",
      111: "F12", 113: "F15", 115: "Home", 116: "Page Up", 117: "Delete",
      118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1",
      123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    return names[keyCode] ?? String(format: "Key 0x%02X", keyCode)
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
    after: AccessibleTextState?,
    expected: String
  ) -> PasteOutcome {
    guard
      let before,
      let after,
      let beforeValue = before.value,
      let afterValue = after.value
    else {
      return .attempted
    }

    let beforeUTF16 = Array(beforeValue.utf16)
    let afterUTF16 = Array(afterValue.utf16)
    let expectedUTF16 = Array(expected.utf16)
    if let location = before.selectionLocation {
      let selectionLength = before.selectionLength ?? 0
      guard
        location >= 0,
        selectionLength >= 0,
        location <= beforeUTF16.count,
        selectionLength <= beforeUTF16.count - location,
        location <= afterUTF16.count,
        expectedUTF16.count <= afterUTF16.count - location,
        afterUTF16.count == beforeUTF16.count - selectionLength + expectedUTF16.count
      else {
        return .attempted
      }
      return Array(afterUTF16[location ..< location + expectedUTF16.count]) == expectedUTF16
        ? .confirmed
        : .attempted
    }

    guard
      afterUTF16.count == beforeUTF16.count + expectedUTF16.count,
      afterValue.contains(expected)
    else {
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
