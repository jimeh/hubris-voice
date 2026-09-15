import Foundation

public struct LocalVocabularyEntry: Codable, Equatable, Hashable, Sendable {
  public var canonicalText: String
  public var explicitAliases: [String]

  public init(canonicalText: String, explicitAliases: [String] = []) {
    self.canonicalText = canonicalText
    self.explicitAliases = explicitAliases
  }

  public var generatedAliases: [String] {
    LocalVocabularyAliases.generated(for: canonicalText)
  }
}

public struct LocalInvocationContext: Equatable, Sendable {
  public let permanentEntries: [LocalVocabularyEntry]
  public let ephemeralEntries: [LocalVocabularyEntry]

  public init(
    permanentEntries: [LocalVocabularyEntry],
    ephemeralEntries: [LocalVocabularyEntry] = []
  ) {
    self.permanentEntries = permanentEntries
    self.ephemeralEntries = ephemeralEntries
  }

  public var resolvedEntries: [LocalVocabularyEntry] {
    LocalVocabularyAliases.resolve(permanentEntries + ephemeralEntries).map { resolved in
      LocalVocabularyEntry(
        canonicalText: resolved.canonicalText,
        explicitAliases: resolved.aliases.map(\.text)
      )
    }
  }
}

enum LocalVocabularyAliasSource: Int, Sendable {
  case generated
  case explicit
}

struct LocalResolvedAlias: Equatable, Sendable {
  let text: String
  let canonicalText: String
  let source: LocalVocabularyAliasSource
}

enum LocalVocabularyAliases {
  private static let locale = Locale(identifier: "en_US_POSIX")

  static func generated(for canonicalText: String) -> [String] {
    let acronymSplit = replacing(
      pattern: "([A-Z]+)([A-Z][a-z])",
      in: canonicalText,
      template: "$1 $2"
    )
    let camelSplit = replacing(
      pattern: "([a-z0-9])([A-Z])",
      in: acronymSplit,
      template: "$1 $2"
    )
    var baseForms = [
      camelSplit.replacingOccurrences(of: "_", with: " "),
      camelSplit.replacingOccurrences(of: "_", with: " underscore "),
    ]
    if camelSplit.contains(".") {
      baseForms.append(camelSplit.replacingOccurrences(of: ".", with: " dot "))
    }
    var forms = Set(baseForms.map(normalizeWhitespace).filter(isMultiword))
    for form in Array(forms) {
      forms.insert(spellAcronyms(in: form))
    }
    forms.remove(canonicalText)
    return forms.filter(isMultiword).sorted()
  }

  static func resolve(_ entries: [LocalVocabularyEntry]) -> [LocalResolvedEntry] {
    var canonicalOrder: [String] = []
    var canonicalKeys: [String: String] = [:]
    var aliasesByCanonical: [String: [(String, LocalVocabularyAliasSource)]] = [:]

    for entry in entries {
      let canonical = normalizeWhitespace(entry.canonicalText)
      guard !canonical.isEmpty else { continue }
      let key = comparisonKey(canonical)
      let retainedCanonical: String
      if let existing = canonicalKeys[key] {
        retainedCanonical = existing
      } else {
        canonicalKeys[key] = canonical
        canonicalOrder.append(canonical)
        retainedCanonical = canonical
      }
      for alias in entry.explicitAliases.map(normalizeWhitespace).filter({ !$0.isEmpty }) {
        aliasesByCanonical[retainedCanonical, default: []].append((alias, .explicit))
      }
      for alias in generated(for: canonical) {
        aliasesByCanonical[retainedCanonical, default: []].append((alias, .generated))
      }
    }

    var owners: [String: [LocalResolvedAlias]] = [:]
    for canonical in canonicalOrder {
      for (alias, source) in aliasesByCanonical[canonical, default: []] {
        guard comparisonKey(alias) != comparisonKey(canonical) else { continue }
        owners[comparisonKey(alias), default: []].append(
          LocalResolvedAlias(text: alias, canonicalText: canonical, source: source)
        )
      }
    }

    var accepted: [String: [LocalResolvedAlias]] = [:]
    for candidates in owners.values {
      let explicit = candidates.filter { $0.source == .explicit }
      let preferred = explicit.isEmpty ? candidates : explicit
      let canonicalKeys = Set(preferred.map { comparisonKey($0.canonicalText) })
      guard canonicalKeys.count == 1, let first = preferred.first else { continue }
      accepted[first.canonicalText, default: []].append(first)
    }

    return canonicalOrder.map { canonical in
      let aliases = accepted[canonical, default: []]
        .sorted { comparisonKey($0.text) < comparisonKey($1.text) }
      return LocalResolvedEntry(canonicalText: canonical, aliases: aliases)
    }
  }

  static func comparisonKey(_ value: String) -> String {
    normalizeWhitespace(value).folding(options: [.caseInsensitive], locale: locale)
  }

  static func normalizeWhitespace(_ value: String) -> String {
    value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
  }

  private static func isMultiword(_ value: String) -> Bool {
    value.split(whereSeparator: \Character.isWhitespace).count >= 2
  }

  private static func replacing(pattern: String, in value: String, template: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
    return expression.stringByReplacingMatches(
      in: value,
      range: NSRange(value.startIndex..., in: value),
      withTemplate: template
    )
  }

  private static func spellAcronyms(in value: String) -> String {
    let words = value.split(whereSeparator: \Character.isWhitespace)
    return words.map { word in
      guard word.count >= 2, word.allSatisfy(\.isUppercase) else { return String(word) }
      return word.map(String.init).joined(separator: " ")
    }.joined(separator: " ")
  }
}

struct LocalResolvedEntry: Equatable, Sendable {
  let canonicalText: String
  let aliases: [LocalResolvedAlias]
}
