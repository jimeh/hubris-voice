import AVFoundation
@testable import HubrisVoiceApp
import HubrisVoiceCore
import XCTest

final class PCMConverterTests: XCTestCase {
  func testConvertsBothEngineRatesAndDrainsTail() throws {
    for rate in [16_000.0, 24_000.0] {
      let source = try XCTUnwrap(AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
      ))
      let converter = try PCMConverter(sourceFormat: source, sampleRate: rate)
      var output = Data()
      for offset in stride(from: 0, to: 48_000, by: 480) {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 480))
        buffer.frameLength = 480
        let samples = try XCTUnwrap(buffer.floatChannelData?.pointee)
        for index in 0 ..< 480 {
          samples[index] = Float(sin(Double(offset + index) * 2 * .pi * 440 / 48_000)) * 0.25
        }
        try output.append(converter.append(buffer))
      }
      try output.append(converter.finish())
      XCTAssertEqual(output.count / 2, Int(rate), accuracy: 2)
      XCTAssertTrue(try converter.finish().isEmpty)
      XCTAssertTrue(output.contains { $0 != 0 })
    }
  }

  func testSegmentDrainAndResetKeepsEachInvocationSeparate() throws {
    let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let converter = try PCMConverter(sourceFormat: source, sampleRate: 16_000)
    for _ in 0 ..< 2 {
      let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4_800))
      buffer.frameLength = 4_800
      let samples = try XCTUnwrap(buffer.floatChannelData?.pointee)
      samples.update(repeating: 0, count: 4_800)
      var output = try converter.append(buffer)
      try output.append(converter.finishAndReset())
      XCTAssertEqual(output.count / 2, 1_600, accuracy: 2)
    }
  }

  func testUnsupportedOutputRateIsRejected() throws {
    let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    XCTAssertThrowsError(try PCMConverter(sourceFormat: source, sampleRate: 44_100))
  }

  func testDurationCapsFollowEngineRate() {
    XCTAssertEqual(AudioSnippetBuffer(sampleRate: 16_000).capacityBytes, 2_880_000)
    XCTAssertEqual(AudioSnippetBuffer(sampleRate: 24_000).capacityBytes, AudioSnippetBuffer.defaultCapacityBytes)
  }
}
