import Foundation

/// Sizes the pill overlay from measured text. The app measures with the real
/// font and reports a width and line count; this policy owns the arithmetic
/// so the cap and chrome rules stay testable.
public struct PillLayoutPolicy: Equatable, Sendable {
  public var lineHeight: Double
  public var lineCap: Int
  public var verticalPadding: Double
  public var leadingPadding: Double
  public var barsWidth: Double
  public var textGap: Double
  public var trailingPadding: Double
  public var maximumWidth: Double

  public init(
    lineHeight: Double = 22,
    lineCap: Int = 3,
    verticalPadding: Double = 10,
    leadingPadding: Double = 14,
    barsWidth: Double = 22,
    textGap: Double = 12,
    trailingPadding: Double = 16,
    maximumWidth: Double = 440
  ) {
    self.lineHeight = lineHeight
    self.lineCap = lineCap
    self.verticalPadding = verticalPadding
    self.leadingPadding = leadingPadding
    self.barsWidth = barsWidth
    self.textGap = textGap
    self.trailingPadding = trailingPadding
    self.maximumWidth = maximumWidth
  }

  public var isSingleLine: Bool {
    lineCap <= 1
  }

  /// Widest the text column can be before wrapping or scrolling.
  public var maximumTextWidth: Double {
    maximumWidth - leadingPadding - barsWidth - textGap - trailingPadding
  }

  public func visibleLines(measuredLines: Int) -> Int {
    max(1, min(measuredLines, max(1, lineCap)))
  }

  /// `measuredTextWidth` is the wider of the transcript and the message line;
  /// zero means there is no text and the pill collapses to the bars.
  /// `messageHeight` is added below the transcript when a message is shown.
  public func panelSize(
    measuredTextWidth: Double,
    measuredLines: Int,
    messageHeight: Double = 0
  ) -> LayoutSize {
    let textWidth = min(max(0, measuredTextWidth), maximumTextWidth)
    let textColumn = textWidth > 0 ? textGap + textWidth : 0
    let width = leadingPadding + barsWidth + textColumn + trailingPadding
    let textHeight = Double(visibleLines(measuredLines: measuredLines)) * lineHeight
    let height = verticalPadding * 2 + textHeight + messageHeight
    return LayoutSize(width: width, height: height)
  }
}

@MainActor
public final class DelayedActionScheduler {
  private var task: Task<Void, Never>?
  private let sleep: @Sendable (Duration) async throws -> Void

  public convenience init() {
    self.init(sleep: { try await Task.sleep(for: $0) })
  }

  init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
    self.sleep = sleep
  }

  deinit {
    task?.cancel()
  }

  public func schedule(
    after delay: Duration,
    action: @escaping @MainActor @Sendable () -> Void
  ) {
    cancel()
    let sleep = sleep
    task = Task { @MainActor [weak self] in
      do {
        try await sleep(delay)
      } catch {
        return
      }
      guard !Task.isCancelled else {
        return
      }
      action()
      self?.task = nil
    }
  }

  public func cancel() {
    task?.cancel()
    task = nil
  }
}
