import CryptoKit
import Foundation
@testable import HubrisVoiceApp
import XCTest

final class LocalModelStoreTests: XCTestCase {
  func testDownloaderRejectsATruncatedResponseAndRemovesThePartialFile() async throws {
    let fixture = try DownloaderFixture(chunks: [Data("short".utf8)])
    defer { fixture.clean() }

    do {
      try await fixture.downloader.download(
        from: fixture.source,
        to: fixture.destination,
        expectedByteCount: 6
      ) { _ in }
      XCTFail("A truncated response must fail in the downloader")
    } catch LocalModelStore.StoreError.downloadFailed {}

    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
  }

  func testDownloaderAcceptsAnExactSizeResponse() async throws {
    let fixture = try DownloaderFixture(chunks: [Data("exact".utf8)])
    defer { fixture.clean() }
    let progress = ProgressRecorder()

    try await fixture.downloader.download(
      from: fixture.source,
      to: fixture.destination,
      expectedByteCount: 5
    ) { bytes in
      progress.record(bytes)
    }

    XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("exact".utf8))
    XCTAssertEqual(progress.values, [5])
  }

  func testDownloaderRejectsAnOversizedResponseAndRemovesThePartialFile() async throws {
    let expectedByteCount: Int64 = 1_048_576
    let fixture = try DownloaderFixture(chunks: [Data(repeating: 0x41, count: Int(expectedByteCount) + 1)])
    defer { fixture.clean() }
    let progress = ProgressRecorder()

    do {
      try await fixture.downloader.download(
        from: fixture.source,
        to: fixture.destination,
        expectedByteCount: expectedByteCount
      ) { bytes in
        progress.record(bytes)
      }
      XCTFail("A response larger than the pinned artifact size must fail")
    } catch LocalModelStore.StoreError.downloadFailed {}

    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    XCTAssertEqual(progress.values, [expectedByteCount])
  }

  func testInstallVerifiesFilesAndLeasePreventsRemoval() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let downloader = FixtureDownloader(root: fixture.downloadRoot)
    let store = fixture.store(downloader: downloader)
    try await store.install("test")
    let expectedByteCounts = await downloader.expectedByteCounts
    XCTAssertEqual(expectedByteCounts, ["first": [5], "second": [6]])
    let installed = try await store.installed("test")
    XCTAssertTrue(installed)
    let lease = try await store.acquire("test")
    do {
      try await store.remove("test")
      XCTFail("Loaded model must retain its files")
    } catch LocalModelStore.StoreError.inUse {}
    await store.release(lease)
    try await store.remove("test")
    let removed = try await store.installed("test")
    XCTAssertFalse(removed)
  }

  func testCorruptDownloadNeverBecomesInstalledAndRetryReusesVerifiedFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let downloader = FixtureDownloader(root: fixture.downloadRoot, corruptSecond: true)
    let store = fixture.store(downloader: downloader)
    do {
      try await store.install("test")
      XCTFail("Corrupt bytes must fail verification")
    } catch LocalModelStore.StoreError.verificationFailed {}
    let installed = try await store.installed("test")
    XCTAssertFalse(installed)
    await downloader.setCorrupt(false)
    try await store.install("test")
    let counts = await downloader.counts
    XCTAssertEqual(counts["first"], 1)
    XCTAssertEqual(counts["second"], 2)
    let recovered = try await store.installed("test")
    XCTAssertTrue(recovered)
  }

  func testCancelledInstallReusesCompletedFilesOnRetry() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let downloader = FixtureDownloader(root: fixture.downloadRoot, suspendAt: "second")
    let store = fixture.store(downloader: downloader)
    let install = Task {
      try await store.install("test")
    }

    await downloader.waitUntilRequested("second")
    install.cancel()
    do {
      try await install.value
      XCTFail("A cancelled install must not be promoted")
    } catch is CancellationError {}

    let stagingFiles = try FileManager.default.subpathsOfDirectory(
      atPath: fixture.modelRoot.appendingPathComponent(".staging").path
    )
    XCTAssertFalse(stagingFiles.contains { $0.contains(".part-") })

    await downloader.setSuspendAt(nil)
    try await store.install("test")
    let counts = await downloader.counts
    XCTAssertEqual(counts["first"], 1)
    XCTAssertEqual(counts["second"], 2)
    let installed = try await store.installed("test")
    XCTAssertTrue(installed)
  }

  func testReconciliationRejectsChangedInstalledBytes() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let store = fixture.store()
    try await store.install("test")
    let lease = try await store.acquire("test")
    await store.release(lease)
    try Data("wrong".utf8).write(to: lease.directory.appendingPathComponent("first"))
    let installed = try await store.installed("test")
    XCTAssertFalse(installed)
  }

  func testWriteFailureDoesNotInstallAndDoesNotDeleteExternalDirectory() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    try Data("blocked".utf8).write(to: fixture.modelRoot)
    do {
      try await fixture.store().install("test")
      XCTFail("A non-directory root cannot be installed")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: fixture.modelRoot), Data("blocked".utf8))
  }

  func testPromotionFailureRestoresPreviousDirectoryAndRetryUsesStaging() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    let installedDirectory = fixture.modelRoot.appendingPathComponent("test-immutable")
    try FileManager.default.createDirectory(at: installedDirectory, withIntermediateDirectories: true)
    let sentinel = installedDirectory.appendingPathComponent("existing")
    try Data("preserve".utf8).write(to: sentinel)
    let fileManager = FailingFileManager()
    fileManager.failNextStagingPromotion()
    let downloader = FixtureDownloader(root: fixture.downloadRoot)
    let store = fixture.store(downloader: downloader, fileManager: fileManager)

    do {
      try await store.install("test")
      XCTFail("The injected promotion failure must escape")
    } catch FailingFileManager.InjectedError.promotion {}
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))

    try await store.install("test")
    let counts = await downloader.counts
    XCTAssertEqual(counts["first"], 1)
    XCTAssertEqual(counts["second"], 1)
    let installed = try await store.installed("test")
    XCTAssertTrue(installed)
  }

  func testSymbolicLinkRootIsRejectedWithoutChangingTarget() async throws {
    let fixture = try Fixture()
    defer { fixture.clean() }
    try FileManager.default.createSymbolicLink(at: fixture.modelRoot, withDestinationURL: fixture.downloadRoot)
    do {
      try await fixture.store().install("test")
      XCTFail("A symbolic link is not an owned model root")
    } catch LocalModelStore.StoreError.unsafePath {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.downloadRoot.path))
  }

  func testSymbolicLinkOwnedParentRejectsInstallWithoutChangingTarget() async throws {
    let fixture = try OwnedParentSymlinkFixture()
    defer { fixture.clean() }
    let store = fixture.store()

    do {
      try await store.install("test")
      XCTFail("A symbolic link is not an owned model parent")
    } catch LocalModelStore.StoreError.unsafePath {}

    XCTAssertEqual(try Data(contentsOf: fixture.sentinel), Data("preserve".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.externalModelRoot.path))
  }

  func testSymbolicLinkOwnedParentRejectsRemovalWithoutChangingTarget() async throws {
    let fixture = try OwnedParentSymlinkFixture(installedModel: true)
    defer { fixture.clean() }
    let store = fixture.store()

    do {
      try await store.remove("test")
      XCTFail("Removal must not traverse a symbolic model parent")
    } catch LocalModelStore.StoreError.unsafePath {}

    XCTAssertEqual(try Data(contentsOf: fixture.sentinel), Data("preserve".utf8))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.externalModelRoot.path))
  }
}

private struct OwnedParentSymlinkFixture {
  let scratch: URL
  let ownedParent: URL
  let externalParent: URL
  let sentinel: URL

  var modelRoot: URL {
    ownedParent.appendingPathComponent("Models")
  }

  var externalModelRoot: URL {
    externalParent.appendingPathComponent("Models/test-immutable")
  }

  init(installedModel: Bool = false) throws {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    ownedParent = scratch.appendingPathComponent("Hubris Voice")
    externalParent = scratch.appendingPathComponent("External")
    sentinel = externalParent.appendingPathComponent("sentinel")
    try FileManager.default.createDirectory(at: externalParent, withIntermediateDirectories: true)
    try Data("preserve".utf8).write(to: sentinel)
    if installedModel {
      try FileManager.default.createDirectory(at: externalModelRoot, withIntermediateDirectories: true)
      try Data("first".utf8).write(to: externalModelRoot.appendingPathComponent("first"))
      try Data("second".utf8).write(to: externalModelRoot.appendingPathComponent("second"))
    }
    try FileManager.default.createSymbolicLink(at: ownedParent, withDestinationURL: externalParent)
  }

  func clean() {
    try? FileManager.default.removeItem(at: scratch)
  }

  func store() -> LocalModelStore {
    Fixture.store(root: modelRoot)
  }
}

private struct Fixture {
  let root: URL
  var modelRoot: URL {
    root.appendingPathComponent("Models")
  }

  var downloadRoot: URL {
    root.appendingPathComponent("Downloads")
  }

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
  }

  func clean() {
    try? FileManager.default.removeItem(at: root)
  }

  func store(
    downloader: FixtureDownloader? = nil,
    fileManager: any LocalModelFileManaging = LocalModelFileManager()
  ) -> LocalModelStore {
    let artifacts = ["first", "second"].map { name in
      LocalModelArtifact(
        relativePath: name, byteCount: Int64(name.utf8.count),
        sha256: SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
      )
    }
    let model = LocalModelDefinition(
      id: "test", title: "Test", repository: "test/model", revision: "immutable", license: "Test", artifacts: artifacts
    )
    return LocalModelStore(
      root: modelRoot,
      catalog: [model],
      downloader: downloader ?? FixtureDownloader(root: downloadRoot),
      fileManager: fileManager
    )
  }

  static func store(root: URL) -> LocalModelStore {
    let artifacts = ["first", "second"].map { name in
      LocalModelArtifact(
        relativePath: name, byteCount: Int64(name.utf8.count),
        sha256: SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
      )
    }
    let model = LocalModelDefinition(
      id: "test", title: "Test", repository: "test/model", revision: "immutable", license: "Test", artifacts: artifacts
    )
    return LocalModelStore(root: root, catalog: [model], downloader: FixtureDownloader(root: root))
  }
}

private actor FixtureDownloader: LocalModelDownloading {
  var corruptSecond: Bool
  var suspendAt: String?
  var counts: [String: Int] = [:]
  var expectedByteCounts: [String: [Int64]] = [:]
  private var requestWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

  init(root _: URL, corruptSecond: Bool = false, suspendAt: String? = nil) {
    self.corruptSecond = corruptSecond
    self.suspendAt = suspendAt
  }

  func setCorrupt(_ value: Bool) {
    corruptSecond = value
  }

  func setSuspendAt(_ name: String?) {
    suspendAt = name
  }

  func waitUntilRequested(_ name: String) async {
    if counts[name, default: 0] > 0 {
      return
    }
    await withCheckedContinuation { continuation in
      requestWaiters[name, default: []].append(continuation)
    }
  }

  func download(
    from url: URL,
    to destination: URL,
    expectedByteCount: Int64,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    let name = url.lastPathComponent
    counts[name, default: 0] += 1
    expectedByteCounts[name, default: []].append(expectedByteCount)
    let waiters = requestWaiters.removeValue(forKey: name) ?? []
    waiters.forEach { $0.resume() }
    if suspendAt == name {
      try Data("partial".utf8).write(to: destination)
      try await Task.sleep(for: .seconds(60))
    }
    let data = Data((corruptSecond && name == "second" ? "broken" : name).utf8)
    try data.write(to: destination)
    progress(Int64(data.count))
  }
}

private struct DownloaderFixture {
  let root: URL
  let source: URL
  let destination: URL
  let downloader: URLSessionModelDownloader

  init(chunks: [Data]) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    guard let sourceURL = URL(string: "https://example.invalid/\(UUID().uuidString)") else {
      throw URLError(.badURL)
    }
    source = sourceURL
    destination = root.appendingPathComponent("artifact.part")
    StubURLProtocol.register(chunks: chunks, for: source)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    downloader = URLSessionModelDownloader(configuration: configuration)
  }

  func clean() {
    try? FileManager.default.removeItem(at: root)
  }
}

private final class ProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedValues: [Int64] = []

  var values: [Int64] {
    lock.withLock { recordedValues }
  }

  func record(_ value: Int64) {
    lock.withLock { recordedValues.append(value) }
  }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  private static let fixtures = FixtureRegistry()

  static func register(chunks: [Data], for url: URL) {
    fixtures.register(chunks: chunks, for: url)
  }

  // swiftlint:disable:next static_over_final_class
  override class func canInit(with request: URLRequest) -> Bool {
    request.url.map { fixtures.contains($0) } ?? false
  }

  // swiftlint:disable:next static_over_final_class
  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url,
          let chunks = Self.fixtures.take(url),
          let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
          )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for chunk in chunks {
      client?.urlProtocol(self, didLoad: chunk)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private final class FixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var chunksByURL: [URL: [Data]] = [:]

    func register(chunks: [Data], for url: URL) {
      lock.withLock { chunksByURL[url] = chunks }
    }

    func contains(_ url: URL) -> Bool {
      lock.withLock { chunksByURL[url] != nil }
    }

    func take(_ url: URL) -> [Data]? {
      lock.withLock { chunksByURL.removeValue(forKey: url) }
    }
  }
}

private final class FailingFileManager: LocalModelFileManaging, @unchecked Sendable {
  enum InjectedError: Error {
    case promotion
  }

  private let lock = NSLock()
  private var failPromotion = false

  func failNextStagingPromotion() {
    lock.withLock {
      failPromotion = true
    }
  }

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
    let shouldFail = lock.withLock {
      guard failPromotion,
            source.deletingLastPathComponent().lastPathComponent == ".staging"
      else { return false }
      failPromotion = false
      return true
    }
    if shouldFail {
      throw InjectedError.promotion
    }
    try FileManager.default.moveItem(at: source, to: destination)
  }

  func removeItem(at url: URL) throws {
    try FileManager.default.removeItem(at: url)
  }
}
