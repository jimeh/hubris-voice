import Foundation
import HubrisVoiceCore

/// Keeps the final audio chunks ahead of their commit while allowing a rapid new press.
@MainActor
final class CaptureFinalizer {
  private let scheduler = DelayedActionScheduler()
  private var generation: Int?
  private var stop: (() -> Void)?
  private var commit: (() -> Void)?

  func schedule(generation: Int, stop: @escaping () -> Void) {
    finish()
    self.generation = generation
    self.stop = stop
    scheduler.schedule(after: .milliseconds(100)) { [weak self] in self?.finish() }
  }

  func commitAfterStop(generation: Int, action: @escaping () -> Void) {
    guard self.generation == generation else {
      action()
      return
    }
    commit = action
  }

  func finish() {
    scheduler.cancel()
    let stop = stop
    let commit = commit
    self.stop = nil
    self.commit = nil
    generation = nil
    stop?()
    commit?()
  }
}
