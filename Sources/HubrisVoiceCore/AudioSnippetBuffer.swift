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

  public init(sampleRate: Int, maximumDuration: Int = 90) {
    precondition(sampleRate == 16_000 || sampleRate == 24_000)
    precondition(maximumDuration >= 0 && maximumDuration <= 90)
    self.init(capacityBytes: sampleRate * MemoryLayout<Int16>.size * maximumDuration)
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
