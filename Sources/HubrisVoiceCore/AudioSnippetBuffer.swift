import Foundation

public struct AudioSnippetBuffer: Equatable, Sendable {
  public enum AppendResult: Equatable, Sendable {
    case stored
    case full
  }

  public static let defaultCapacityBytes = 24_000 * 2 * 90

  public let capacityBytes: Int
  public private(set) var chunks: [Data] = []
  public private(set) var byteCount = 0
  public private(set) var isFull = false

  public init(capacityBytes: Int = Self.defaultCapacityBytes) {
    precondition(capacityBytes >= 0)
    self.capacityBytes = capacityBytes
  }

  public mutating func append(_ chunk: Data) -> AppendResult {
    guard !isFull, chunk.count <= capacityBytes - byteCount else {
      isFull = true
      return .full
    }
    chunks.append(chunk)
    byteCount += chunk.count
    isFull = byteCount == capacityBytes
    return .stored
  }
}
