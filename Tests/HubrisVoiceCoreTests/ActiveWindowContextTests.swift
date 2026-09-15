@testable import HubrisVoiceCore
import XCTest

final class ActiveWindowContextTests: XCTestCase {
  func testDefaultEphemeralCapSupportsIdentifierDenseWindows() {
    let terms = (0 ..< 50).map { "Identifier\($0)Value" }

    let context = select(fragments: [fragment(terms.joined(separator: " "))])

    XCTAssertEqual(context.ephemeralEntries.count, 40)
    XCTAssertEqual(context.ephemeralEntries.map(\.canonicalText), Array(terms.prefix(40)))
  }

  func testCandidateExtractionPreservesIdentifiersAndUnicode() {
    let terms = ActiveWindowContextSelector.candidateTerms(in: [
      fragment(
        "HubrisVoice URLSession user_id PostgreSQL getUserByID Codex "
          + "MySuperLongClassName2 München naïve"
      ),
    ])

    XCTAssertEqual(
      terms,
      [
        "HubrisVoice", "URLSession", "user_id", "PostgreSQL", "getUserByID", "Codex",
        "MySuperLongClassName2", "München", "naïve",
      ]
    )
  }

  func testCandidateExtractionPreservesSourceFilenames() {
    let terms = ActiveWindowContextSelector.candidateTerms(in: [
      fragment(
        "AppModel.swift DevelopmentDiagnostics.swift AppModelTests.generated.swift "
          + "package.json README.md"
      ),
    ])

    XCTAssertEqual(
      terms,
      [
        "AppModel.swift", "DevelopmentDiagnostics.swift", "AppModelTests.generated.swift",
        "package.json", "README.md",
      ]
    )
  }

  func testCandidateExtractionDropsStructuralAndSecretLikeNoise() {
    let terms = ActiveWindowContextSelector.candidateTerms(in: [
      fragment(
        "a 42 !!! https://example.com/name example.com user@example.com /Users/jim/project "
          + "550e8400-e29b-41d4-a716-446655440000 abcdef0123456789 "
          + "sk-abcdefghijklmnopqrstuvwxyz123456 AKIAIOSFODNN7EXAMPLE UsefulIdentifier"
      ),
    ])

    XCTAssertEqual(terms, ["UsefulIdentifier"])
  }

  func testSelectionKeepsIdentifierShapesEvenWhenLexiconKnowsThem() {
    let identifiers = ["HubrisVoice", "URLSession", "user_id", "PostgreSQL", "getUserByID", "Codex2"]
    let context = select(
      fragments: [fragment(identifiers.joined(separator: " "), source: .generalWindow)],
      classifications: Dictionary(uniqueKeysWithValues: identifiers.map { ($0, .known) })
    )

    XCTAssertEqual(Set(context.ephemeralEntries.map(\.canonicalText)), Set(identifiers))
  }

  func testOrdinaryWordsNeedLexiconAndContextSupport() {
    let context = select(
      fragments: [
        fragment("ordinary repeated", source: .generalWindow),
        fragment("repeated selectedword", source: .selectedText),
        fragment("Torvane", source: .windowTitle),
      ],
      classifications: [
        "ordinary": .known,
        "repeated": .known,
        "selectedword": .known,
        "Torvane": .unknown,
      ]
    )

    XCTAssertEqual(
      Set(context.ephemeralEntries.map(\.canonicalText)),
      Set(["repeated", "selectedword", "Torvane"])
    )
  }

  func testKnownTitleCasedLabelsAreNotTreatedAsPascalCaseIdentifiers() {
    let labels = ["Settings", "Window", "Project"]
    let context = select(
      fragments: [fragment(labels.joined(separator: " "), source: .generalWindow)],
      classifications: Dictionary(uniqueKeysWithValues: labels.map { ($0, .known) })
    )

    XCTAssertTrue(context.ephemeralEntries.isEmpty)
  }

  func testUnrepresentableTermsAreRejected() {
    let fragments = [fragment("RepresentableTerm RejectedTerm")]
    let evidence = [
      WindowTermEvidence(
        term: "RepresentableTerm",
        lexiconClassification: .unknown,
        isCorrectionRepresentable: true
      ),
      WindowTermEvidence(
        term: "RejectedTerm",
        lexiconClassification: .unknown,
        isCorrectionRepresentable: false
      ),
    ]

    let context = ActiveWindowContextSelector.selectContext(
      from: fragments,
      permanentEntries: [],
      evidence: evidence
    )

    XCTAssertEqual(context.ephemeralEntries.map(\.canonicalText), ["RepresentableTerm"])
  }

  func testRankingIsDeterministicAndUsesSourceThenRepetition() {
    let fragments = [
      fragment("GeneralIdentifier RepeatedIdentifier", source: .generalWindow),
      fragment("RepeatedIdentifier", source: .generalWindow),
      fragment("TitleIdentifier", source: .windowTitle),
      fragment("FocusedIdentifier", source: .focusedEditor),
      fragment("SelectedIdentifier", source: .selectedText),
    ]
    let expected = [
      "SelectedIdentifier",
      "FocusedIdentifier",
      "TitleIdentifier",
      "RepeatedIdentifier",
      "GeneralIdentifier",
    ]

    XCTAssertEqual(select(fragments: fragments).ephemeralEntries.map(\.canonicalText), expected)
    XCTAssertEqual(select(fragments: fragments).ephemeralEntries.map(\.canonicalText), expected)
  }

  func testDeduplicationRetainsHighestRankedCanonicalSpelling() {
    let context = select(fragments: [
      fragment("hubrisvoice", source: .generalWindow),
      fragment("HubrisVoice", source: .focusedEditor),
      fragment("HUBRISVOICE", source: .generalWindow),
    ])

    XCTAssertEqual(context.ephemeralEntries.map(\.canonicalText), ["HubrisVoice"])
  }

  func testDeduplicationPrefersDistinctiveFilenameCasingOverFocusedTranscriptEcho() {
    let context = select(fragments: [
      fragment("appmodel.swift", source: .focusedElement),
      fragment("AppModel.swift", source: .focusedEditor),
    ])

    XCTAssertEqual(context.ephemeralEntries.map(\.canonicalText), ["AppModel.swift"])
  }

  func testPermanentEntriesTakePrecedenceWithoutUsingEphemeralCap() {
    let permanent = [
      LocalVocabularyEntry(canonicalText: "HubrisVoice", explicitAliases: ["hubris voice"]),
      LocalVocabularyEntry(canonicalText: "PermanentOnly"),
    ]
    let context = select(
      fragments: [fragment("hubrisvoice FirstIdentifier SecondIdentifier")],
      permanentEntries: permanent,
      maximumEphemeralTerms: 1
    )

    XCTAssertEqual(context.permanentEntries, permanent)
    XCTAssertEqual(context.ephemeralEntries.map(\.canonicalText), ["FirstIdentifier"])
    XCTAssertEqual(context.resolvedEntries.first?.explicitAliases, ["hubris voice"])
  }

  func testSelectionAppliesTheEphemeralCapAfterRanking() {
    let terms = (0 ..< 25).map { "Term\($0)Value" }
    let context = select(
      fragments: [fragment(terms.joined(separator: " "))],
      maximumEphemeralTerms: 20
    )

    XCTAssertEqual(context.ephemeralEntries.count, 20)
    XCTAssertEqual(context.ephemeralEntries.map(\.canonicalText), Array(terms.prefix(20)))
  }

  func testSelectedEntriesReuseGeneratedAliasPolicy() {
    let context = select(fragments: [fragment("user_id", source: .selectedText)])

    XCTAssertEqual(
      context.ephemeralEntries.first?.generatedAliases,
      ["user id", "user underscore id"]
    )
  }
}

private extension ActiveWindowContextTests {
  func fragment(
    _ text: String,
    source: WindowTextSource = .focusedEditor,
    relevance: WindowTextRelevance = .nearby
  ) -> WindowTextFragment {
    WindowTextFragment(
      text: text,
      source: source,
      relevance: relevance,
      visibility: .visibleChildren
    )
  }

  func select(
    fragments: [WindowTextFragment],
    permanentEntries: [LocalVocabularyEntry] = [],
    classifications: [String: WindowTermLexiconClassification] = [:],
    maximumEphemeralTerms: Int = ActiveWindowContextSelector.defaultMaximumEphemeralTerms
  ) -> LocalInvocationContext {
    let evidence = ActiveWindowContextSelector.candidateTerms(in: fragments).map { term in
      WindowTermEvidence(
        term: term,
        lexiconClassification: classifications[term] ?? .unknown,
        isCorrectionRepresentable: true
      )
    }
    return ActiveWindowContextSelector.selectContext(
      from: fragments,
      permanentEntries: permanentEntries,
      evidence: evidence,
      maximumEphemeralTerms: maximumEphemeralTerms
    )
  }
}
