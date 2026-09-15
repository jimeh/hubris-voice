import AppKit
import Foundation
import HubrisVoiceCore

@MainActor
struct WindowTermClassifier {
  static let maximumTerms = 256

  private let spellChecker: NSSpellChecker
  private let language: String?

  init(
    spellChecker: NSSpellChecker = .shared,
    preferredLanguages: [String] = Locale.preferredLanguages
  ) {
    self.spellChecker = spellChecker
    language = Self.englishLanguage(
      available: spellChecker.availableLanguages,
      preferred: preferredLanguages
    )
  }

  func evidence(for terms: [String]) -> [WindowTermEvidence] {
    let prioritizedTerms = terms.enumerated().sorted { lhs, rhs in
      let lhsIsIdentifier = ActiveWindowContextSelector.isIdentifierLike(lhs.element)
      let rhsIsIdentifier = ActiveWindowContextSelector.isIdentifierLike(rhs.element)
      if lhsIsIdentifier != rhsIsIdentifier {
        return lhsIsIdentifier
      }
      return lhs.offset < rhs.offset
    }
    return prioritizedTerms.prefix(Self.maximumTerms).map { _, term in
      WindowTermEvidence(
        term: term,
        lexiconClassification: classification(of: term),
        isCorrectionRepresentable: !term.isEmpty
      )
    }
  }

  private func classification(of term: String) -> WindowTermLexiconClassification {
    guard let language else { return .unclassified }
    let misspelled = spellChecker.checkSpelling(
      of: term,
      startingAt: 0,
      language: language,
      wrap: false,
      inSpellDocumentWithTag: 0,
      wordCount: nil
    )
    return misspelled.location == NSNotFound ? .known : .unknown
  }

  private static func englishLanguage(
    available: [String],
    preferred: [String]
  ) -> String? {
    let english = available.filter { $0.lowercased().hasPrefix("en") }
    guard !english.isEmpty else { return nil }
    for preference in preferred where preference.lowercased().hasPrefix("en") {
      if let exact = english.first(where: {
        $0.caseInsensitiveCompare(preference) == .orderedSame
      }) {
        return exact
      }
      let normalized = preference.replacingOccurrences(of: "-", with: "_")
      if let regional = english.first(where: {
        $0.caseInsensitiveCompare(normalized) == .orderedSame
      }) {
        return regional
      }
    }
    return english.first
  }
}
