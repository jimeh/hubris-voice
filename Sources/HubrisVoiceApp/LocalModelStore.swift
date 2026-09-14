import CryptoKit
import Foundation

struct LocalModelProgress: Equatable, Sendable {
  let completedBytes: Int64
  let totalBytes: Int64
}

protocol LocalModelDownloading: Sendable {
  func download(
    from url: URL,
    to destination: URL,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws
}

struct URLSessionModelDownloader: LocalModelDownloading {
  func download(
    from url: URL,
    to destination: URL,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    var completed = false
    let handle: FileHandle
    do {
      handle = try FileHandle(forWritingTo: destination)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw error
    }
    defer {
      try? handle.close()
      if !completed {
        try? FileManager.default.removeItem(at: destination)
      }
    }

    let (bytes, response) = try await session.bytes(from: url)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
      throw LocalModelStore.StoreError.downloadFailed
    }
    var buffer = Data()
    buffer.reserveCapacity(1_048_576)
    var receivedBytes: Int64 = 0
    for try await byte in bytes {
      buffer.append(byte)
      if buffer.count >= 1_048_576 {
        try Task.checkCancellation()
        try handle.write(contentsOf: buffer)
        receivedBytes += Int64(buffer.count)
        progress(receivedBytes)
        buffer.removeAll(keepingCapacity: true)
      }
    }
    try Task.checkCancellation()
    if !buffer.isEmpty {
      try handle.write(contentsOf: buffer)
      receivedBytes += Int64(buffer.count)
      progress(receivedBytes)
    }
    completed = true
  }
}

protocol LocalModelFileManaging: Sendable {
  func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
  func fileExists(atPath filePath: String) -> Bool
  func attributesOfItem(atPath filePath: String) throws -> [FileAttributeKey: Any]
  func moveItem(at source: URL, to destination: URL) throws
  func removeItem(at url: URL) throws
}

struct LocalModelFileManager: LocalModelFileManaging {
  func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: withIntermediateDirectories
    )
  }

  func fileExists(atPath filePath: String) -> Bool {
    FileManager.default.fileExists(atPath: filePath)
  }

  func attributesOfItem(atPath filePath: String) throws -> [FileAttributeKey: Any] {
    try FileManager.default.attributesOfItem(atPath: filePath)
  }

  func moveItem(at source: URL, to destination: URL) throws {
    try FileManager.default.moveItem(at: source, to: destination)
  }

  func removeItem(at url: URL) throws {
    try FileManager.default.removeItem(at: url)
  }
}

/// Owns installed files. Loading holds a lease until the native manager releases them.
actor LocalModelStore {
  enum StoreError: Error, LocalizedError {
    case unknownModel, downloadFailed, verificationFailed, busy, inUse, unsafePath

    var errorDescription: String? {
      switch self {
      case .unknownModel: "This model is not in the installed catalog."
      case .downloadFailed: "The model download failed. Check your connection and retry."
      case .verificationFailed: "The downloaded model failed verification. Retry the download."
      case .busy: "Another model operation is in progress."
      case .inUse: "Unload this model before removing its files."
      case .unsafePath: "The model directory contains an unexpected symbolic link."
      }
    }
  }

  struct Lease: Sendable {
    // swiftlint:disable:next identifier_name
    let id: UUID
    let modelID: String
    let directory: URL
  }

  let root: URL
  private let catalog: [LocalModelDefinition]
  private let downloader: any LocalModelDownloading
  private let fileManager: any LocalModelFileManaging
  private var activeInstall: UUID?
  private var leases: [UUID: String] = [:]

  static var defaultRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Hubris Voice/Models", isDirectory: true)
  }

  init(
    root: URL = LocalModelStore.defaultRoot,
    catalog: [LocalModelDefinition] = LocalModelCatalog.models,
    downloader: any LocalModelDownloading = URLSessionModelDownloader(),
    fileManager: any LocalModelFileManaging = LocalModelFileManager()
  ) {
    self.root = root
    self.catalog = catalog
    self.downloader = downloader
    self.fileManager = fileManager
  }

  func installed(_ modelID: String) throws -> Bool {
    let model = try definition(modelID)
    return try verify(model, directory: directory(for: model))
  }

  func acquire(_ modelID: String) throws -> Lease {
    guard try installed(modelID) else { throw StoreError.verificationFailed }
    let model = try definition(modelID)
    let lease = Lease(id: UUID(), modelID: modelID, directory: directory(for: model))
    leases[lease.id] = modelID
    return lease
  }

  func release(_ lease: Lease) {
    leases.removeValue(forKey: lease.id)
  }

  func install(
    _ modelID: String,
    progress: @escaping @Sendable (LocalModelProgress) -> Void = { _ in }
  ) async throws {
    guard activeInstall == nil else { throw StoreError.busy }
    let model = try definition(modelID)
    if try installed(modelID) {
      return
    }
    guard !leases.values.contains(modelID) else { throw StoreError.inUse }
    let operation = UUID()
    activeInstall = operation
    defer { activeInstall = nil }
    let staging = root.appendingPathComponent(".staging/\(model.id)-\(model.revision)", isDirectory: true)
    try rejectSymlinks(staging)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    var completed: Int64 = 0
    for artifact in model.artifacts {
      try Task.checkCancellation()
      let destination = staging.appendingPathComponent(artifact.relativePath)
      try rejectSymlinks(destination)
      if try valid(artifact, at: destination) {
        completed += artifact.byteCount
        progress(.init(completedBytes: completed, totalBytes: model.downloadBytes))
        continue
      }
      let base = completed
      guard let url =
        URL(string: "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(artifact.relativePath)")
      else {
        throw StoreError.unknownModel
      }
      try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      let temporary = destination.appendingPathExtension("part-\(UUID().uuidString)")
      try rejectSymlinks(temporary)
      defer { try? fileManager.removeItem(at: temporary) }
      try await downloader.download(from: url, to: temporary) { bytes in
        progress(.init(completedBytes: base + min(bytes, artifact.byteCount), totalBytes: model.downloadBytes))
      }
      try Task.checkCancellation()
      guard try valid(artifact, at: temporary) else { throw StoreError.verificationFailed }
      if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
      }
      try fileManager.moveItem(at: temporary, to: destination)
      completed += artifact.byteCount
      progress(.init(completedBytes: completed, totalBytes: model.downloadBytes))
    }
    try Task.checkCancellation()
    let destination = directory(for: model)
    try rejectSymlinks(destination)
    // A verified installation is never replaced. Incomplete/corrupt files are moved aside.
    let backup = root.appendingPathComponent(".replaced-\(operation.uuidString)")
    let exists = fileManager.fileExists(atPath: destination.path)
    if exists {
      try fileManager.moveItem(at: destination, to: backup)
    }
    do {
      try fileManager.moveItem(at: staging, to: destination)
    } catch {
      if exists {
        try? fileManager.moveItem(at: backup, to: destination)
      }
      throw error
    }
    if exists {
      try? fileManager.removeItem(at: backup)
    }
  }

  func remove(_ modelID: String) throws {
    guard activeInstall == nil else { throw StoreError.busy }
    guard !leases.values.contains(modelID) else { throw StoreError.inUse }
    let model = try definition(modelID)
    let destination = directory(for: model)
    try rejectSymlinks(destination)
    if fileManager.fileExists(atPath: destination.path) {
      try fileManager.removeItem(at: destination)
    }
    let staging = root.appendingPathComponent(".staging/\(model.id)-\(model.revision)")
    try rejectSymlinks(staging)
    if fileManager.fileExists(atPath: staging.path) {
      try fileManager.removeItem(at: staging)
    }
  }

  private func definition(_ modelID: String) throws -> LocalModelDefinition {
    guard let model = catalog.first(where: { $0.id == modelID }) else { throw StoreError.unknownModel }
    return model
  }

  private func directory(for model: LocalModelDefinition) -> URL {
    root.appendingPathComponent("\(model.id)-\(model.revision)", isDirectory: true)
  }

  private func verify(_ model: LocalModelDefinition, directory: URL) throws -> Bool {
    try rejectSymlinks(directory)
    for artifact in model.artifacts {
      let file = directory.appendingPathComponent(artifact.relativePath)
      try rejectSymlinks(file)
      guard try valid(artifact, at: file) else { return false }
    }
    return true
  }

  private func valid(_ artifact: LocalModelArtifact, at url: URL) throws -> Bool {
    guard fileManager.fileExists(atPath: url.path) else { return false }
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard (attributes[.size] as? NSNumber)?.int64Value == artifact.byteCount,
          attributes[.type] as? FileAttributeType == .typeRegular
    else { return false }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      try Task.checkCancellation()
      hash.update(data: chunk)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined() == artifact.sha256
  }

  private func rejectSymlinks(_ url: URL) throws {
    var candidate = url.standardizedFileURL
    let standardizedRoot = root.standardizedFileURL
    let ownedBoundary = standardizedRoot.deletingLastPathComponent()
    guard candidate.path.hasPrefix(standardizedRoot.path + "/") || candidate == standardizedRoot else {
      throw StoreError.unsafePath
    }
    while true {
      if let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
         attributes[.type] as? FileAttributeType == .typeSymbolicLink
      {
        throw StoreError.unsafePath
      }
      if candidate == ownedBoundary {
        break
      }
      candidate.deleteLastPathComponent()
    }
  }
}
