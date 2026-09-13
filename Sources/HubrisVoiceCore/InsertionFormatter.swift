import Foundation

public struct InsertionFormatter: Equatable, Sendable {
  public struct Options: Equatable, Sendable {
    public var smartLeadingSpace: Bool
    public var trailingSpace: Bool
    public var adjustCaseAfterComma: Bool
    public var protectedTerms: [String]

    public init(
      smartLeadingSpace: Bool = true,
      trailingSpace: Bool = true,
      adjustCaseAfterComma: Bool = false,
      protectedTerms: [String] = []
    ) {
      self.smartLeadingSpace = smartLeadingSpace
      self.trailingSpace = trailingSpace
      self.adjustCaseAfterComma = adjustCaseAfterComma
      self.protectedTerms = protectedTerms
    }
  }

  public struct Context: Equatable, Sendable {
    public var textBeforeCaret: String?
    public var textAfterCaret: String?

    public init(
      textBeforeCaret: String?,
      textAfterCaret: String?
    ) {
      self.textBeforeCaret = textBeforeCaret
      self.textAfterCaret = textAfterCaret
    }
  }

  public static func format(
    _ transcript: String,
    context: Context,
    options: Options
  ) -> String {
    var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "" }

    if shouldAdjustCase(text, context: context, options: options) {
      text = text.first.map { $0.lowercased() + String(text.dropFirst()) } ?? text
    }
    if shouldAddLeadingSpace(context: context, options: options) {
      text = " " + text
    }
    if shouldAddTrailingSpace(context: context, options: options) {
      text += " "
    }
    return text
  }
}

private extension InsertionFormatter {
  static let openingCharacters: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘"]
  static let closingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]

  static func shouldAddLeadingSpace(
    context: Context,
    options: Options
  ) -> Bool {
    guard
      options.smartLeadingSpace,
      let character = context.textBeforeCaret?.last
    else {
      return false
    }
    return !character.isWhitespace && !openingCharacters.contains(character)
  }

  static func shouldAddTrailingSpace(
    context: Context,
    options: Options
  ) -> Bool {
    guard options.trailingSpace else { return false }
    guard let character = context.textAfterCaret?.first else { return true }
    return !character.isWhitespace && !closingPunctuation.contains(character)
  }

  static func shouldAdjustCase(
    _ transcript: String,
    context: Context,
    options: Options
  ) -> Bool {
    guard
      options.adjustCaseAfterComma,
      context.textBeforeCaret?.last(where: { !$0.isWhitespace }) == ","
    else {
      return false
    }

    let firstWord = String(transcript.prefix(while: { !$0.isWhitespace }))
    guard firstWord != "I" else { return false }
    guard !options.protectedTerms.contains(where: { term in
      term.compare(firstWord, options: .caseInsensitive) == .orderedSame
    }) else {
      return false
    }
    return !firstWord.dropFirst().contains(where: \.isUppercase)
  }
}
