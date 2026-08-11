import Foundation
@testable import HubrisVoiceCore
import XCTest

final class RealtimeProtocolTests: XCTestCase {
  func testEndpointDeclaresTranscriptionIntentWithoutSessionModel() throws {
    let endpoint = try XCTUnwrap(RealtimeAPI.endpoint)
    let components = try XCTUnwrap(
      URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    )

    XCTAssertEqual(endpoint.scheme, "wss")
    XCTAssertEqual(endpoint.host, "api.openai.com")
    XCTAssertEqual(endpoint.path, "/v1/realtime")
    XCTAssertEqual(
      components.queryItems,
      [
        URLQueryItem(name: "intent", value: "transcription"),
      ]
    )
  }

  func testSessionUpdateUsesTranscriptionSessionAndCurrentLiveFields() throws {
    let configuration = RealtimeSessionConfiguration(
      language: "en",
      prompt: "Names are written exactly as supplied.",
      keywords: ["Hucode", "Treeboot"],
      delay: .low
    )

    let data = try RealtimeClientEvent.sessionUpdate(configuration).encoded()
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let session = try XCTUnwrap(object["session"] as? [String: Any])
    let audio = try XCTUnwrap(session["audio"] as? [String: Any])
    let input = try XCTUnwrap(audio["input"] as? [String: Any])
    let format = try XCTUnwrap(input["format"] as? [String: Any])
    let transcription = try XCTUnwrap(
      input["transcription"] as? [String: Any]
    )

    XCTAssertEqual(object["type"] as? String, "session.update")
    XCTAssertEqual(session["type"] as? String, "transcription")
    XCTAssertEqual(format["type"] as? String, "audio/pcm")
    XCTAssertEqual(format["rate"] as? Int, 24_000)
    XCTAssertTrue(input["turn_detection"] is NSNull)
    XCTAssertEqual(
      transcription["model"] as? String,
      RealtimeAPI.transcriptionModel
    )
    XCTAssertEqual(transcription["languages"] as? [String], ["en"])
    XCTAssertEqual(transcription["keywords"] as? [String], ["Hucode", "Treeboot"])
    XCTAssertEqual(transcription["delay"] as? String, "low")
  }

  func testAudioAppendAndCommitEncodeExpectedEvents() throws {
    let audio = Data([0x00, 0x7f, 0xff])

    let append = try jsonObject(
      for: RealtimeClientEvent.appendAudio(audio).encoded()
    )
    let commit = try jsonObject(
      for: RealtimeClientEvent.commitAudio(eventID: "commit-1").encoded()
    )

    XCTAssertEqual(append["type"] as? String, "input_audio_buffer.append")
    XCTAssertEqual(append["audio"] as? String, audio.base64EncodedString())
    XCTAssertEqual(commit["type"] as? String, "input_audio_buffer.commit")
    XCTAssertEqual(commit["event_id"] as? String, "commit-1")
  }

  func testDecodeKnownAndUnknownServerEvents() throws {
    XCTAssertEqual(
      try decode(#"{"type":"input_audio_buffer.committed","item_id":"item-1"}"#),
      .inputCommitted(itemID: "item-1")
    )
    XCTAssertEqual(
      try decode(
        #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"item-1","delta":"hello"}"#
      ),
      .transcriptDelta(itemID: "item-1", delta: "hello")
    )
    XCTAssertEqual(
      try decode(
        #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"item-1","transcript":"hello world"}"#
      ),
      .transcriptCompleted(itemID: "item-1", transcript: "hello world")
    )
    XCTAssertEqual(
      try decode(#"{"type":"error","error":{"message":"nope"}}"#),
      .error(message: "nope")
    )
    XCTAssertEqual(
      try decode(#"{"type":"session.updated","session":{"id":"session-1"}}"#),
      .sessionReady
    )
    XCTAssertEqual(
      try decode(#"{"type":"rate_limits.updated"}"#),
      .ignored(type: "rate_limits.updated")
    )
  }

  func testDecodeRejectsMalformedAndIncompleteEvents() {
    XCTAssertThrowsError(
      try RealtimeServerEvent.decode(Data("not-json".utf8))
    )
    XCTAssertThrowsError(
      try decode(
        #"{"type":"conversation.item.input_audio_transcription.delta","delta":"hello"}"#
      )
    )
  }

  private func decode(_ json: String) throws -> RealtimeServerEvent {
    try RealtimeServerEvent.decode(Data(json.utf8))
  }

  private func jsonObject(for data: Data) throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
  }
}
