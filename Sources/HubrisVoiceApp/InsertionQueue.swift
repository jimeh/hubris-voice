import Foundation

/// Keeps clipboard writes ordered until the preceding paste has had time to consume them.
@MainActor
final class InsertionQueue {
  private var tail: Task<Void, Never>?

  @discardableResult
  func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
    let previous = tail
    let task = Task {
      await previous?.value
      await operation()
    }
    tail = task
    return task
  }
}
