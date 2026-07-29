public struct CompletedTranscript: Equatable, Sendable {
  public let itemID: String
  public let text: String

  public init(itemID: String, text: String) {
    self.itemID = itemID
    self.text = text
  }
}

public struct TranscriptAssembler: Sendable {
  private var transcripts: [String: String] = [:]

  public init() {}

  @discardableResult
  public mutating func apply(
    _ event: RealtimeServerEvent
  ) -> CompletedTranscript? {
    switch event {
    case .transcriptDelta(let itemID, let delta):
      transcripts[itemID, default: ""] += delta
      return nil
    case .transcriptCompleted(let itemID, let transcript):
      transcripts[itemID] = transcript
      return CompletedTranscript(itemID: itemID, text: transcript)
    case .sessionReady, .inputCommitted, .error, .ignored:
      return nil
    }
  }

  public func preview(for itemID: String) -> String? {
    transcripts[itemID]
  }

  public mutating func remove(itemID: String) {
    transcripts.removeValue(forKey: itemID)
  }
}
