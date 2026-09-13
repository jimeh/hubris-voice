@preconcurrency import AVFoundation
import CoreAudio
import Foundation

final class AudioCapture: @unchecked Sendable {
  enum CaptureError: Error, LocalizedError {
    case converterUnavailable
    case targetFormatUnavailable
    case audioUnitUnavailable
    case deviceUnavailable(String)
    case deviceSelectionFailed(OSStatus)

    var errorDescription: String? {
      switch self {
      case .converterUnavailable:
        "The microphone format cannot be converted to 24 kHz PCM."
      case .targetFormatUnavailable:
        "The 24 kHz PCM audio format could not be created."
      case .audioUnitUnavailable:
        "The microphone audio unit is unavailable."
      case .deviceUnavailable(let uid):
        "The selected input device is no longer available (\(uid))."
      case .deviceSelectionFailed(let status):
        "The selected input device could not be activated (Core Audio \(status))."
      }
    }
  }

  var onChunk: (@Sendable (Data) -> Void)?
  var onLevel: (@Sendable (Float) -> Void)?
  var onError: (@Sendable (String) -> Void)?
  var onDevicesChanged: (@Sendable () -> Void)?

  var preferredDeviceUID: String? {
    get { withLock { storedPreferredDeviceUID } }
    set {
      let shouldSwitch = withLock {
        let changed = storedPreferredDeviceUID != newValue
        storedPreferredDeviceUID = newValue
        return changed && isRunning
      }
      if shouldSwitch {
        reconfigureWhileRunning(reportMissingPreferredDevice: true)
      }
    }
  }

  private let engine = AVAudioEngine()
  private let lock = NSRecursiveLock()
  private let deviceListenerQueue = DispatchQueue(label: "com.jimeh.HubrisVoice.audio-devices")
  private var converter: AVAudioConverter?
  private var targetFormat: AVAudioFormat?
  private var storedPreferredDeviceUID: String?
  private(set) var isRunning = false
  private var isTapInstalled = false
  private var isSwitchingDevice = false
  private var engineConfigurationObserver: NSObjectProtocol?
  private var deviceListener: AudioObjectPropertyListenerBlock?

  init() {
    engineConfigurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine,
      queue: nil
    ) { [weak self] _ in
      self?.reconfigureWhileRunning(reportMissingPreferredDevice: false)
    }
    installDeviceListeners()
  }

  deinit {
    if let engineConfigurationObserver {
      NotificationCenter.default.removeObserver(engineConfigurationObserver)
    }
    removeDeviceListeners()
  }

  func start() throws {
    lock.lock()
    defer { lock.unlock() }
    guard !isRunning else { return }
    try configureAndStart(preferredUID: storedPreferredDeviceUID)
    isRunning = true
  }

  func stop() {
    lock.lock()
    defer { lock.unlock() }
    guard isRunning else { return }
    isRunning = false
    removeTapAndStop()
  }

  static func availableInputDevices() -> [(uid: String, name: String)] {
    allDeviceIDs().compactMap { deviceID in
      guard
        inputChannelCount(deviceID) > 0,
        let uid = stringProperty(kAudioDevicePropertyDeviceUID, on: deviceID),
        let name = stringProperty(kAudioObjectPropertyName, on: deviceID)
      else {
        return nil
      }
      return (uid: uid, name: name)
    }.sorted { lhs, rhs in
      lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  private func configureAndStart(preferredUID: String?) throws {
    let input = engine.inputNode
    let deviceID = preferredUID.flatMap(Self.deviceID(forUID:)) ?? Self.defaultInputDeviceID()
    if let deviceID {
      try select(deviceID: deviceID, on: input)
    }
    let sourceFormat = input.outputFormat(forBus: 0)
    let components = try makeConverter(from: sourceFormat)
    converter = components.converter
    targetFormat = components.targetFormat
    installTap(
      on: input,
      sourceFormat: sourceFormat,
      converter: components.converter,
      targetFormat: components.targetFormat
    )
    do {
      engine.prepare()
      try engine.start()
    } catch {
      removeTap(from: input)
      converter = nil
      targetFormat = nil
      throw error
    }
  }

  private func reconfigureWhileRunning(reportMissingPreferredDevice: Bool) {
    lock.lock()
    guard isRunning, !isSwitchingDevice else {
      lock.unlock()
      return
    }
    isSwitchingDevice = true
    let preferredUID = storedPreferredDeviceUID
    removeTapAndStop()
    let missingUID = preferredUID.flatMap { uid in
      reportMissingPreferredDevice && Self.deviceID(forUID: uid) == nil
        ? uid
        : nil
    }
    do {
      try configureAndStart(preferredUID: preferredUID)
      isRunning = true
      isSwitchingDevice = false
      lock.unlock()
      if let missingUID {
        onError?(CaptureError.deviceUnavailable(missingUID).localizedDescription)
      }
    } catch {
      do {
        try configureAndStart(preferredUID: nil)
        isRunning = true
      } catch {
        isRunning = false
      }
      isSwitchingDevice = false
      lock.unlock()
      onError?(error.localizedDescription)
    }
  }

  private func makeConverter(
    from sourceFormat: AVAudioFormat
  ) throws -> (converter: AVAudioConverter, targetFormat: AVAudioFormat) {
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
    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
      throw CaptureError.converterUnavailable
    }
    return (converter, targetFormat)
  }

  private func installTap(
    on input: AVAudioInputNode,
    sourceFormat: AVAudioFormat,
    converter: AVAudioConverter,
    targetFormat: AVAudioFormat
  ) {
    input.installTap(onBus: 0, bufferSize: 1_024, format: sourceFormat) { [weak self] buffer, _ in
      self?.process(buffer, converter: converter, targetFormat: targetFormat)
    }
    isTapInstalled = true
  }

  private func removeTapAndStop() {
    removeTap(from: engine.inputNode)
    engine.stop()
    converter = nil
    targetFormat = nil
  }

  private func removeTap(from input: AVAudioInputNode) {
    guard isTapInstalled else { return }
    input.removeTap(onBus: 0)
    isTapInstalled = false
  }

  private func select(deviceID: AudioDeviceID, on input: AVAudioInputNode) throws {
    guard let audioUnit = input.audioUnit else {
      throw CaptureError.audioUnitUnavailable
    }
    var deviceID = deviceID
    let status = AudioUnitSetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &deviceID,
      UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    guard status == noErr else {
      throw CaptureError.deviceSelectionFailed(status)
    }
  }

  private func process(
    _ buffer: AVAudioPCMBuffer,
    converter: AVAudioConverter,
    targetFormat: AVAudioFormat
  ) {
    onLevel?(level(for: buffer))
    let ratio = targetFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * ratio) + 1))
    guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
      return
    }
    let inputProvider = ConverterInput(buffer: buffer)
    var conversionError: NSError?
    let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
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
    let byteCount = Int(converted.frameLength) * MemoryLayout<Int16>.size
    onChunk?(Data(bytes: samples, count: byteCount))
  }

  private func level(for buffer: AVAudioPCMBuffer) -> Float {
    guard buffer.frameLength > 0, let channel = buffer.floatChannelData?.pointee else {
      return 0
    }
    var sum: Float = 0
    for index in 0 ..< Int(buffer.frameLength) {
      let sample = channel[index]
      sum += sample * sample
    }
    let rootMeanSquare = sqrt(sum / Float(buffer.frameLength))
    return min(1, max(0, rootMeanSquare * 8))
  }

  private func installDeviceListeners() {
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self else { return }
      onDevicesChanged?()
      reconfigureWhileRunning(reportMissingPreferredDevice: true)
    }
    deviceListener = listener
    for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
      var address = Self.systemAddress(selector)
      AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        deviceListenerQueue,
        listener
      )
    }
  }

  private func removeDeviceListeners() {
    guard let deviceListener else { return }
    for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
      var address = Self.systemAddress(selector)
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        deviceListenerQueue,
        deviceListener
      )
    }
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private static func systemAddress(
    _ selector: AudioObjectPropertySelector
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
  }

  private static func allDeviceIDs() -> [AudioDeviceID] {
    var address = systemAddress(kAudioHardwarePropertyDevices)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
    ) == noErr else { return [] }
    var devices = Array(
      repeating: AudioDeviceID(0),
      count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    )
    let status = devices.withUnsafeMutableBufferPointer { buffer in
      guard let baseAddress = buffer.baseAddress else {
        return kAudio_ParamError
      }
      return AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &dataSize,
        baseAddress
      )
    }
    guard status == noErr else { return [] }
    return devices
  }

  private static func deviceID(forUID uid: String) -> AudioDeviceID? {
    allDeviceIDs().first {
      stringProperty(kAudioDevicePropertyDeviceUID, on: $0) == uid
    }
  }

  private static func defaultInputDeviceID() -> AudioDeviceID? {
    var address = systemAddress(kAudioHardwarePropertyDefaultInputDevice)
    var deviceID = AudioDeviceID(0)
    var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID
    ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
    return deviceID
  }

  private static func stringProperty(
    _ selector: AudioObjectPropertySelector,
    on deviceID: AudioDeviceID
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    let storage = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
    storage.initialize(to: nil)
    defer {
      storage.deinitialize(count: 1)
      storage.deallocate()
    }
    var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard
      AudioObjectGetPropertyData(
        deviceID,
        &address,
        0,
        nil,
        &dataSize,
        storage
      ) == noErr,
      let value = storage.pointee?.takeRetainedValue()
    else {
      return nil
    }
    return value as String
  }

  private static func inputChannelCount(_ deviceID: AudioDeviceID) -> UInt32 {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
      return 0
    }
    let rawBuffer = UnsafeMutableRawPointer.allocate(
      byteCount: Int(dataSize),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawBuffer.deallocate() }
    guard AudioObjectGetPropertyData(
      deviceID, &address, 0, nil, &dataSize, rawBuffer
    ) == noErr else { return 0 }
    let list = rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
  }
}

private final class ConverterInput: @unchecked Sendable {
  private let buffer: AVAudioPCMBuffer
  private let lock = NSLock()
  private var hasSuppliedBuffer = false

  init(buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }

  func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
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
