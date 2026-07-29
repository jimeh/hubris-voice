@preconcurrency import AVFoundation
import Foundation

final class AudioCapture: @unchecked Sendable {
  enum CaptureError: Error, LocalizedError {
    case converterUnavailable
    case targetFormatUnavailable
    case conversionFailed(String)

    var errorDescription: String? {
      switch self {
      case .converterUnavailable:
        "The microphone format cannot be converted to 24 kHz PCM."
      case .targetFormatUnavailable:
        "The 24 kHz PCM audio format could not be created."
      case .conversionFailed(let message):
        "Audio conversion failed: \(message)"
      }
    }
  }

  var onChunk: (@Sendable (Data) -> Void)?
  var onLevel: (@Sendable (Float) -> Void)?
  var onError: (@Sendable (String) -> Void)?

  private let engine = AVAudioEngine()
  private var converter: AVAudioConverter?
  private var targetFormat: AVAudioFormat?
  private(set) var isRunning = false

  func start() throws {
    guard !isRunning else {
      return
    }

    let input = engine.inputNode
    let sourceFormat = input.outputFormat(forBus: 0)
    guard
      let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
      )
    else {
      throw CaptureError.targetFormatUnavailable
    }
    guard
      let converter = AVAudioConverter(
        from: sourceFormat,
        to: targetFormat
      )
    else {
      throw CaptureError.converterUnavailable
    }

    self.converter = converter
    self.targetFormat = targetFormat

    input.installTap(
      onBus: 0,
      bufferSize: 1_024,
      format: sourceFormat
    ) { [weak self] buffer, _ in
      self?.process(
        buffer,
        converter: converter,
        targetFormat: targetFormat
      )
    }

    do {
      engine.prepare()
      try engine.start()
      isRunning = true
    } catch {
      input.removeTap(onBus: 0)
      self.converter = nil
      self.targetFormat = nil
      throw error
    }
  }

  func stop() {
    guard isRunning else {
      return
    }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    converter = nil
    targetFormat = nil
    isRunning = false
  }

  private func process(
    _ buffer: AVAudioPCMBuffer,
    converter: AVAudioConverter,
    targetFormat: AVAudioFormat
  ) {
    onLevel?(level(for: buffer))

    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(
      max(1, ceil(Double(buffer.frameLength) * ratio) + 1)
    )
    guard
      let converted = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: capacity
      )
    else {
      return
    }

    let inputProvider = ConverterInput(buffer: buffer)
    var conversionError: NSError?
    let status = converter.convert(
      to: converted,
      error: &conversionError
    ) { _, inputStatus in
      inputProvider.next(status: inputStatus)
    }

    guard
      status != .error,
      conversionError == nil,
      converted.frameLength > 0,
      let samples = converted.int16ChannelData?.pointee
    else {
      if let conversionError {
        onError?(conversionError.localizedDescription)
      }
      return
    }

    let byteCount =
      Int(converted.frameLength)
      * MemoryLayout<Int16>.size
    onChunk?(Data(bytes: samples, count: byteCount))
  }

  private func level(for buffer: AVAudioPCMBuffer) -> Float {
    guard
      buffer.frameLength > 0,
      let channel = buffer.floatChannelData?.pointee
    else {
      return 0
    }

    var sum: Float = 0
    for index in 0..<Int(buffer.frameLength) {
      let sample = channel[index]
      sum += sample * sample
    }
    let rootMeanSquare = sqrt(sum / Float(buffer.frameLength))
    return min(1, max(0, rootMeanSquare * 8))
  }
}

private final class ConverterInput: @unchecked Sendable {
  private let buffer: AVAudioPCMBuffer
  private let lock = NSLock()
  private var hasSuppliedBuffer = false

  init(buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }

  func next(
    status: UnsafeMutablePointer<AVAudioConverterInputStatus>
  ) -> AVAudioBuffer? {
    lock.lock()
    defer { lock.unlock() }
    if hasSuppliedBuffer {
      status.pointee = .noDataNow
      return nil
    }
    hasSuppliedBuffer = true
    status.pointee = .haveData
    return buffer
  }
}
