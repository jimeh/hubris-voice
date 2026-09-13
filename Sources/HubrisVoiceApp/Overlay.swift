import AppKit
import Combine
import HubrisVoiceCore
import SwiftUI

enum OverlayMode: Equatable {
  case listening
  case finalizing
  case attention
}

@MainActor
final class OverlayViewModel: ObservableObject {
  static let barCount = 5

  @Published var mode: OverlayMode = .listening
  @Published var transcript = ""
  @Published var message = ""
  @Published var levels: [Float] = Array(repeating: 0, count: OverlayViewModel.barCount)
  @Published var pendingCount = 0
  @Published var isLocked = false
  @Published var lineCap = 3
  /// Set by the controller from its measurement so the view and the panel
  /// agree on the text column width and on whether the transcript overflows.
  @Published var overflows = false
  @Published var textWidth: CGFloat = 0

  func beginListening() {
    mode = .listening
    transcript = ""
    message = ""
    levels = Array(repeating: 0, count: Self.barCount)
    pendingCount = 0
    isLocked = false
    overflows = false
  }

  func apply(_ presentation: OverlayPresentation) {
    mode = switch presentation.mode {
    case .listening: .listening
    case .finalizing: .finalizing
    case .attention: .attention
    }
    // Match final transcript leading whitespace cleanup without changing streamed word boundaries.
    transcript = String(presentation.transcript.drop(while: \.isWhitespace))
    message = presentation.message
    pendingCount = presentation.pendingCount
    isLocked = presentation.isLocked
  }

  func record(level: Float) {
    levels.removeFirst()
    levels.append(max(0, min(1, level)))
  }
}

@MainActor
final class OverlayController {
  private let model: OverlayViewModel
  private let panel: NSPanel
  private let hostingView: NSHostingView<PillView>
  private let placement = OverlayPlacement()
  private var cancellables: Set<AnyCancellable> = []
  private var anchor: OverlayAnchor?
  private var preference = OverlayPlacementPreference.automatic

  var lineCap: Int {
    get { model.lineCap }
    set {
      let clamped = max(1, min(newValue, 6))
      guard clamped != model.lineCap else { return }
      model.lineCap = clamped
    }
  }

  var panelFrame: NSRect {
    panel.frame
  }

  var hostingSizingOptions: NSHostingSizingOptions {
    hostingView.sizingOptions
  }

  init(model: OverlayViewModel) {
    self.model = model
    hostingView = NSHostingView(rootView: PillView(model: model))
    hostingView.sizingOptions = []
    panel = NSPanel(
      contentRect: NSRect(
        origin: .zero,
        size: NSSize(width: 52, height: 20 + PillLayout.lineHeight)
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
    panel.ignoresMouseEvents = true
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.contentView = hostingView

    // Published values arrive before the property changes, so the layout
    // works from the emitted snapshot rather than reading the model back.
    // Nothing is laid out while hidden: the subscription fires on creation,
    // which happens inside SwiftUI's app graph update, and forcing the
    // hosting view to render there aborts the process.
    Publishers.CombineLatest(
      Publishers.CombineLatest3(model.$transcript, model.$message, model.$mode),
      Publishers.CombineLatest3(model.$lineCap, model.$pendingCount, model.$isLocked)
    )
    .map { text, chrome in
      LayoutInput(
        transcript: text.0,
        message: text.1,
        mode: text.2,
        lineCap: chrome.0,
        pendingCount: chrome.1,
        isLocked: chrome.2
      )
    }
    .removeDuplicates()
    .sink { [weak self] input in
      guard let self, panel.isVisible else { return }
      layout(input)
    }
    .store(in: &cancellables)
  }

  private struct LayoutInput: Equatable {
    let transcript: String
    let message: String
    let mode: OverlayMode
    let lineCap: Int
    let pendingCount: Int
    let isLocked: Bool
  }

  private var currentInput: LayoutInput {
    LayoutInput(
      transcript: model.transcript,
      message: model.message,
      mode: model.mode,
      lineCap: model.lineCap,
      pendingCount: model.pendingCount,
      isLocked: model.isLocked
    )
  }

  func show(
    anchor: OverlayAnchor?,
    preference: OverlayPlacementPreference
  ) {
    self.anchor = anchor
    self.preference = preference
    layout(currentInput)
    guard !panel.isVisible else {
      return
    }
    panel.orderFrontRegardless()
  }

  func hide() {
    panel.orderOut(nil)
  }

  private func layout(_ input: LayoutInput) {
    let screen = targetScreen()
    let policy = PillLayout.policy(lineCap: input.lineCap, screen: screen)
    let measurement = PillLayout.measure(
      transcript: input.transcript,
      message: input.message,
      badges: PillLayout.badgeWidth(pendingCount: input.pendingCount, isLocked: input.isLocked),
      policy: policy
    )
    model.overflows = measurement.overflows
    model.textWidth = measurement.textWidth
    let size = policy.panelSize(
      measuredTextWidth: measurement.columnWidth,
      measuredLines: measurement.lines,
      messageHeight: measurement.messageHeight
    )
    let panelSize = NSSize(width: size.width, height: size.height)
    guard let screen else {
      panel.setFrame(NSRect(origin: panel.frame.origin, size: panelSize), display: true)
      return
    }
    let origin = placement.origin(
      anchor: anchor,
      preference: preference,
      panelSize: LayoutSize(panelSize),
      visibleFrame: LayoutRect(screen.visibleFrame)
    )
    panel.setFrame(NSRect(origin: NSPoint(origin), size: panelSize), display: true)
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

/// Font metrics and text measurement for the pill. The policy in the core
/// owns the arithmetic; this owns everything that needs AppKit.
@MainActor
enum PillLayout {
  struct Measurement {
    let textWidth: CGFloat
    let columnWidth: CGFloat
    let lines: Int
    let overflows: Bool
    let messageHeight: CGFloat
  }

  static let transcriptFont: NSFont = {
    let base = NSFont.systemFont(ofSize: 15.5, weight: .medium)
    guard
      let descriptor = base.fontDescriptor.withDesign(.rounded),
      let rounded = NSFont(descriptor: descriptor, size: 15.5)
    else {
      return base
    }
    return rounded
  }()

  static let messageFont = NSFont.systemFont(ofSize: 11, weight: .medium)
  static let messageHeight: CGFloat = 18
  /// Drawn after the transcript by the view, so it is measured with it.
  static let caretSuffix = " ▏"
  static let maximumWidth: CGFloat = 440
  static let lineHeight: CGFloat = ceil(
    transcriptFont.ascender - transcriptFont.descender + transcriptFont.leading
  )

  static func policy(lineCap: Int, screen: NSScreen?) -> PillLayoutPolicy {
    var policy = PillLayoutPolicy(lineHeight: Double(lineHeight), lineCap: lineCap)
    if let screen {
      policy.maximumWidth = min(Double(maximumWidth), screen.visibleFrame.width * 0.45)
    }
    return policy
  }

  static func badgeWidth(pendingCount: Int, isLocked: Bool) -> CGFloat {
    (pendingCount > 0 ? 26 : 0) + (isLocked ? 16 : 0)
  }

  /// `badges` is the width the lock glyph and pending count take next to the
  /// bars; it is charged to the text column so the policy's chrome stays
  /// constant.
  static func measure(
    transcript: String,
    message: String,
    badges: CGFloat,
    policy: PillLayoutPolicy
  ) -> Measurement {
    let maximumTextWidth = CGFloat(policy.maximumTextWidth) - badges
    let messageWidth = message.isEmpty ? 0 : min(ceil(width(of: message, font: messageFont)), maximumTextWidth)
    let messageHeight = message.isEmpty ? 0 : messageHeight

    guard !transcript.isEmpty else {
      return Measurement(
        textWidth: 0,
        columnWidth: messageWidth + badges,
        lines: 1,
        overflows: false,
        messageHeight: messageHeight
      )
    }

    let measured = transcript + caretSuffix
    if policy.isSingleLine {
      let natural = ceil(width(of: measured, font: transcriptFont))
      let textWidth = min(natural, maximumTextWidth)
      return Measurement(
        textWidth: textWidth,
        columnWidth: max(textWidth, messageWidth) + badges,
        lines: 1,
        overflows: natural > maximumTextWidth,
        messageHeight: messageHeight
      )
    }

    let bounds = (measured as NSString).boundingRect(
      with: NSSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: transcriptFont]
    )
    let lines = max(1, Int((bounds.height / lineHeight).rounded()))
    let textWidth = lines > 1 ? maximumTextWidth : ceil(bounds.width)
    return Measurement(
      textWidth: textWidth,
      columnWidth: max(textWidth, messageWidth) + badges,
      lines: lines,
      overflows: lines > policy.visibleLines(measuredLines: lines),
      messageHeight: messageHeight
    )
  }

  private static func width(of text: String, font: NSFont) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font]).width
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
