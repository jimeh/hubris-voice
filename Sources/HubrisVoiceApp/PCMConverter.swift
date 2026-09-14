@preconcurrency import AVFoundation
import Foundation

/// One converter per capture. Its owner serializes input and drains it before ending audio.
final class PCMConverter {
  typealias Conversion = (@escaping AVAudioConverterInputBlock) throws -> Data

  enum ConversionError: Error {
    case unsupportedFormat
    case failed
  }

  let outputFormat: AVAudioFormat
  private let conversion: Conversion
  private let resetConverter: () -> Void
  private var finished = false

  init(sourceFormat: AVAudioFormat, sampleRate: Double) throws {
    guard sampleRate == 16_000 || sampleRate == 24_000,
          let output = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
            channels: 1, interleaved: false
          ),
          let converter = AVAudioConverter(from: sourceFormat, to: output)
    else { throw ConversionError.unsupportedFormat }
    outputFormat = output
    conversion = { input in
      try Self.convert(using: converter, outputFormat: output, input: input)
    }
    resetConverter = { converter.reset() }
  }

  init(
    outputFormat: AVAudioFormat,
    conversion: @escaping Conversion,
    reset: @escaping () -> Void
  ) {
    self.outputFormat = outputFormat
    self.conversion = conversion
    resetConverter = reset
  }

  func append(_ buffer: AVAudioPCMBuffer) throws -> Data {
    guard !finished else { return Data() }
    let input = PCMConverterInput(buffer: buffer)
    return try convert { _, status in input.next(status: status) }
  }

  func finish() throws -> Data {
    guard !finished else { return Data() }
    finished = true
    return try convert { _, status in
      status.pointee = .endOfStream
      return nil
    }
  }

  func finishAndReset() throws -> Data {
    defer {
      resetConverter()
      finished = false
    }
    return try finish()
  }

  private func convert(_ input: @escaping AVAudioConverterInputBlock) throws -> Data {
    try conversion(input)
  }

  private static func convert(
    using converter: AVAudioConverter,
    outputFormat: AVAudioFormat,
    input: @escaping AVAudioConverterInputBlock
  ) throws -> Data {
    var result = Data()
    while true {
      guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else {
        throw ConversionError.failed
      }
      var error: NSError?
      let status = converter.convert(to: output, error: &error, withInputFrom: input)
      if let error {
        throw error
      }
      guard status != .error else { throw ConversionError.failed }
      if output.frameLength > 0, let samples = output.int16ChannelData?.pointee {
        result.append(Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size))
      }
      guard status == .haveData else { return result }
    }
  }
}

private final class PCMConverterInput: @unchecked Sendable {
  private let buffer: AVAudioPCMBuffer
  private var supplied = false

  init(buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }

  func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    guard !supplied else {
      status.pointee = .noDataNow
      return nil
    }
    supplied = true
    status.pointee = .haveData
    return buffer
  }
}
