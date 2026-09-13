import AppKit
import HubrisVoiceCore
import SwiftUI

struct KeyCap: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(.body, design: .monospaced, weight: .semibold))
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Color.slate.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
  }
}

/// Captures the next chord or lone modifier key pressed while the Settings
/// window is key and assigns it to a shortcut role.
struct ShortcutRecorder: View {
  @ObservedObject var model: AppModel
  let binding: ShortcutBinding?
  let role: ShortcutRole
  let allowsClear: Bool

  @State private var isRecording = false
  @State private var hint: String?
  @State private var monitor: Any?

  var body: some View {
    HStack(spacing: 8) {
      if isRecording {
        Text(hint ?? "Press keys…")
          .font(.caption)
          .foregroundStyle(hint == nil ? .secondary : Color.voiceCoral)
          .frame(minWidth: 120, alignment: .trailing)
        Button("Cancel") { stopRecording() }
      } else {
        if let binding {
          KeyCap(text: binding.displayName)
        } else {
          Text("Off")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Button("Record…") { startRecording() }
          .disabled(model.isRecordingShortcut)
        if allowsClear, binding != nil {
          Button("Clear") { model.setShortcut(nil, for: role) }
        }
      }
    }
    .onDisappear { stopRecording() }
  }

  private func startRecording() {
    guard monitor == nil, model.beginShortcutRecording(for: role) else { return }
    isRecording = true
    hint = nil
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
      handle(event) ? nil : event
    }
  }

  private func stopRecording() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
    monitor = nil
    isRecording = false
    model.endShortcutRecording(for: role)
  }

  /// Returns true when the event was consumed by the recorder.
  private func handle(_ event: NSEvent) -> Bool {
    switch event.type {
    case .flagsChanged:
      guard
        let modifier = ModifierKey.allCases.first(where: { $0.keyCode == event.keyCode }),
        event.modifierFlags.contains(modifier.eventFlag)
      else {
        return false
      }
      assign(.modifier(modifier))
      return true
    case .keyDown:
      if event.keyCode == 53 {
        stopRecording()
        return true
      }
      let modifiers = KeyModifiers(flags: event.modifierFlags)
      guard !modifiers.isEmpty else {
        hint = "Add a modifier, or use Fn or a right-side key alone"
        return true
      }
      assign(.chord(GlobalShortcut(keyCode: event.keyCode, modifiers: modifiers)))
      return true
    default:
      return false
    }
  }

  private func assign(_ binding: ShortcutBinding) {
    model.setShortcut(binding, for: role)
    stopRecording()
  }
}

private extension ModifierKey {
  var eventFlag: NSEvent.ModifierFlags {
    switch self {
    case .fn: .function
    case .rightCommand: .command
    case .rightOption: .option
    case .rightControl: .control
    case .rightShift: .shift
    }
  }
}

private extension KeyModifiers {
  init(flags: NSEvent.ModifierFlags) {
    var modifiers: KeyModifiers = []
    if flags.contains(.control) {
      modifiers.insert(.control)
    }
    if flags.contains(.shift) {
      modifiers.insert(.shift)
    }
    if flags.contains(.command) {
      modifiers.insert(.command)
    }
    if flags.contains(.option) {
      modifiers.insert(.option)
    }
    self = modifiers
  }
}
