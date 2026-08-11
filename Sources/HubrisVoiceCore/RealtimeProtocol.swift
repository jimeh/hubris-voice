import Foundation

public enum RealtimeAPI {
  public static let transcriptionModel = "gpt-live-transcribe"

  public static var endpoint: URL? {
    var components = URLComponents()
    components.scheme = "wss"
    components.host = "api.openai.com"
    components.path = "/v1/realtime"
    components.queryItems = [
      URLQueryItem(name: "intent", value: "transcription"),
    ]
    return components.url
  }
}

public struct RealtimeSessionConfiguration: Equatable, Sendable {
  public enum Delay: String, Equatable, Sendable {
    case minimal
    case low
    case medium
    case high
    case xhigh
  }

  public let language: String
  public let prompt: String
  public let keywords: [String]
  public let delay: Delay

  public init(
    language: String,
    prompt: String,
    keywords: [String],
    delay: Delay
  ) {
    self.language = language
    self.prompt = prompt
    self.keywords = keywords
    self.delay = delay
  }
}

public enum RealtimeClientEvent: Equatable, Sendable {
  case sessionUpdate(RealtimeSessionConfiguration)
  case appendAudio(Data)
  case commitAudio(eventID: String)
  case clearAudio

  public func encoded() throws -> Data {
    try JSONSerialization.data(
      withJSONObject: jsonObject,
      options: [.sortedKeys]
    )
  }

  private var jsonObject: [String: Any] {
    switch self {
    case .sessionUpdate(let configuration):
      [
        "type": "session.update",
        "session": [
          "type": "transcription",
          "audio": [
            "input": [
              "format": [
                "type": "audio/pcm",
                "rate": 24_000,
              ],
              "transcription": [
                "model": RealtimeAPI.transcriptionModel,
                "prompt": configuration.prompt,
                "keywords": configuration.keywords,
                "languages": [configuration.language],
                "delay": configuration.delay.rawValue,
              ],
              "turn_detection": NSNull(),
            ],
          ],
        ],
      ]
    case .appendAudio(let data):
      [
        "type": "input_audio_buffer.append",
        "audio": data.base64EncodedString(),
      ]
    case .commitAudio(let eventID):
      [
        "event_id": eventID,
        "type": "input_audio_buffer.commit",
      ]
    case .clearAudio:
      [
        "type": "input_audio_buffer.clear",
      ]
    }
  }
}

public enum RealtimeServerEvent: Equatable, Sendable {
  public enum DecodeError: Error, Equatable, LocalizedError {
    case invalidJSON
    case missingField(String, eventType: String)

    public var errorDescription: String? {
      switch self {
      case .invalidJSON:
        "The Realtime server sent invalid JSON."
      case .missingField(let field, let eventType):
        "Realtime event \(eventType) is missing \(field)."
      }
    }
  }

  case sessionReady
  case inputCommitted(itemID: String)
  case transcriptDelta(itemID: String, delta: String)
  case transcriptCompleted(itemID: String, transcript: String)
  case error(message: String)
  case ignored(type: String)

  public static func decode(_ data: Data) throws -> Self {
    guard
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any],
      let type = dictionary["type"] as? String
    else {
      throw DecodeError.invalidJSON
    }

    switch type {
    case "session.updated":
      return .sessionReady
    case "input_audio_buffer.committed":
      return try .inputCommitted(
        itemID: requiredString(
          "item_id",
          in: dictionary,
          eventType: type
        )
      )
    case "conversation.item.input_audio_transcription.delta":
      return try .transcriptDelta(
        itemID: requiredString(
          "item_id",
          in: dictionary,
          eventType: type
        ),
        delta: requiredString(
          "delta",
          in: dictionary,
          eventType: type
        )
      )
    case "conversation.item.input_audio_transcription.completed":
      return try .transcriptCompleted(
        itemID: requiredString(
          "item_id",
          in: dictionary,
          eventType: type
        ),
        transcript: requiredString(
          "transcript",
          in: dictionary,
          eventType: type
        )
      )
    case "error":
      guard
        let error = dictionary["error"] as? [String: Any],
        let message = error["message"] as? String
      else {
        throw DecodeError.missingField("error.message", eventType: type)
      }
      return .error(message: message)
    default:
      return .ignored(type: type)
    }
  }

  private static func requiredString(
    _ key: String,
    in dictionary: [String: Any],
    eventType: String
  ) throws -> String {
    guard let value = dictionary[key] as? String else {
      throw DecodeError.missingField(key, eventType: eventType)
    }
    return value
  }
}
