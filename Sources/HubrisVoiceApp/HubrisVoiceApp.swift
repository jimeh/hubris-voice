import AppKit
import HubrisVoiceCore
import SwiftUI

@MainActor
final class AppEnvironment {
  static let shared = AppEnvironment()

  let model: AppModel
  let overlay: OverlayController

  private init() {
    let model = AppModel()
    self.model = model
    overlay = OverlayController(model: model.overlayModel)
    model.overlayController = overlay
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var isDuplicateInstance = false

  func applicationWillFinishLaunching(_ notification: Notification) {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
      return
    }

    let currentProcessID = ProcessInfo.processInfo.processIdentifier
    let runningProcessIDs = NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier
    ).map(\.processIdentifier)
    guard
      SingleInstancePolicy.shouldTerminate(
        currentProcessID: currentProcessID,
        runningProcessIDs: runningProcessIDs
      )
    else {
      return
    }

    isDuplicateInstance = true
    NSApplication.shared.terminate(nil)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !isDuplicateInstance else {
      return
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    AppEnvironment.shared.model.start()
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    guard !isDuplicateInstance else {
      return
    }
    AppEnvironment.shared.model.refreshPermissions()
  }
}

@main
@MainActor
struct HubrisVoiceApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var model = AppEnvironment.shared.model

  var body: some Scene {
    MenuBarExtra(
      "Hubris Voice",
      systemImage: model.menuSystemImage
    ) {
      MenuBarContent(model: model)
    }
    .menuBarExtraStyle(.menu)

    Settings {
      SettingsView(model: model)
    }
    .windowResizability(.contentSize)
  }
}
