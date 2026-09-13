import Foundation
@testable import HubrisVoiceApp
import XCTest

final class LocalModelInstallationSmokeTests: XCTestCase {
  func testExplicitDownloadAndVerifiedLease() async throws {
    guard ProcessInfo.processInfo.environment["HUBRIS_LOCAL_MODEL_INSTALL_SMOKE"] == "1" else {
      throw XCTSkip("Explicit opt-in downloads approximately 711 MB of pinned model files.")
    }
    let root = LocalModelStore.defaultRoot.deletingLastPathComponent()
      .appendingPathComponent("Experiments/installation-smoke", isDirectory: true)
    let store = LocalModelStore(root: root)
    for model in LocalModelCatalog.models {
      try await store.install(model.id)
      let lease = try await store.acquire(model.id)
      XCTAssertTrue(FileManager.default.fileExists(atPath: lease.directory.path))
      await store.release(lease)
    }
  }
}
