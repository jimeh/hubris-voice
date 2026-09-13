import Foundation

final class CapturedAudioMailbox: @unchecked Sendable {
  enum EnqueueResult: Equatable, Sendable {
    case scheduled(generation: Int)
    case queued
    case full(generation: Int)
    case inactive
  }

  struct Chunk: Sendable {
    let generation: Int
    let data: Data
  }

  private let lock = NSLock()
  private var activeGeneration: Int?
  private var chunks: [Chunk] = []
  private var isDrainScheduled = false
  private let capacity: Int

  init(capacity: Int = 512) {
    self.capacity = capacity
  }

  func transition(to generation: Int) -> [Chunk] {
    lock.lock()
    defer { lock.unlock() }
    let previous = chunks
    activeGeneration = generation
    chunks.removeAll(keepingCapacity: true)
    isDrainScheduled = false
    return previous
  }

  func enqueue(_ data: Data) -> EnqueueResult {
    lock.lock()
    defer { lock.unlock() }
    guard let activeGeneration else { return .inactive }
    guard chunks.count < capacity else { return .full(generation: activeGeneration) }
    chunks.append(.init(generation: activeGeneration, data: data))
    guard !isDrainScheduled else { return .queued }
    isDrainScheduled = true
    return .scheduled(generation: activeGeneration)
  }

  func drain() -> [Chunk] {
    lock.lock()
    defer { lock.unlock() }
    let result = chunks
    chunks.removeAll(keepingCapacity: true)
    isDrainScheduled = false
    return result
  }

  func deactivate(generation: Int) {
    lock.lock()
    if activeGeneration == generation {
      activeGeneration = nil
    }
    lock.unlock()
  }
}
