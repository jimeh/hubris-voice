import Foundation

public enum WindowTextSource: Equatable, Sendable {
  case selectedText
  case focusedElement
  case focusedEditor
  case documentTitle
  case selectedTabTitle
  case windowTitle
  case generalWindow
}

public enum WindowTextRelevance: Int, Equatable, Sendable {
  case general
  case supporting
  case nearby
  case primary
}

public enum WindowTextVisibility: Equatable, Sendable {
  case visibleChildren
  case boundsIntersection
  case visibleCharacterRange
  case title
}

public struct WindowTextFragment: Equatable, Sendable {
  public let text: String
  public let source: WindowTextSource
  public let relevance: WindowTextRelevance
  public let visibility: WindowTextVisibility

  public init(
    text: String,
    source: WindowTextSource,
    relevance: WindowTextRelevance,
    visibility: WindowTextVisibility
  ) {
    self.text = text
    self.source = source
    self.relevance = relevance
    self.visibility = visibility
  }
}

public enum WindowTermLexiconClassification: Equatable, Sendable {
  case known
  case unknown
  case unclassified
}

public struct WindowTermEvidence: Equatable, Sendable {
  public let term: String
  public let lexiconClassification: WindowTermLexiconClassification
  public let isCorrectionRepresentable: Bool

  public init(
    term: String,
    lexiconClassification: WindowTermLexiconClassification,
    isCorrectionRepresentable: Bool
  ) {
    self.term = term
    self.lexiconClassification = lexiconClassification
    self.isCorrectionRepresentable = isCorrectionRepresentable
  }
}

public enum ActiveWindowContextSelector {
  public static let defaultMaximumEphemeralTerms = 40

  public static func isIdentifierLike(_ term: String) -> Bool {
    identifierShape(term) != .ordinary
  }

  public static func candidateTerms(in fragments: [WindowTextFragment]) -> [String] {
    var terms: [String] = []
    var seen: Set<String> = []

    for fragment in fragments {
      for term in tokens(in: fragment.text) where seen.insert(comparisonKey(term)).inserted {
        terms.append(term)
      }
    }
    return terms
  }

  public static func selectContext(
    from fragments: [WindowTextFragment],
    permanentEntries: [LocalVocabularyEntry],
    evidence: [WindowTermEvidence],
    maximumEphemeralTerms: Int = defaultMaximumEphemeralTerms
  ) -> LocalInvocationContext {
    let evidenceByTerm = Dictionary(evidence.map { (comparisonKey($0.term), $0) }) { first, _ in
      first
    }
    let permanentKeys = Set(permanentEntries.map { comparisonKey($0.canonicalText) })
    var candidates: [String: Candidate] = [:]
    var occurrenceIndex = 0

    for (fragmentIndex, fragment) in fragments.enumerated() {
      for term in tokens(in: fragment.text) {
        defer { occurrenceIndex += 1 }
        let key = comparisonKey(term)
        guard !permanentKeys.contains(key),
              let termEvidence = evidenceByTerm[key],
              termEvidence.isCorrectionRepresentable
        else { continue }

        let occurrenceScore = sourceScore(fragment.source)
          + relevanceScore(fragment.relevance)
          + shapeScore(term)
        if var existing = candidates[key] {
          existing.occurrenceCount += 1
          existing.bestOccurrenceScore = max(existing.bestOccurrenceScore, occurrenceScore)
          existing.hasSelectedOccurrence =
            existing.hasSelectedOccurrence || fragment.source == .selectedText
          existing.hasStrongOccurrence = existing.hasStrongOccurrence || isStrong(fragment)
          let spellingQuality = canonicalSpellingQuality(term)
          let existingSpellingQuality = canonicalSpellingQuality(existing.canonicalText)
          if spellingQuality > existingSpellingQuality
            || (spellingQuality == existingSpellingQuality
              && canonicalRank(term, occurrenceScore: occurrenceScore)
              > canonicalRank(existing.canonicalText, occurrenceScore: existing.canonicalScore))
          {
            existing.canonicalText = term
            existing.canonicalScore = occurrenceScore
          }
          candidates[key] = existing
        } else {
          candidates[key] = Candidate(
            canonicalText: term,
            canonicalScore: occurrenceScore,
            bestOccurrenceScore: occurrenceScore,
            occurrenceCount: 1,
            firstFragmentIndex: fragmentIndex,
            firstOccurrenceIndex: occurrenceIndex,
            lexiconClassification: termEvidence.lexiconClassification,
            hasSelectedOccurrence: fragment.source == .selectedText,
            hasStrongOccurrence: isStrong(fragment)
          )
        }
      }
    }

    let selected = candidates.values
      .filter(isEligible)
      .sorted(by: ranksBefore)
      .prefix(max(0, maximumEphemeralTerms))
      .map { LocalVocabularyEntry(canonicalText: $0.canonicalText) }

    return LocalInvocationContext(
      permanentEntries: permanentEntries,
      ephemeralEntries: Array(selected)
    )
  }
}

private extension ActiveWindowContextSelector {
  struct Candidate {
    var canonicalText: String
    var canonicalScore: Int
    var bestOccurrenceScore: Int
    var occurrenceCount: Int
    let firstFragmentIndex: Int
    let firstOccurrenceIndex: Int
    let lexiconClassification: WindowTermLexiconClassification
    var hasSelectedOccurrence: Bool
    var hasStrongOccurrence: Bool

    var score: Int {
      bestOccurrenceScore
        + min(occurrenceCount - 1, 4) * 40
        + lexiconScore(lexiconClassification)
        + canonicalQuality(canonicalText)
    }
  }

  static func tokens(in text: String) -> [String] {
    text.split(whereSeparator: \Character.isWhitespace).flatMap { rawChunk -> [String] in
      let chunk = String(rawChunk)
      let trimmed = chunk.trimmingCharacters(in: .punctuationCharacters)
      if isSourceFilename(trimmed) {
        return [trimmed]
      }
      guard !isStructuralNoise(chunk) else { return [] }

      var tokens: [String] = []
      var current = ""
      for character in chunk {
        if character.isLetter || character.isNumber || character == "_" {
          current.append(character)
        } else if !current.isEmpty {
          tokens.append(current)
          current = ""
        }
      }
      if !current.isEmpty {
        tokens.append(current)
      }
      return tokens.filter(isPlausibleToken)
    }
  }

  static func isStructuralNoise(_ chunk: String) -> Bool {
    let trimmed = chunk.trimmingCharacters(in: .punctuationCharacters)
    let lowercased = trimmed.lowercased()
    if lowercased.contains("://") || lowercased.hasPrefix("www.") || lowercased.contains("@") {
      return true
    }
    if trimmed.contains("/") || trimmed.contains("\\") {
      return true
    }
    let dotParts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
    if dotParts.count >= 2,
       dotParts.last?.count ?? 0 >= 2,
       dotParts.last?.allSatisfy(\.isLetter) == true
    {
      return true
    }
    if lowercased.hasPrefix("sk-") || lowercased.hasPrefix("ghp_")
      || lowercased.hasPrefix("github_pat_") || lowercased.hasPrefix("akia")
      || lowercased.hasPrefix("asia")
    {
      return true
    }
    let compact = trimmed.filter { $0.isLetter || $0.isNumber }
    if compact.count >= 16, compact.allSatisfy(\.isHexDigit) {
      return true
    }
    let hasLowercase = compact.contains(where: \.isLowercase)
    let hasUppercase = compact.contains(where: \.isUppercase)
    let hasNumber = compact.contains(where: \.isNumber)
    if compact.count >= 24, hasLowercase, hasUppercase, hasNumber {
      let uniqueRatio = Double(Set(compact).count) / Double(compact.count)
      if uniqueRatio >= 0.65 {
        return true
      }
    }
    return looksLikeUUID(trimmed)
  }

  static func looksLikeUUID(_ value: String) -> Bool {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
    return parts.allSatisfy { $0.allSatisfy(\.isHexDigit) }
  }

  static func isPlausibleToken(_ token: String) -> Bool {
    guard token.count > 1, token.count <= 80 else { return false }
    guard token.contains(where: \.isLetter) else { return false }
    let compact = token.filter { $0.isLetter || $0.isNumber }
    if compact.count >= 16, compact.allSatisfy(\.isHexDigit) {
      return false
    }
    return true
  }

  static func isEligible(_ candidate: Candidate) -> Bool {
    if isIdentifierLike(candidate.canonicalText) {
      return true
    }
    switch candidate.lexiconClassification {
    case .known:
      return candidate.hasSelectedOccurrence || candidate.occurrenceCount >= 2
    case .unknown:
      return candidate.hasStrongOccurrence || candidate.occurrenceCount >= 2
        || startsWithUppercase(candidate.canonicalText)
    case .unclassified:
      return candidate.hasSelectedOccurrence || candidate.occurrenceCount >= 2
        || startsWithUppercase(candidate.canonicalText)
    }
  }

  static func ranksBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
    if lhs.score != rhs.score {
      return lhs.score > rhs.score
    }
    if lhs.firstFragmentIndex != rhs.firstFragmentIndex {
      return lhs.firstFragmentIndex < rhs.firstFragmentIndex
    }
    if lhs.firstOccurrenceIndex != rhs.firstOccurrenceIndex {
      return lhs.firstOccurrenceIndex < rhs.firstOccurrenceIndex
    }
    return comparisonKey(lhs.canonicalText) < comparisonKey(rhs.canonicalText)
  }

  enum IdentifierShape {
    case ordinary
    case filename
    case pascalCase
    case camelCase
    case acronym
    case underscore
    case mixedAlphanumeric
  }

  static func identifierShape(_ term: String) -> IdentifierShape {
    if isSourceFilename(term) {
      return .filename
    }
    if term.contains("_") {
      return .underscore
    }
    if term.contains(where: \.isLetter), term.contains(where: \.isNumber) {
      return .mixedAlphanumeric
    }
    let letters = term.filter(\.isLetter)
    if letters.count >= 2, letters.allSatisfy(\.isUppercase) {
      return .acronym
    }
    let hasInteriorUppercase = term.dropFirst().contains(where: \.isUppercase)
    if term.first?.isLowercase == true, hasInteriorUppercase {
      return .camelCase
    }
    if term.first?.isUppercase == true,
       term.dropFirst().contains(where: \.isLowercase),
       hasInteriorUppercase
    {
      return .pascalCase
    }
    return .ordinary
  }

  static func sourceScore(_ source: WindowTextSource) -> Int {
    switch source {
    case .selectedText: 700
    case .focusedElement: 600
    case .focusedEditor: 500
    case .documentTitle, .selectedTabTitle, .windowTitle: 350
    case .generalWindow: 100
    }
  }

  static func relevanceScore(_ relevance: WindowTextRelevance) -> Int {
    relevance.rawValue * 25
  }

  static func shapeScore(_ term: String) -> Int {
    switch identifierShape(term) {
    case .filename: 140
    case .underscore: 130
    case .camelCase, .pascalCase: 120
    case .acronym: 100
    case .mixedAlphanumeric: 90
    case .ordinary: 0
    }
  }

  static func lexiconScore(_ classification: WindowTermLexiconClassification) -> Int {
    switch classification {
    case .unknown: 60
    case .unclassified: 20
    case .known: 0
    }
  }

  static func canonicalRank(_ term: String, occurrenceScore: Int) -> Int {
    occurrenceScore + canonicalQuality(term)
  }

  static func canonicalSpellingQuality(_ term: String) -> Int {
    let spellingSubject = isSourceFilename(term)
      ? term.split(separator: ".").dropLast().joined(separator: ".")
      : term
    return switch identifierShape(spellingSubject) {
    case .filename, .camelCase, .pascalCase, .acronym: 3
    case .underscore, .mixedAlphanumeric: 2
    case .ordinary: startsWithUppercase(spellingSubject) ? 1 : 0
    }
  }

  static func canonicalQuality(_ term: String) -> Int {
    switch identifierShape(term) {
    case .filename: 40
    case .camelCase, .pascalCase, .underscore: 30
    case .acronym, .mixedAlphanumeric: 20
    case .ordinary: startsWithUppercase(term) ? 10 : 0
    }
  }

  static func startsWithUppercase(_ term: String) -> Bool {
    term.first?.isUppercase == true
  }

  static func isSourceFilename(_ term: String) -> Bool {
    let parts = term.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2,
          let fileExtension = parts.last,
          parts.dropLast().allSatisfy({ part in
            !part.isEmpty
              && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
          })
    else { return false }

    return sourceFilenameExtensions.contains(String(fileExtension).lowercased())
  }

  static let sourceFilenameExtensions: Set<String> = [
    "bash", "c", "cc", "cpp", "css", "cxx", "fish", "fs", "fsx", "go", "gql",
    "graphql", "h", "hpp", "html", "java", "js", "json", "jsx", "kt", "kts", "less",
    "lock", "m", "md", "mdx", "mm", "php", "plist", "proto", "py", "rb", "rs", "sass",
    "scala", "scss", "sh", "sql", "svelte", "swift", "toml", "ts", "tsx", "txt", "vue",
    "xml", "yaml", "yml", "zsh",
  ]

  static func isStrong(_ fragment: WindowTextFragment) -> Bool {
    switch fragment.source {
    case .selectedText, .focusedElement, .focusedEditor,
         .documentTitle, .selectedTabTitle, .windowTitle:
      true
    case .generalWindow:
      fragment.relevance == .primary
    }
  }

  static func comparisonKey(_ term: String) -> String {
    LocalVocabularyAliases.comparisonKey(term)
  }
}
