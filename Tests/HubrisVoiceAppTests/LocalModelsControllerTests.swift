import Foundation
@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

@MainActor
final class LocalModelsControllerTests: XCTestCase {
  func testCorrectionRemovalPreservesManualUnloadAndRestoresPriorReadiness() async throws {
    let fixture = try makeFixture()
    defer { fixture.clean() }
    let controller = fixture.controller
    var events: [String] = []
    let finished = expectation(description: "removal finished")
    controller.onUnload = { events.append("manual-unload") }
    controller.onPrepareSupplementalRemoval = {
      events.append("prepare-supplemental")
      return true
    }
    controller.onSupplementalRemovalFinished = { restoreReadiness in
      events.append("finish-supplemental:\(restoreReadiness)")
      finished.fulfill()
    }

    controller.remove(LocalModelCatalog.correctionID)
    await fulfillment(of: [finished], timeout: 2)

    XCTAssertEqual(events, ["prepare-supplemental", "finish-supplemental:true"])
  }

  func testPrimaryRemovalKeepsExplicitUnloadSemantics() async throws {
    let fixture = try makeFixture()
    defer { fixture.clean() }
    let controller = fixture.controller
    controller.engine = .fluidAudio
    var events: [String] = []
    let rechecked = expectation(description: "primary readiness rechecked")
    controller.onUnload = { events.append("manual-unload") }
    controller.onPrepareSupplementalRemoval = {
      events.append("prepare-supplemental")
      return true
    }
    controller.onLoad = {
      events.append("load")
      rechecked.fulfill()
    }

    controller.remove(LocalModelCatalog.primaryID)
    await fulfillment(of: [rechecked], timeout: 2)

    XCTAssertEqual(events, ["manual-unload", "load"])
  }

  private func makeFixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("HubrisVoice-LocalModelsControllerTests-\(UUID().uuidString)")
    let suite = "HubrisVoice.LocalModelsControllerTest.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let store = LocalModelStore(root: root)
    return Fixture(
      controller: LocalModelsController(settings: UserDefaultsSettingsStore(defaults), store: store),
      defaults: defaults,
      suite: suite,
      root: root
    )
  }
}

private struct Fixture {
  let controller: LocalModelsController
  let defaults: UserDefaults
  let suite: String
  let root: URL

  func clean() {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
}
