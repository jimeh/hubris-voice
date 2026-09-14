import Foundation
@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

@MainActor
final class LocalModelsControllerTests: XCTestCase {
  func testInvalidVocabularyDisablesEditingAndPreservesPersistedData() throws {
    let fixture = try makeFixture()
    defer { fixture.clean() }
    let encoded = "{not-json"
    fixture.defaults.set(encoded, forKey: LocalVocabularyStore.Key.vocabulary)
    fixture.defaults.removeObject(forKey: LocalVocabularyStore.Key.cloudSeedCompleted)

    let controller = LocalModelsController(
      settings: UserDefaultsSettingsStore(fixture.defaults),
      store: controllerStore(in: fixture.root)
    )

    XCTAssertFalse(controller.isDictionaryAvailable)
    XCTAssertNotNil(controller.dictionaryError)
    controller.entries.append(LocalVocabularyEntry(canonicalText: "MustNotPersist"))
    XCTAssertTrue(controller.entries.isEmpty)
    XCTAssertEqual(fixture.defaults.string(forKey: LocalVocabularyStore.Key.vocabulary), encoded)
    XCTAssertFalse(fixture.defaults.bool(forKey: LocalVocabularyStore.Key.cloudSeedCompleted))
  }

  func testFutureVocabularyVersionReportsDistinctErrorAndPreservesPersistedData() throws {
    let fixture = try makeFixture()
    defer { fixture.clean() }
    let encoded = "{\"version\":2,\"entries\":[]}"
    fixture.defaults.set(encoded, forKey: LocalVocabularyStore.Key.vocabulary)

    let controller = LocalModelsController(
      settings: UserDefaultsSettingsStore(fixture.defaults),
      store: controllerStore(in: fixture.root)
    )

    XCTAssertFalse(controller.isDictionaryAvailable)
    XCTAssertEqual(controller.dictionaryError?.contains("newer version"), true)
    controller.entries = [LocalVocabularyEntry(canonicalText: "MustNotPersist")]
    XCTAssertTrue(controller.entries.isEmpty)
    XCTAssertEqual(fixture.defaults.string(forKey: LocalVocabularyStore.Key.vocabulary), encoded)
  }

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

  private func controllerStore(in root: URL) -> LocalModelStore {
    LocalModelStore(root: root)
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
