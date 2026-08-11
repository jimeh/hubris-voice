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

  static func requestMicrophone() async -> Bool {
    await AVCaptureDevice.requestAccess(for: .audio)
  }

  @discardableResult
  static func requestAccessibility() -> Bool {
    AXIsProcessTrustedWithOptions(
      ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    )
  }
}
