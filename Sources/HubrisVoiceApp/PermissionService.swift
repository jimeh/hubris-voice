import AppKit
import ApplicationServices
import AVFoundation
import Foundation

enum MicrophonePermission: Equatable {
  case authorized
  case denied
  case notDetermined
  case restricted

  var label: String {
    switch self {
    case .authorized:
      "Allowed"
    case .denied:
      "Denied"
    case .notDetermined:
      "Not requested"
    case .restricted:
      "Restricted"
    }
  }
}

@MainActor
enum PermissionService {
  enum SystemPermission {
    case microphone
    case accessibility
    case inputMonitoring
  }

  static var microphone: MicrophonePermission {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      .authorized
    case .denied:
      .denied
    case .notDetermined:
      .notDetermined
    case .restricted:
      .restricted
    @unknown default:
      .restricted
    }
  }

  static var accessibilityTrusted: Bool {
    AXIsProcessTrusted()
  }

  static var inputMonitoring: Bool {
    CGPreflightListenEventAccess()
  }

  static func requestMicrophone() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  @discardableResult
  static func requestAccessibility() -> Bool {
    AXIsProcessTrustedWithOptions(
      ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    )
  }

  @discardableResult
  static func requestInputMonitoring() -> Bool {
    CGRequestListenEventAccess()
  }

  static func openSystemSettings(for permission: SystemPermission) {
    let pane = switch permission {
    case .microphone: "Privacy_Microphone"
    case .accessibility: "Privacy_Accessibility"
    case .inputMonitoring: "Privacy_ListenEvent"
    }
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
    ) else {
      return
    }
    NSWorkspace.shared.open(url)
  }
}
