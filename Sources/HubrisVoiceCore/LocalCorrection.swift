import Foundation

public enum LocalCorrectionPolicy: String, Codable, Equatable, Sendable {
  case disabled
  case strict

  public var configuration: LocalCorrectionConfiguration? {
    switch self {
    case .disabled:
      nil
    case .strict:
      LocalCorrectionConfiguration(
        minimumSimilarity: 0.80,
        shortTermTaperPivot: 1,
        rescueMinimumSimilarity: 0.80,
        rescueMultiwordMinimumSimilarity: 0.85,
        acousticRescueEnabled: true
      )
    }
  }
}

public struct LocalCorrectionConfiguration: Equatable, Sendable {
  public let minimumSimilarity: Double
  public let shortTermTaperPivot: Int
  public let rescueMinimumSimilarity: Double
  public let rescueMultiwordMinimumSimilarity: Double
  public let acousticRescueEnabled: Bool

  public init(
    minimumSimilarity: Double,
    shortTermTaperPivot: Int,
    rescueMinimumSimilarity: Double,
    rescueMultiwordMinimumSimilarity: Double,
    acousticRescueEnabled: Bool
  ) {
    self.minimumSimilarity = minimumSimilarity
    self.shortTermTaperPivot = shortTermTaperPivot
    self.rescueMinimumSimilarity = rescueMinimumSimilarity
    self.rescueMultiwordMinimumSimilarity = rescueMultiwordMinimumSimilarity
    self.acousticRescueEnabled = acousticRescueEnabled
  }
}

public struct LocalCorrectionResult: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    case disabled
    case unchanged
    case applied
    case rejected
  }

  public let text: String
  public let outcome: Outcome
  public let decisions: [LocalCorrectionDecision]

  public init(text: String, outcome: Outcome, decisions: [LocalCorrectionDecision] = []) {
    self.text = text
    self.outcome = outcome
    self.decisions = decisions
  }
}

public struct LocalCorrectionDecision: Equatable, Sendable {
  public enum Reason: Equatable, Sendable {
    case canonicalSubstitution
    case insertionOrDeletion
    case candidateIsNotCanonical
    case protectedWordConsumption
  }

  public let rawText: String
  public let candidateText: String
  public let accepted: Bool
  public let reason: Reason
}

public enum LocalTranscriptCorrection {
  private static let protectedWords: Set<String> = Set(
    """
    a an the and or but if then than to of on in at by for from with as is are was were be been being
    it this that these those we you i he she they my your our their
    """
    .split(separator: " ").map(String.init)
  )

  public static func applyAliases(
    to rawText: String,
    context: LocalInvocationContext,
    policy: LocalCorrectionPolicy
  ) -> LocalCorrectionResult {
    guard policy != .disabled else {
      return LocalCorrectionResult(text: rawText, outcome: .disabled)
    }
    let aliases = LocalVocabularyAliases.resolve(
      context.permanentEntries + context.ephemeralEntries
    ).flatMap(\.aliases)
      .filter { $0.text.split(whereSeparator: \Character.isWhitespace).count >= 2 }
      .sorted {
        if $0.text.count == $1.text.count {
          return LocalVocabularyAliases.comparisonKey($0.text)
            < LocalVocabularyAliases.comparisonKey($1.text)
        }
        return $0.text.count > $1.text.count
      }

    var result = rawText
    var decisions: [LocalCorrectionDecision] = []
    let targets = Dictionary(uniqueKeysWithValues: aliases.map {
      (LocalVocabularyAliases.comparisonKey($0.text), $0.canonicalText)
    })
    if let expression = aliasExpression(aliases.map(\.text)) {
      let matches = expression.matches(
        in: rawText,
        range: NSRange(rawText.startIndex..., in: rawText)
      )
      for match in matches.reversed() {
        guard let range = Range(match.range, in: result) else { continue }
        let matched = String(result[range])
        guard let canonical = targets[LocalVocabularyAliases.comparisonKey(matched)] else {
          continue
        }
        if matched != canonical {
          result.replaceSubrange(range, with: canonical)
          decisions.append(
            LocalCorrectionDecision(
              rawText: matched,
              candidateText: canonical,
              accepted: true,
              reason: .canonicalSubstitution
            )
          )
        }
      }
    }
    return LocalCorrectionResult(
      text: result,
      outcome: decisions.isEmpty ? .unchanged : .applied,
      decisions: decisions.reversed()
    )
  }

  public static func guardCandidate(
    rawText: String,
    candidateText: String,
    context: LocalInvocationContext,
    policy: LocalCorrectionPolicy
  ) -> LocalCorrectionResult {
    guard policy != .disabled else {
      return LocalCorrectionResult(text: rawText, outcome: .disabled)
    }

    let rawTokens = tokens(in: rawText)
    let candidateTokens = tokens(in: candidateText)
    let resolved = LocalVocabularyAliases.resolve(
      context.permanentEntries + context.ephemeralEntries
    )
    var edits: [(Range<String.Index>, String)] = []
    var decisions: [LocalCorrectionDecision] = []

    for difference in differences(
      rawTokens.map { comparisonToken($0.text) },
      candidateTokens.map { comparisonToken($0.text) }
    ) {
      let assessment = assess(
        difference,
        rawTokens: rawTokens,
        candidateTokens: candidateTokens,
        entries: resolved
      )
      decisions.append(assessment.decision)
      if let edit = assessment.edit {
        edits.append(edit)
      }
    }

    var result = rawText
    for (range, replacement) in edits.reversed() {
      result.replaceSubrange(range, with: replacement)
    }
    let outcome: LocalCorrectionResult.Outcome = if edits.isEmpty {
      decisions.isEmpty ? .unchanged : .rejected
    } else {
      .applied
    }
    return LocalCorrectionResult(text: result, outcome: outcome, decisions: decisions)
  }

  private struct Token {
    let text: String
    let range: Range<String.Index>
  }

  private struct Difference {
    let rawRange: Range<Int>
    let candidateRange: Range<Int>
  }

  private struct Assessment {
    let decision: LocalCorrectionDecision
    let edit: (Range<String.Index>, String)?
  }

  private static func assess(
    _ difference: Difference,
    rawTokens: [Token],
    candidateTokens: [Token],
    entries: [LocalResolvedEntry]
  ) -> Assessment {
    let raw = rawTokens[difference.rawRange].map(\.text).joined(separator: " ")
    let candidate = candidateTokens[difference.candidateRange].map(\.text).joined(separator: " ")
    guard !difference.rawRange.isEmpty, !difference.candidateRange.isEmpty else {
      return rejected(raw: raw, candidate: candidate, reason: .insertionOrDeletion)
    }
    guard let canonical = canonicalTerm(in: candidate, entries: entries) else {
      return rejected(raw: raw, candidate: candidate, reason: .candidateIsNotCanonical)
    }

    let rawWords = lexicalWords(in: raw)
    let consumesProtectedWord = !protectedWords.isDisjoint(with: rawWords)
    let explicitAlias = entries
      .first { $0.canonicalText == canonical }?
      .aliases
      .contains {
        $0.source == .explicit && lexicalWords(in: $0.text) == rawWords
      } ?? false
    guard !consumesProtectedWord || explicitAlias else {
      return rejected(raw: raw, candidate: candidate, reason: .protectedWordConsumption)
    }

    let first = rawTokens[difference.rawRange.lowerBound]
    let last = rawTokens[difference.rawRange.index(before: difference.rawRange.upperBound)]
    let trailingPunctuation = last.text.reversed().prefix(while: isBoundaryCharacter)
    return Assessment(
      decision: LocalCorrectionDecision(
        rawText: raw,
        candidateText: candidate,
        accepted: true,
        reason: .canonicalSubstitution
      ),
      edit: (
        first.range.lowerBound ..< last.range.upperBound,
        canonical + String(trailingPunctuation.reversed())
      )
    )
  }

  private static func rejected(
    raw: String,
    candidate: String,
    reason: LocalCorrectionDecision.Reason
  ) -> Assessment {
    Assessment(
      decision: LocalCorrectionDecision(
        rawText: raw,
        candidateText: candidate,
        accepted: false,
        reason: reason
      ),
      edit: nil
    )
  }

  private static func tokens(in text: String) -> [Token] {
    var result: [Token] = []
    var start: String.Index?
    var index = text.startIndex
    while index < text.endIndex {
      if text[index].isWhitespace {
        if let start {
          result.append(Token(text: String(text[start ..< index]), range: start ..< index))
        }
        start = nil
      } else if start == nil {
        start = index
      }
      index = text.index(after: index)
    }
    if let start {
      result.append(Token(text: String(text[start ..< text.endIndex]), range: start ..< text.endIndex))
    }
    return result
  }

  private static func differences(_ raw: [String], _ candidate: [String]) -> [Difference] {
    let rawCount = raw.count
    let candidateCount = candidate.count
    var lengths = Array(
      repeating: Array(repeating: 0, count: candidateCount + 1),
      count: rawCount + 1
    )
    if rawCount > 0, candidateCount > 0 {
      for rawIndex in stride(from: rawCount - 1, through: 0, by: -1) {
        for candidateIndex in stride(from: candidateCount - 1, through: 0, by: -1) {
          lengths[rawIndex][candidateIndex] = raw[rawIndex] == candidate[candidateIndex]
            ? lengths[rawIndex + 1][candidateIndex + 1] + 1
            : max(lengths[rawIndex + 1][candidateIndex], lengths[rawIndex][candidateIndex + 1])
        }
      }
    }

    var matches: [(Int, Int)] = [(-1, -1)]
    var rawIndex = 0
    var candidateIndex = 0
    while rawIndex < rawCount, candidateIndex < candidateCount {
      if raw[rawIndex] == candidate[candidateIndex] {
        matches.append((rawIndex, candidateIndex))
        rawIndex += 1
        candidateIndex += 1
      } else if lengths[rawIndex + 1][candidateIndex] >= lengths[rawIndex][candidateIndex + 1] {
        rawIndex += 1
      } else {
        candidateIndex += 1
      }
    }
    matches.append((rawCount, candidateCount))

    return zip(matches, matches.dropFirst()).compactMap { previous, next in
      let rawRange = (previous.0 + 1) ..< next.0
      let candidateRange = (previous.1 + 1) ..< next.1
      return rawRange.isEmpty && candidateRange.isEmpty
        ? nil
        : Difference(rawRange: rawRange, candidateRange: candidateRange)
    }
  }

  private static func canonicalTerm(
    in candidate: String,
    entries: [LocalResolvedEntry]
  ) -> String? {
    let normalized = LocalVocabularyAliases.normalizeWhitespace(candidate)
    return entries.compactMap { entry -> String? in
      guard let range = normalized.range(of: entry.canonicalText) else { return nil }
      let prefix = normalized[..<range.lowerBound]
      let suffix = normalized[range.upperBound...]
      guard prefix.allSatisfy(isBoundaryCharacter), suffix.allSatisfy(isBoundaryCharacter) else {
        return nil
      }
      return entry.canonicalText
    }.first
  }

  private static func lexicalWords(in text: String) -> Set<String> {
    var words: [String] = []
    var current = ""
    for character in text.lowercased() {
      if character.isLetter || character.isNumber || character == "_" {
        current.append(character)
      } else if !current.isEmpty {
        words.append(current)
        current = ""
      }
    }
    if !current.isEmpty {
      words.append(current)
    }
    return Set(words)
  }

  private static func comparisonToken(_ text: String) -> String {
    String(
      text.drop(while: isBoundaryCharacter)
        .reversed()
        .drop(while: isBoundaryCharacter)
        .reversed()
    )
  }

  private static func isBoundaryCharacter(_ character: Character) -> Bool {
    !character.isLetter && !character.isNumber && character != "_"
  }

  private static func aliasExpression(_ aliases: [String]) -> NSRegularExpression? {
    guard !aliases.isEmpty else { return nil }
    let body = aliases.map { alias in
      alias.split(whereSeparator: \Character.isWhitespace)
        .map { NSRegularExpression.escapedPattern(for: String($0)) }
        .joined(separator: "\\s+")
    }.joined(separator: "|")
    return try? NSRegularExpression(
      pattern: "(?<![\\p{L}\\p{M}\\p{N}_])(?:\(body))(?![\\p{L}\\p{M}\\p{N}_])",
      options: [.caseInsensitive]
    )
  }
}
