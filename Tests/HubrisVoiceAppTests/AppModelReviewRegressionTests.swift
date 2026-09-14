import Foundation
@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

@MainActor
final class AppModelReviewRegressionTests: XCTestCase {
  func testConfigurationCompletionRequiresSameBackendAndEpoch() {
    let original = NSObject()
    let replacement = NSObject()
    let epoch = TranscriptionBackendEpoch(4)

    XCTAssertTrue(AppModelCoordinationPolicy.acceptsConfigurationCompletion(
      capturedBackendID: ObjectIdentifier(original),
      currentBackendID: ObjectIdentifier(original),
      capturedEpoch: epoch,
      currentEpoch: epoch
    ))
    XCTAssertFalse(AppModelCoordinationPolicy.acceptsConfigurationCompletion(
      capturedBackendID: ObjectIdentifier(original),
      currentBackendID: ObjectIdentifier(replacement),
      capturedEpoch: epoch,
      currentEpoch: epoch
    ))
    XCTAssertFalse(AppModelCoordinationPolicy.acceptsConfigurationCompletion(
      capturedBackendID: ObjectIdentifier(original),
      currentBackendID: ObjectIdentifier(original),
      capturedEpoch: epoch,
      currentEpoch: .init(5)
    ))
  }

  func testTargetedLocalFailureRecordsPartialTranscriptForRecovery() throws {
    var session = DictationSession(
      configuration: .init(format: .local),
      readiness: .ready
    )
    _ = session.transition(.pressed)
    let invocationID = try XCTUnwrap(session.listening?.id)
    _ = session.transition(.engine(.preview(id: invocationID, text: "unfinished local preview")))
    let suite = "HubrisVoice.AppModelReviewRegressionTest.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.set(
      TranscriptionEngineSelection.fluidAudio.rawValue,
      forKey: TranscriptionPreferences.Key.engine
    )
    addTeardownBlock {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
    let model = AppModel(defaults: defaults, initialSession: session)

    model.testingHandleEngineEvent(.failure(
      epoch: invocationID.epoch,
      id: invocationID,
      failure: .init(kind: .transcription, message: "Local failure", isRecoverable: false)
    ))

    XCTAssertEqual(model.history.latest?.text, "unfinished local preview")
    XCTAssertEqual(model.history.latest?.outcome, .rejected)
    XCTAssertEqual(model.overlayModel.message, "Local failure · Copy it from the menu bar")
  }
}
