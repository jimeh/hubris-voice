@testable import HubrisVoiceCore
import XCTest

final class LocalCorrectionTests: XCTestCase {
  func testStrictPolicyMatchesTestedTuning() throws {
    let configuration = try XCTUnwrap(LocalCorrectionPolicy.strict.configuration)

    XCTAssertEqual(configuration.minimumSimilarity, 0.80)
    XCTAssertEqual(configuration.shortTermTaperPivot, 1)
    XCTAssertEqual(configuration.rescueMinimumSimilarity, 0.80)
    XCTAssertEqual(configuration.rescueMultiwordMinimumSimilarity, 0.85)
    XCTAssertTrue(configuration.acousticRescueEnabled)
    XCTAssertNil(LocalCorrectionPolicy.disabled.configuration)
  }

  func testDisabledPolicyLeavesRawTextUntouched() {
    let context = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "user_id"),
    ])

    XCTAssertEqual(
      LocalTranscriptCorrection.applyAliases(
        to: "user underscore ID",
        context: context,
        policy: .disabled
      ),
      LocalCorrectionResult(text: "user underscore ID", outcome: .disabled)
    )
  }

  func testGeneratedAliasesCanonicalizeIdentifiersAndPreservePunctuation() {
    let context = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "user_id"),
      LocalVocabularyEntry(canonicalText: "URLSession"),
    ])

    let result = LocalTranscriptCorrection.applyAliases(
      to: "Use user underscore ID, then URL session.",
      context: context,
      policy: .strict
    )

    XCTAssertEqual(result.text, "Use user_id, then URLSession.")
    XCTAssertEqual(result.outcome, .applied)
  }

  func testAliasMatchingUsesUnicodeWordBoundaries() {
    let context = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "Quexal", explicitAliases: ["quex al"]),
    ])

    XCTAssertEqual(
      LocalTranscriptCorrection.applyAliases(
        to: "équés quex al, then quex alé",
        context: context,
        policy: .strict
      ).text,
      "équés Quexal, then quex alé"
    )
  }

  func testAmbiguousAliasIsLeftUnchanged() {
    let context = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "user_id", explicitAliases: ["user ID"]),
      LocalVocabularyEntry(canonicalText: "userID", explicitAliases: ["user ID"]),
    ])

    XCTAssertEqual(
      LocalTranscriptCorrection.applyAliases(
        to: "user ID",
        context: context,
        policy: .strict
      ).text,
      "user ID"
    )
  }

  func testGuardAcceptsOnlyCanonicalSubstitutionAndPreservesRawPunctuation() {
    let context = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "TensorRT"),
    ])

    let result = LocalTranscriptCorrection.guardCandidate(
      rawText: "Open this on macOS with Tensor RT.",
      candidateText: "Open this macOS with TensorRT",
      context: context,
      policy: .strict
    )

    XCTAssertEqual(result.text, "Open this on macOS with TensorRT.")
    XCTAssertEqual(result.decisions.filter(\.accepted).count, 1)
    XCTAssertTrue(result.decisions.contains { $0.reason == .insertionOrDeletion })
  }

  func testGuardPreservesOpeningAndClosingPunctuation() {
    let context = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "TensorRT"),
    ])
    for (raw, expected) in [
      ("Use (Tensor RT).", "Use (TensorRT)."),
      ("Use [Tensor RT], please.", "Use [TensorRT], please."),
      ("Use \"Tensor RT\".", "Use \"TensorRT\"."),
      ("Use “Tensor RT”.", "Use “TensorRT”."),
    ] {
      let result = LocalTranscriptCorrection.guardCandidate(
        rawText: raw, candidateText: expected, context: context, policy: .strict
      )
      XCTAssertEqual(result.text, expected)
      XCTAssertEqual(result.outcome, .applied)
    }
  }

  func testGuardDoesNotDuplicatePunctuationInsideCanonicalTerms() {
    for (raw, expected, canonical) in [
      ("Use (.net).", "Use (.NET).", ".NET"),
      ("Use (c++).", "Use (C++).", "C++"),
    ] {
      let result = LocalTranscriptCorrection.guardCandidate(
        rawText: raw, candidateText: expected,
        context: LocalInvocationContext(permanentEntries: [LocalVocabularyEntry(canonicalText: canonical)]),
        policy: .strict
      )
      XCTAssertEqual(result.text, expected)
      XCTAssertEqual(result.outcome, .applied)
    }
  }

  func testGuardRejectsDeletionInsertionAndNoncanonicalReplacement() {
    let context = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "Kubernetes"),
    ])

    XCTAssertEqual(
      LocalTranscriptCorrection.guardCandidate(
        rawText: "say hello",
        candidateText: "say Kubernetes hello",
        context: context,
        policy: .strict
      ).text,
      "say hello"
    )
    XCTAssertEqual(
      LocalTranscriptCorrection.guardCandidate(
        rawText: "ask the Quaxal",
        candidateText: "ask Quexal",
        context: LocalInvocationContext(permanentEntries: [
          LocalVocabularyEntry(canonicalText: "Quexal"),
        ]),
        policy: .strict
      ).text,
      "ask the Quaxal"
    )
  }

  func testProtectedWordConsumptionRequiresExplicitAlias() {
    let withoutAlias = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "Quexal"),
    ])
    let withAlias = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "Quexal", explicitAliases: ["the Quaxal"]),
    ])

    XCTAssertEqual(
      LocalTranscriptCorrection.guardCandidate(
        rawText: "ask the Quaxal",
        candidateText: "ask Quexal",
        context: withoutAlias,
        policy: .strict
      ).text,
      "ask the Quaxal"
    )
    XCTAssertEqual(
      LocalTranscriptCorrection.guardCandidate(
        rawText: "ask the Quaxal",
        candidateText: "ask Quexal",
        context: withAlias,
        policy: .strict
      ).text,
      "ask Quexal"
    )
  }

  func testGuardHandlesUnicodeTermsWithoutMatchingInsideAnotherWord() {
    let context = LocalInvocationContext(permanentEntries: [
      LocalVocabularyEntry(canonicalText: "München"),
    ])

    XCTAssertEqual(
      LocalTranscriptCorrection.guardCandidate(
        rawText: "visit munch en, please",
        candidateText: "visit München please",
        context: context,
        policy: .strict
      ).text,
      "visit München, please"
    )
  }
}
