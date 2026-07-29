import Foundation

public struct OverlayLayoutPolicy: Sendable {
  public let minimumTranscriptHeight: Double
  public let maximumTranscriptHeight: Double
  public let panelChromeHeight: Double

  public init(
    minimumTranscriptHeight: Double,
    maximumTranscriptHeight: Double,
    panelChromeHeight: Double
  ) {
    self.minimumTranscriptHeight = minimumTranscriptHeight
    self.maximumTranscriptHeight = maximumTranscriptHeight
    self.panelChromeHeight = panelChromeHeight
  }

  public func transcriptViewportHeight(
    measuredTextHeight: Double
  ) -> Double {
    min(
      max(measuredTextHeight, minimumTranscriptHeight),
      maximumTranscriptHeight
    )
  }

  public func panelHeight(measuredTextHeight: Double) -> Double {
    panelChromeHeight
      + transcriptViewportHeight(measuredTextHeight: measuredTextHeight)
  }
}

@MainActor
public final class DelayedActionScheduler {
  private var task: Task<Void, Never>?

  public init() {}

  deinit {
    task?.cancel()
  }

  public func schedule(
    after delay: Duration,
    action: @escaping @MainActor @Sendable () -> Void
  ) {
    cancel()
    task = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
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
