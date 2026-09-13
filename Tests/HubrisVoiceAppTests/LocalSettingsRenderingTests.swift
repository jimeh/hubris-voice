import AppKit
import Foundation
@testable import HubrisVoiceApp
import HubrisVoiceCore
import SwiftUI
import XCTest

@MainActor
final class LocalSettingsRenderingTests: XCTestCase {
  func testRenderLocalSettings() async throws {
    guard ProcessInfo.processInfo.environment["HUBRIS_LOCAL_UI_SMOKE"] == "1" else {
      throw XCTSkip("Opt-in native settings rendering.")
    }
    let suite = "com.jimeh.HubrisVoice.UIFixture.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("fluidAudio", forKey: TranscriptionPreferences.Key.engine)
    let model = AppModel(defaults: defaults)
    await model.localModels.refresh()
    model.localModels.loadState = .loaded
    model.localModels.entries = [
      LocalVocabularyEntry(canonicalText: "user_id", explicitAliases: ["user identifier"]),
      LocalVocabularyEntry(canonicalText: "URLSession"),
    ]
    model.localModels.pendingConfiguration = false
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/local-ui", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try render(ModelsSettingsTab(models: model.localModels), to: root.appendingPathComponent("models.png"))
    try render(DictationSettingsTab(model: model), to: root.appendingPathComponent("dictation.png"))
    try render(DictionarySettingsTab(model: model), to: root.appendingPathComponent("dictionary.png"))
  }

  private func render(_ view: some View, to url: URL) throws {
    let host = NSHostingView(rootView: view)
    let frame = NSRect(x: 0, y: 0, width: 640, height: 560)
    let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.frame = frame
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: url)
    XCTAssertGreaterThan(data.count, 5_000)
    window.close()
  }
}
