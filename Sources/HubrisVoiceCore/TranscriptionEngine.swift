import Foundation

// `id` is the conventional name for the invocation identity throughout this contract.
// swiftlint:disable identifier_name

public struct TranscriptionBackendEpoch: Hashable, Comparable, Sendable {
  public let rawValue: UInt64

  public init(_ rawValue: UInt64) {
    self.rawValue = rawValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public struct TranscriptionInvocationID: Hashable, Sendable {
  public let epoch: TranscriptionBackendEpoch
  public let generation: Int

  public init(epoch: TranscriptionBackendEpoch, generation: Int) {
    self.epoch = epoch
    self.generation = generation
  }
}

public struct TranscriptionPCMFormat: Equatable, Sendable {
  public enum Encoding: Equatable, Sendable {
    case signedInteger16LittleEndian
  }

  public let sampleRate: Int
  public let channelCount: Int
  public let encoding: Encoding

  public init(
    sampleRate: Int,
    channelCount: Int = 1,
    encoding: Encoding = .signedInteger16LittleEndian
  ) {
    precondition(sampleRate > 0)
    precondition(channelCount > 0)
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.encoding = encoding
  }

  public static let openAI = Self(sampleRate: 24_000)
  public static let local = Self(sampleRate: 16_000)
}

public struct TranscriptionInvocation: Equatable, Sendable {
  public let id: TranscriptionInvocationID
  public let format: TranscriptionPCMFormat

  public init(id: TranscriptionInvocationID, format: TranscriptionPCMFormat) {
    self.id = id
    self.format = format
  }
}

public enum TranscriptionCorrectionOutcome: Equatable, Sendable {
  case disabled
  case applied
  case degraded
}

public struct TranscriptionFinalResult: Equatable, Sendable {
  public let text: String
  public let correction: TranscriptionCorrectionOutcome

  public init(text: String, correction: TranscriptionCorrectionOutcome) {
    self.text = text
    self.correction = correction
  }
}

public struct TranscriptionFailure: Error, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case configuration
    case capture
    case transport
    case transcription
  }

  public let kind: Kind
  public let message: String
  public let isRecoverable: Bool

  public init(kind: Kind, message: String, isRecoverable: Bool) {
    self.kind = kind
    self.message = message
    self.isRecoverable = isRecoverable
  }
}

public enum TranscriptionEngineReadiness: Equatable, Sendable {
  case preparing(message: String)
  case ready
  case recovering(message: String)
  case unavailable(reason: String, action: String?)

  public var permitsBoundedCapture: Bool {
    switch self {
    case .preparing, .ready, .recovering:
      true
    case .unavailable:
      false
    }
  }
}

public enum TranscriptionEngineEvent: Equatable, Sendable {
  case readiness(epoch: TranscriptionBackendEpoch, state: TranscriptionEngineReadiness)
  case preview(id: TranscriptionInvocationID, text: String)
  case final(id: TranscriptionInvocationID, result: TranscriptionFinalResult)
  case failure(
    epoch: TranscriptionBackendEpoch,
    id: TranscriptionInvocationID?,
    failure: TranscriptionFailure
  )
}

public enum TranscriptionEngineCommand: Equatable, Sendable {
  case prepare(epoch: TranscriptionBackendEpoch)
  case begin(TranscriptionInvocation)
  case append(id: TranscriptionInvocationID, sequence: Int, audio: Data)
  case finish(id: TranscriptionInvocationID)
  case cancel(id: TranscriptionInvocationID)
}

// swiftlint:enable identifier_name
