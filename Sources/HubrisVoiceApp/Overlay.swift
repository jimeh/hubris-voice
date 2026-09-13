import AppKit
import Combine
import HubrisVoiceCore
import SwiftUI

enum OverlayMode: Equatable {
  case listening
  case finalizing
  case attention

  var title: String {
    switch self {
    case .listening:
      "Listening"
    case .finalizing:
      "Finalizing"
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
  @Published var pendingCount = 0
  @Published var isLocked = false

  var transcriptViewportHeight: CGFloat {
    OverlayLayout.transcriptViewportHeight(for: transcript)
  }

  func beginListening() {
    mode = .listening
    transcript = ""
    message = "Hold ⌃⇧Space · release to paste"
    elapsed = 0
    levels = Array(repeating: 0.08, count: 22)
    pendingCount = 0
    isLocked = false
  }

  func apply(_ presentation: OverlayPresentation) {
    mode = switch presentation.mode {
    case .listening: .listening
    case .finalizing: .finalizing
    case .attention: .attention
    }
    transcript = presentation.transcript
    message = presentation.message
    pendingCount = presentation.pendingCount
    isLocked = presentation.isLocked
  }

  func record(level: Float) {
    levels.removeFirst()
    levels.append(max(0.08, level))
  }
}

@MainActor
final class OverlayController {
  private let model: OverlayViewModel
  private let panel: NSPanel
  private let hostingView: NSHostingView<OverlayView>
  private let placement = OverlayPlacement()
  private var cancellables: Set<AnyCancellable> = []
  private var anchor: OverlayAnchor?
  private var preference = OverlayPlacementPreference.automatic

  var panelFrame: NSRect {
    panel.frame
  }

  var hostingSizingOptions: NSHostingSizingOptions {
    hostingView.sizingOptions
  }

  init(model: OverlayViewModel) {
    self.model = model
    hostingView = NSHostingView(
      rootView: OverlayView(model: model)
    )
    hostingView.sizingOptions = []
    panel = NSPanel(
      contentRect: NSRect(
        x: 0,
        y: 0,
        width: OverlayLayout.panelWidth,
        height: OverlayLayout.panelHeight(for: "")
      ),
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
    panel.contentView = hostingView

    model.$transcript
      .removeDuplicates()
      .sink { [weak self] transcript in
        self?.resizeForTranscript(transcript)
      }
      .store(in: &cancellables)
  }

  func show(
    anchor: OverlayAnchor?,
    preference: OverlayPlacementPreference
  ) {
    self.anchor = anchor
    self.preference = preference
    resizeForTranscript(model.transcript)
    guard !panel.isVisible else {
      return
    }
    panel.orderFrontRegardless()
  }

  func hide() {
    panel.orderOut(nil)
  }

  private func resizeForTranscript(_ transcript: String) {
    let height = OverlayLayout.panelHeight(for: transcript)
    let size = NSSize(width: OverlayLayout.panelWidth, height: height)
    guard let screen = targetScreen() else {
      panel.setFrame(
        NSRect(origin: panel.frame.origin, size: size),
        display: true
      )
      return
    }
    let origin = placement.origin(
      anchor: anchor,
      preference: preference,
      panelSize: LayoutSize(size),
      visibleFrame: LayoutRect(screen.visibleFrame)
    )
    panel.setFrame(
      NSRect(
        origin: NSPoint(origin),
        size: size
      ),
      display: true
    )
  }

  private func targetScreen() -> NSScreen? {
    if let anchor {
      let center = NSPoint(x: anchor.rect.midX, y: anchor.rect.midY)
      return NSScreen.screens.first { $0.frame.contains(center) }
    }
    let mouseLocation = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
      ?? NSScreen.main
      ?? NSScreen.screens.first
  }
}

private extension LayoutPoint {
  init(_ point: NSPoint) {
    self.init(x: point.x, y: point.y)
  }
}

private extension LayoutSize {
  init(_ size: NSSize) {
    self.init(width: size.width, height: size.height)
  }
}

private extension LayoutRect {
  init(_ rect: NSRect) {
    self.init(
      origin: LayoutPoint(rect.origin),
      size: LayoutSize(rect.size)
    )
  }
}

private extension NSPoint {
  init(_ point: LayoutPoint) {
    self.init(x: point.x, y: point.y)
  }
}

private struct OverlayView: View {
  @ObservedObject var model: OverlayViewModel

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Circle()
          .fill(model.mode.color)
          .frame(width: 8, height: 8)
        Text(model.mode.title)
          .font(.system(size: 13, weight: .semibold, design: .rounded))
        if model.isLocked {
          Image(systemName: "lock.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(model.mode.color)
            .accessibilityLabel("Recording locked")
        }
        Spacer()
        Text(timeLabel)
          .font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.fog.opacity(0.58))
        if model.pendingCount > 0 {
          Text("+\(model.pendingCount)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.fog.opacity(0.58))
        }
      }

      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 0) {
            Text(
              model.transcript.isEmpty
                ? "Start speaking…"
                : model.transcript
            )
            .font(
              .system(size: 18, weight: .medium, design: .rounded)
            )
            .foregroundStyle(
              model.transcript.isEmpty ? Color.fog.opacity(0.42) : .fog
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Color.clear
              .frame(height: 1)
              .id(TranscriptScrollAnchor.bottom)
          }
        }
        .scrollIndicators(.hidden)
        .frame(height: model.transcriptViewportHeight)
        .defaultScrollAnchor(.bottom)
        .onChange(of: model.transcript) {
          proxy.scrollTo(TranscriptScrollAnchor.bottom, anchor: .bottom)
        }
      }

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
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(
      maxWidth: .infinity,
      maxHeight: .infinity,
      alignment: .topLeading
    )
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

private enum TranscriptScrollAnchor {
  static let bottom = "transcript-bottom"
}

@MainActor
private enum OverlayLayout {
  static let panelWidth: CGFloat = 540
  static let minimumTranscriptHeight: CGFloat = 44
  static let maximumTranscriptHeight: CGFloat = 132
  static let panelChromeHeight: CGFloat = 134
  static let transcriptWidth: CGFloat = panelWidth - 56

  static let policy = OverlayLayoutPolicy(
    minimumTranscriptHeight: Double(minimumTranscriptHeight),
    maximumTranscriptHeight: Double(maximumTranscriptHeight),
    panelChromeHeight: Double(panelChromeHeight)
  )

  private static let transcriptFont: NSFont = {
    let base = NSFont.systemFont(ofSize: 18, weight: .medium)
    guard
      let descriptor = base.fontDescriptor.withDesign(.rounded),
      let rounded = NSFont(descriptor: descriptor, size: 18)
    else {
      return base
    }
    return rounded
  }()

  static func transcriptViewportHeight(for transcript: String) -> CGFloat {
    CGFloat(
      policy.transcriptViewportHeight(
        measuredTextHeight: Double(measuredTextHeight(for: transcript))
      )
    )
  }

  static func panelHeight(for transcript: String) -> CGFloat {
    CGFloat(
      policy.panelHeight(
        measuredTextHeight: Double(measuredTextHeight(for: transcript))
      )
    )
  }

  private static func measuredTextHeight(for transcript: String) -> CGFloat {
    let text = transcript.isEmpty ? "Start speaking…" : transcript
    let bounds = (text as NSString).boundingRect(
      with: NSSize(
        width: transcriptWidth,
        height: .greatestFiniteMagnitude
      ),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: transcriptFont]
    )
    return ceil(bounds.height)
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
    blue: 0x2e / 255
  )
  static let fog = Color(
    red: 0xe8 / 255,
    green: 0xec / 255,
    blue: 0xef / 255
  )
  static let signalBlue = Color(
    red: 0x62 / 255,
    green: 0xa8 / 255,
    blue: 0xff / 255
  )
  static let voiceCoral = Color(
    red: 0xff / 255,
    green: 0x74 / 255,
    blue: 0x66 / 255
  )
  static let completionMint = Color(
    red: 0x6d / 255,
    green: 0xd6 / 255,
    blue: 0xa0 / 255
  )
}
