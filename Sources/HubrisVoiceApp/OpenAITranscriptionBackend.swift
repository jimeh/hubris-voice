import Foundation
import HubrisVoiceCore

// Keep the provider lifecycle and correlation table together for direct review.
// `id` consistently means a transcription invocation identity in this adapter.
// swiftlint:disable file_length identifier_name type_body_length

enum OpenAIConfigurationEvent: Equatable, Sendable {
  case applied
  case failed(String)
}

final class OpenAITranscriptionBackend: TranscriptionEngineRuntime, @unchecked Sendable {
  let events: AsyncStream<TranscriptionEngineEvent>
  let configurationEvents: AsyncStream<OpenAIConfigurationEvent>

  private let commands = TranscriptionEngineCommandPipe()
  private let state: OpenAITranscriptionState
  private var commandTask: Task<Void, Never>?

  init(
    apiKey: String,
    configuration: RealtimeSessionConfiguration,
    reconnectPolicy: ReconnectPolicy = .init(),
    outboundCapacity: Int = 512,
    consumesOutboundActions: Bool = true
  ) {
    let eventPair = AsyncStream.makeStream(of: TranscriptionEngineEvent.self)
    events = eventPair.stream
    let configurationPair = AsyncStream.makeStream(
      of: OpenAIConfigurationEvent.self,
      bufferingPolicy: .bufferingNewest(20)
    )
    configurationEvents = configurationPair.stream
    state = OpenAITranscriptionState(
      apiKey: apiKey,
      configuration: configuration,
      reconnectPolicy: reconnectPolicy,
      outboundCapacity: outboundCapacity,
      consumesOutboundActions: consumesOutboundActions,
      eventContinuation: eventPair.continuation,
      configurationContinuation: configurationPair.continuation
    )
    let commandStream = commands.stream
    commandTask = Task { [state, commands] in
      await state.start()
      for await command in commandStream {
        commands.didConsume(command)
        guard !Task.isCancelled else { return }
        await state.handle(command)
      }
    }
  }

  deinit { commandTask?.cancel() }

  func submit(_ command: TranscriptionEngineCommand) -> Bool {
    commands.submit(command)
  }

  func updateCredentials(_ apiKey: String) async {
    await state.updateCredentials(apiKey)
  }

  func updateConfiguration(
    _ configuration: RealtimeSessionConfiguration,
    reconnect: Bool
  ) async -> Bool {
    await state.updateConfiguration(configuration, reconnect: reconnect)
  }

  func requestReconnect() async {
    await state.requestReconnect()
  }

  func shutdown() async {
    commands.finish()
    commandTask?.cancel()
    commandTask = nil
    await state.shutdown()
  }

  func testingSetReady(epoch: TranscriptionBackendEpoch) async {
    await state.testingSetReady(epoch: epoch)
  }

  func testingHandle(_ command: TranscriptionEngineCommand) async {
    await state.handle(command)
  }

  func testingReceive(_ event: RealtimeServerEvent) async {
    await state.testingReceive(event)
  }

  func testingCommitEventID(for id: TranscriptionInvocationID) async -> String? {
    await state.testingCommitEventID(for: id)
  }

  func testingResetForReconnect() async {
    await state.testingResetForReconnect()
  }

  func testingIsTransportInactive() async -> Bool {
    await state.testingIsTransportInactive()
  }

  func testingHasInvocation(_ id: TranscriptionInvocationID) async -> Bool {
    await state.testingHasInvocation(id)
  }

  func testingHasActiveAttempt() async -> Bool {
    await state.testingHasActiveAttempt()
  }
}

private actor OpenAITranscriptionState {
  private struct Invocation {
    let value: TranscriptionInvocation
    var chunks: [Data] = []
    var nextSequence = 0
    var itemID: String?
    var preview = ""
    var isFinished = false
    var isCancelled = false

    var hasAudio: Bool {
      chunks.contains { !$0.isEmpty }
    }
  }

  private struct BufferedProviderPreview {
    var text = ""
    var byteCount = 0
  }

  private struct PendingCommit {
    let eventID: String
    let id: TranscriptionInvocationID
  }

  private let client: RealtimeTranscriptionClient
  private let reconnectPolicy: ReconnectPolicy
  private let eventContinuation: AsyncStream<TranscriptionEngineEvent>.Continuation
  private let configurationContinuation: AsyncStream<OpenAIConfigurationEvent>.Continuation
  private var apiKey: String
  private var configuration: RealtimeSessionConfiguration
  private var epoch = TranscriptionBackendEpoch(0)
  private var invocations: [TranscriptionInvocationID: Invocation] = [:]
  private var retiredItemIDs: Set<String> = []
  private var assignedItemIDs: Set<String> = []
  private var awaitingCommits: [PendingCommit] = []
  private var bufferedProviderPreviews: [String: BufferedProviderPreview] = [:]
  private var fencedProviderItemIDs: Set<String> = []
  private var didOverflowBufferedProviderItems = false
  private var activeInputID: TranscriptionInvocationID?
  private var activeAttemptID: String?
  private var attempt = 0
  private var isReady = false
  private var transportTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var eventTask: Task<Void, Never>?
  private var pendingConfigurationAcknowledgements = 0
  private var isShutdown = false

  private static let maximumBufferedProviderItems = 8
  private static let maximumBufferedPreviewBytesPerItem = 64 * 1_024

  init(
    apiKey: String,
    configuration: RealtimeSessionConfiguration,
    reconnectPolicy: ReconnectPolicy,
    outboundCapacity: Int,
    consumesOutboundActions: Bool,
    eventContinuation: AsyncStream<TranscriptionEngineEvent>.Continuation,
    configurationContinuation: AsyncStream<OpenAIConfigurationEvent>.Continuation
  ) {
    self.apiKey = apiKey
    self.configuration = configuration
    self.reconnectPolicy = reconnectPolicy
    client = RealtimeTranscriptionClient(
      outboundCapacity: outboundCapacity,
      consumesOutboundActions: consumesOutboundActions
    )
    self.eventContinuation = eventContinuation
    self.configurationContinuation = configurationContinuation
  }

  func start() async {
    guard !isShutdown else { return }
    await client.start()
    guard !isShutdown else {
      await client.disconnect()
      return
    }
    guard eventTask == nil else { return }
    eventTask = Task { [weak self, events = client.events] in
      for await event in events {
        guard let self else { return }
        await handle(event)
      }
    }
  }

  func handle(_ command: TranscriptionEngineCommand) async {
    guard !isShutdown else { return }
    switch command {
    case .prepare(let epoch):
      self.epoch = epoch
      prepare()
    case .begin(let invocation):
      guard invocation.id.epoch == epoch, invocations[invocation.id] == nil else { return }
      invocations[invocation.id] = Invocation(value: invocation)
      activeInputID = invocation.id
    case .append(let id, let sequence, let audio):
      await append(id: id, sequence: sequence, audio: audio)
    case .finish(let id):
      await finish(id: id)
    case .cancel(let id):
      await cancel(id: id)
    }
  }

  func updateCredentials(_ apiKey: String) async {
    guard !isShutdown else { return }
    guard apiKey != self.apiKey else { return }
    self.apiKey = apiKey
    await disconnect()
    guard !isShutdown else { return }
    if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      eventContinuation.yield(.readiness(
        epoch: epoch,
        state: .unavailable(
          reason: "Add an OpenAI API key before dictating.",
          action: nil
        )
      ))
    } else {
      attempt = 0
      connect()
    }
  }

  func updateConfiguration(
    _ configuration: RealtimeSessionConfiguration,
    reconnect: Bool
  ) async -> Bool {
    guard !isShutdown else { return false }
    self.configuration = configuration
    guard isReady else { return false }
    if reconnect {
      attempt = 0
      await disconnect()
      guard !isShutdown else { return false }
      connect()
      return true
    }
    pendingConfigurationAcknowledgements += 1
    let sent = await client.updateSession(configuration)
    guard !isShutdown else { return false }
    if !sent {
      pendingConfigurationAcknowledgements = max(0, pendingConfigurationAcknowledgements - 1)
    }
    return sent
  }

  func requestReconnect() async {
    guard !isShutdown else { return }
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    attempt = 0
    await disconnect()
    guard !isShutdown else { return }
    connect()
  }

  func shutdown() async {
    guard !isShutdown else { return }
    isShutdown = true
    eventTask?.cancel()
    eventTask = nil
    await disconnect()
    eventContinuation.finish()
    configurationContinuation.finish()
  }

  func testingSetReady(epoch: TranscriptionBackendEpoch) async {
    guard !isShutdown else { return }
    self.epoch = epoch
    let attemptID = "test-attempt"
    activeAttemptID = attemptID
    client.outbound.setAttempt(attemptID)
    await client.beginAttempt(attemptID)
    isReady = true
    eventContinuation.yield(.readiness(epoch: epoch, state: .ready))
    await replayLiveInvocations()
  }

  func testingReceive(_ event: RealtimeServerEvent) async {
    guard !isShutdown else { return }
    guard let activeAttemptID else { return }
    await handle(.init(attemptID: activeAttemptID, payload: .server(event)))
  }

  func testingCommitEventID(for id: TranscriptionInvocationID) -> String? {
    awaitingCommits.first(where: { $0.id == id })?.eventID
  }

  func testingResetForReconnect() {
    guard !isShutdown else { return }
    isReady = false
    resetWireCorrelationForReplay()
  }

  func testingIsTransportInactive() -> Bool {
    isShutdown && activeAttemptID == nil && transportTask == nil && reconnectTask == nil && !isReady
  }

  func testingHasInvocation(_ id: TranscriptionInvocationID) -> Bool {
    invocations[id] != nil
  }

  func testingHasActiveAttempt() -> Bool {
    activeAttemptID != nil
  }

  private func prepare() {
    guard !isShutdown else { return }
    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      eventContinuation.yield(.readiness(
        epoch: epoch,
        state: .unavailable(reason: "Add an OpenAI API key before dictating.", action: nil)
      ))
      return
    }
    connect()
  }

  private func append(id: TranscriptionInvocationID, sequence: Int, audio: Data) async {
    guard var invocation = invocations[id], !invocation.isCancelled, !invocation.isFinished else { return }
    guard sequence == invocation.nextSequence else {
      retire(id)
      eventContinuation.yield(.failure(
        epoch: epoch,
        id: id,
        failure: .init(
          kind: .capture,
          message: "Audio arrived out of order.",
          isRecoverable: false
        )
      ))
      return
    }
    invocation.nextSequence += 1
    invocation.chunks.append(audio)
    invocations[id] = invocation
    if isReady, activeInputID == id {
      guard client.outbound.appendAudio(audio) else {
        await failFullOutboundMailbox(id: id)
        return
      }
    }
  }

  private func finish(id: TranscriptionInvocationID) async {
    guard var invocation = invocations[id], !invocation.isCancelled, !invocation.isFinished else { return }
    invocation.isFinished = true
    invocations[id] = invocation
    guard invocation.hasAudio else {
      completeEmptyInvocation(id)
      return
    }
    if isReady {
      await commit(id)
    }
  }

  private func cancel(id: TranscriptionInvocationID) async {
    guard var invocation = invocations[id], !invocation.isCancelled else { return }
    invocation.isCancelled = true
    invocation.chunks.removeAll(keepingCapacity: false)
    if invocation.itemID == nil {
      fencedProviderItemIDs.formUnion(bufferedProviderPreviews.keys)
      bufferedProviderPreviews.removeAll()
    }
    if let itemID = invocation.itemID {
      retiredItemIDs.insert(itemID)
    }
    invocations[id] = invocation
    if activeInputID == id {
      if isReady {
        if !client.outbound.clearAudio() {
          await retireConnectionAfterOutboundFailure()
        }
      }
      activeInputID = nil
    }
    if !awaitingCommits.contains(where: { $0.id == id }) {
      invocations.removeValue(forKey: id)
    }
  }

  private func connect() {
    guard !isShutdown else { return }
    guard activeAttemptID == nil, transportTask == nil else { return }
    let attemptID = UUID().uuidString
    activeAttemptID = attemptID
    client.outbound.setAttempt(attemptID)
    eventContinuation.yield(.readiness(
      epoch: epoch,
      state: attempt == 0 ? .preparing(message: "Connecting…") : .recovering(message: "Reconnecting…")
    ))
    transportTask = Task { [weak self, apiKey, configuration, client] in
      do {
        try await client.connect(
          apiKey: apiKey,
          configuration: configuration,
          attemptID: attemptID
        )
      } catch is CancellationError {
        return
      } catch {
        await self?.connectionFailed(attemptID: attemptID, message: error.localizedDescription)
      }
    }
  }

  private func connectionFailed(attemptID: String, message: String) {
    guard !isShutdown else { return }
    guard activeAttemptID == attemptID else { return }
    activeAttemptID = nil
    transportTask = nil
    isReady = false
    scheduleReconnect(message: message)
  }

  private func handle(_ event: RealtimeTransportEvent) async {
    guard !isShutdown else { return }
    guard event.belongsTo(activeAttemptID) else { return }
    switch event.payload {
    case .server(.sessionReady):
      pendingConfigurationAcknowledgements = max(0, pendingConfigurationAcknowledgements - 1)
      if pendingConfigurationAcknowledgements == 0 {
        configurationContinuation.yield(.applied)
      }
      guard !isReady else { return }
      isReady = true
      attempt = 0
      eventContinuation.yield(.readiness(epoch: epoch, state: .ready))
      await replayLiveInvocations()
    case .server(.inputCommitted(let itemID)):
      acknowledgeCommit(itemID: itemID)
    case .server(.transcriptDelta(let itemID, let delta)):
      receiveDelta(itemID: itemID, delta: delta)
    case .server(.transcriptCompleted(let itemID, let transcript)):
      receiveCompletion(itemID: itemID, transcript: transcript)
    case .server(.error(let message, let eventID)):
      receiveError(message: message, eventID: eventID)
    case .server(.ignored):
      break
    case .connectionLost(let message):
      guard let attemptID = activeAttemptID else { return }
      activeAttemptID = nil
      transportTask = nil
      isReady = false
      pendingConfigurationAcknowledgements = 0
      resetWireCorrelationForReplay()
      scheduleReconnect(message: message)
      await client.disconnect()
      client.outbound.setAttempt(nil)
      _ = attemptID
    }
  }

  private func scheduleReconnect(message _: String) {
    guard !isShutdown else { return }
    attempt += 1
    eventContinuation.yield(.readiness(
      epoch: epoch,
      state: .recovering(message: "Reconnecting…")
    ))
    reconnectTask?.cancel()
    let delay = reconnectPolicy.delay(forAttempt: attempt)
    reconnectTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.reconnectDelayElapsed()
    }
  }

  private func reconnectDelayElapsed() {
    reconnectTask = nil
    guard !isShutdown else { return }
    connect()
  }

  private func disconnect() async {
    reconnectTask?.cancel()
    reconnectTask = nil
    transportTask?.cancel()
    transportTask = nil
    activeAttemptID = nil
    isReady = false
    pendingConfigurationAcknowledgements = 0
    resetWireCorrelationForReplay()
    client.outbound.setAttempt(nil)
    await client.disconnect()
  }

  private func replayLiveInvocations() async {
    let live = invocations.values
      .filter { !$0.isCancelled }
      .sorted { $0.value.id.generation < $1.value.id.generation }
    for invocation in live {
      if invocation.isFinished, !invocation.hasAudio {
        completeEmptyInvocation(invocation.value.id)
        continue
      }
      activeInputID = invocation.value.id
      guard let receipt = client.outbound.replay(
        invocation.chunks,
        commit: invocation.isFinished
      ) else {
        await failFullOutboundMailbox(id: invocation.value.id)
        return
      }
      if let eventID = receipt.commitEventID {
        activeInputID = nil
        awaitingCommits.append(.init(eventID: eventID, id: invocation.value.id))
      }
    }
  }

  private func commit(_ id: TranscriptionInvocationID) async {
    guard let invocation = invocations[id], !invocation.isCancelled else { return }
    activeInputID = nil
    guard let eventID = client.outbound.commitAudio() else {
      await failFullOutboundMailbox(id: id)
      return
    }
    awaitingCommits.append(.init(eventID: eventID, id: id))
  }

  private func failFullOutboundMailbox(id: TranscriptionInvocationID) async {
    retire(id)
    eventContinuation.yield(.failure(
      epoch: epoch,
      id: id,
      failure: .init(
        kind: .transport,
        message: "The transcription connection could not keep up with audio.",
        isRecoverable: true
      )
    ))
    await retireConnectionAfterOutboundFailure()
  }

  private func retireConnectionAfterOutboundFailure() async {
    guard !isShutdown else { return }
    reconnectTask?.cancel()
    reconnectTask = nil
    transportTask?.cancel()
    transportTask = nil
    activeAttemptID = nil
    isReady = false
    pendingConfigurationAcknowledgements = 0
    resetWireCorrelationForReplay()
    client.outbound.setAttempt(nil)
    await client.disconnect()
    scheduleReconnect(message: "Outbound transcription queue full")
  }

  private func acknowledgeCommit(itemID: String) {
    assignedItemIDs.insert(itemID)
    let bufferedPreview = bufferedProviderPreviews.removeValue(forKey: itemID)
    guard !awaitingCommits.isEmpty else { return }
    let pending = awaitingCommits.removeFirst()
    guard var invocation = invocations[pending.id] else {
      bindActiveBufferedPreviewIfUnambiguous()
      return
    }
    invocation.itemID = itemID
    if invocation.isCancelled {
      fencedProviderItemIDs.insert(itemID)
      retiredItemIDs.insert(itemID)
      invocations.removeValue(forKey: pending.id)
    } else {
      fencedProviderItemIDs.remove(itemID)
      retiredItemIDs.remove(itemID)
      invocations[pending.id] = invocation
      if let bufferedPreview {
        appendPreview(id: pending.id, delta: bufferedPreview.text)
      }
    }
    bindActiveBufferedPreviewIfUnambiguous()
  }

  private func receiveDelta(itemID: String, delta: String) {
    if let id = invocations.first(where: { $0.value.itemID == itemID })?.key {
      appendPreview(id: id, delta: delta)
      return
    }
    guard !retiredItemIDs.contains(itemID), !assignedItemIDs.contains(itemID),
          !fencedProviderItemIDs.contains(itemID), !didOverflowBufferedProviderItems
    else { return }
    guard awaitingCommits.isEmpty else {
      bufferProviderPreview(itemID: itemID, delta: delta)
      return
    }
    bindActiveItem(itemID: itemID, delta: delta)
  }

  private func bufferProviderPreview(itemID: String, delta: String) {
    guard var preview = bufferedProviderPreviews[itemID] else {
      guard bufferedProviderPreviews.count < Self.maximumBufferedProviderItems else {
        didOverflowBufferedProviderItems = true
        return
      }
      let byteCount = delta.utf8.count
      guard byteCount <= Self.maximumBufferedPreviewBytesPerItem else {
        didOverflowBufferedProviderItems = true
        return
      }
      bufferedProviderPreviews[itemID] = .init(text: delta, byteCount: byteCount)
      return
    }
    let byteCount = delta.utf8.count
    guard byteCount <= Self.maximumBufferedPreviewBytesPerItem - preview.byteCount else { return }
    preview.text += delta
    preview.byteCount += byteCount
    bufferedProviderPreviews[itemID] = preview
  }

  private func bindActiveBufferedPreviewIfUnambiguous() {
    guard !didOverflowBufferedProviderItems, awaitingCommits.isEmpty,
          bufferedProviderPreviews.count == 1,
          let itemID = bufferedProviderPreviews.keys.first
    else { return }
    bindActiveItem(itemID: itemID, delta: "")
  }

  private func bindActiveItem(itemID: String, delta: String) {
    guard let id = activeInputID, var invocation = invocations[id],
          invocation.itemID == nil, !invocation.isCancelled
    else { return }
    assignedItemIDs.insert(itemID)
    invocation.itemID = itemID
    invocations[id] = invocation
    let bufferedText = bufferedProviderPreviews.removeValue(forKey: itemID)?.text ?? ""
    let previewDelta = bufferedText + delta
    if !previewDelta.isEmpty {
      appendPreview(id: id, delta: previewDelta)
    }
  }

  private func appendPreview(id: TranscriptionInvocationID, delta: String) {
    guard var invocation = invocations[id], !invocation.isCancelled else { return }
    invocation.preview += delta
    invocations[id] = invocation
    eventContinuation.yield(.preview(id: id, text: invocation.preview))
  }

  private func receiveCompletion(itemID: String, transcript: String) {
    guard !retiredItemIDs.contains(itemID),
          let id = invocations.first(where: { $0.value.itemID == itemID && !$0.value.isCancelled })?.key
    else { return }
    retire(id)
    eventContinuation.yield(.final(
      id: id,
      result: .init(text: transcript, correction: .disabled)
    ))
  }

  private func receiveError(message: String, eventID: String?) {
    if let eventID, let index = awaitingCommits.firstIndex(where: { $0.eventID == eventID }) {
      let commit = awaitingCommits.remove(at: index)
      guard let invocation = invocations[commit.id] else { return }
      if invocation.isCancelled {
        invocations.removeValue(forKey: commit.id)
        return
      }
      retire(commit.id)
      eventContinuation.yield(.failure(
        epoch: epoch,
        id: commit.id,
        failure: .init(kind: .transcription, message: message, isRecoverable: false)
      ))
      return
    }
    if pendingConfigurationAcknowledgements > 0 {
      pendingConfigurationAcknowledgements = 0
      configurationContinuation.yield(.failed(message))
    }
    eventContinuation.yield(.failure(
      epoch: epoch,
      id: nil,
      failure: .init(kind: .transport, message: message, isRecoverable: true)
    ))
  }

  private func resetWireCorrelationForReplay() {
    awaitingCommits.removeAll()
    bufferedProviderPreviews.removeAll()
    fencedProviderItemIDs.removeAll()
    didOverflowBufferedProviderItems = false
    assignedItemIDs.removeAll()
    retiredItemIDs.removeAll()
    activeInputID = nil
    for id in invocations.keys {
      guard var invocation = invocations[id] else { continue }
      if invocation.isCancelled {
        invocations.removeValue(forKey: id)
        continue
      }
      if let itemID = invocation.itemID {
        retiredItemIDs.insert(itemID)
      }
      invocation.itemID = nil
      invocation.preview = ""
      invocations[id] = invocation
      eventContinuation.yield(.preview(id: id, text: ""))
    }
  }

  private func retire(_ id: TranscriptionInvocationID) {
    guard let invocation = invocations.removeValue(forKey: id) else { return }
    if let itemID = invocation.itemID {
      retiredItemIDs.insert(itemID)
    }
    if activeInputID == id {
      activeInputID = nil
    }
  }

  private func completeEmptyInvocation(_ id: TranscriptionInvocationID) {
    guard let invocation = invocations[id], !invocation.isCancelled else { return }
    retire(id)
    eventContinuation.yield(.final(
      id: id,
      result: .init(text: "", correction: .disabled)
    ))
  }
}

// swiftlint:enable file_length identifier_name type_body_length
