import AppKit
import Combine
import SwiftUI

enum OverlayMode: Equatable {
  case listening
  case finalizing
  case completed
  case attention

  var title: String {
    switch self {
    case .listening:
      "Listening"
    case .finalizing:
      "Finalizing"
    case .completed:
      "Pasted"
    case .attention:
      "Transcript ready"
    }
  }

  var color: Color {
    switch self {
    case .listening:
      .signalBlue
    case .finalizing, .attention:
      .voiceCoral
    case .completed:
      .completionMint
    }
  }
}

@MainActor
final class OverlayViewModel: ObservableObject {
  @Published var mode: OverlayMode = .listening
  @Published var transcript = ""
  @Published var message = "Hold ⌃⇧Space · release to paste"
  @Published var elapsed: TimeInterval = 0
  @Published var levels: [Float] = Array(repeating: 0.08, count: 22)
  @Published var canCopy = false

  func beginListening() {
    mode = .listening
    transcript = ""
    message = "Hold ⌃⇧Space · release to paste"
    elapsed = 0
    levels = Array(repeating: 0.08, count: 22)
    canCopy = false
  }

  func record(level: Float) {
    levels.removeFirst()
    levels.append(max(0.08, level))
  }
}

@MainActor
final class OverlayController {
  private let panel: NSPanel

  init(
    model: OverlayViewModel,
    onCopy: @escaping () -> Void,
    onDismiss: @escaping () -> Void
  ) {
    panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 540, height: 178),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    panel.level = .floating
    panel.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .transient,
    ]
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.contentView = NSHostingView(
      rootView: OverlayView(
        model: model,
        onCopy: onCopy,
        onDismiss: onDismiss
      )
    )
  }

  func show() {
    positionOnActiveScreen()
    panel.orderFrontRegardless()
  }

  func hide() {
    panel.orderOut(nil)
  }

  private func positionOnActiveScreen() {
    let mouseLocation = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { screen in
        screen.frame.contains(mouseLocation)
      } ?? NSScreen.main ?? NSScreen.screens.first
    guard let screen else {
      return
    }

    let size = panel.frame.size
    let visibleFrame = screen.visibleFrame
    panel.setFrameOrigin(
      NSPoint(
        x: visibleFrame.midX - size.width / 2,
        y: visibleFrame.minY + 44
      )
    )
  }
}

private struct OverlayView: View {
  @ObservedObject var model: OverlayViewModel
  let onCopy: () -> Void
  let onDismiss: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Circle()
          .fill(model.mode.color)
          .frame(width: 8, height: 8)
        Text(model.mode.title)
          .font(.system(size: 13, weight: .semibold, design: .rounded))
        Spacer()
        Text(timeLabel)
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.fog.opacity(0.58))
      }

      Text(
        model.transcript.isEmpty
          ? "Start speaking…"
          : model.transcript
      )
      .font(.system(size: 18, weight: .medium, design: .rounded))
      .foregroundStyle(
        model.transcript.isEmpty ? Color.fog.opacity(0.42) : .fog
      )
      .lineLimit(2)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)

      AudioInkView(
        levels: model.levels,
        color: model.mode.color,
        reduceMotion: reduceMotion
      )
      .frame(height: 22)

      HStack {
        Text(model.message)
          .font(.system(size: 11, weight: .regular))
          .foregroundStyle(Color.fog.opacity(0.58))
        Spacer()
        if model.canCopy {
          Button("Copy", action: onCopy)
            .buttonStyle(.borderedProminent)
            .tint(model.mode.color)
          Button("Dismiss", action: onDismiss)
            .buttonStyle(.plain)
            .foregroundStyle(Color.fog.opacity(0.7))
        }
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .background {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.carbon.opacity(0.96))
        .overlay {
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Color.white.opacity(0.1), lineWidth: 1)
        }
    }
    .padding(8)
  }

  private var timeLabel: String {
    let seconds = Int(model.elapsed)
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}

private struct AudioInkView: View {
  let levels: [Float]
  let color: Color
  let reduceMotion: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 3) {
      ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
        Capsule(style: .continuous)
          .fill(color.opacity(0.9))
          .frame(
            maxWidth: .infinity,
            minHeight: 2,
            maxHeight: max(2, CGFloat(level) * 22)
          )
      }
    }
    .animation(
      reduceMotion ? nil : .easeOut(duration: 0.08),
      value: levels
    )
  }
}

extension Color {
  static let carbon = Color(
    red: 0x12 / 255,
    green: 0x14 / 255,
    blue: 0x17 / 255
  )
  static let slate = Color(
    red: 0x24 / 255,
    green: 0x28 / 255,
    blue: 0x2E / 255
  )
  static let fog = Color(
    red: 0xE8 / 255,
    green: 0xEC / 255,
    blue: 0xEF / 255
  )
  static let signalBlue = Color(
    red: 0x62 / 255,
    green: 0xA8 / 255,
    blue: 0xFF / 255
  )
  static let voiceCoral = Color(
    red: 0xFF / 255,
    green: 0x74 / 255,
    blue: 0x66 / 255
  )
  static let completionMint = Color(
    red: 0x6D / 255,
    green: 0xD6 / 255,
    blue: 0xA0 / 255
  )
}
