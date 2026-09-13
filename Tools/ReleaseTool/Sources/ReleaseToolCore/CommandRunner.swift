import Foundation

public enum CommandOutputMode: Sendable {
  case captured
  case inherited
}

public struct CommandInvocation: Sendable {
  public let executable: String
  public let arguments: [String]
  public let standardInput: Data?
  public let outputMode: CommandOutputMode
  public let displayName: String

  public init(
    _ executable: String,
    _ arguments: [String] = [],
    standardInput: Data? = nil,
    outputMode: CommandOutputMode = .inherited,
    displayName: String? = nil
  ) {
    self.executable = executable
    self.arguments = arguments
    self.standardInput = standardInput
    self.outputMode = outputMode
    self.displayName = displayName ?? executable
  }
}

public struct CommandOutput: Equatable, Sendable {
  public let standardOutput: String
  public let standardError: String

  public init(standardOutput: String = "", standardError: String = "") {
    self.standardOutput = standardOutput
    self.standardError = standardError
  }
}

public protocol CommandRunning: Sendable {
  func run(_ invocation: CommandInvocation) throws -> CommandOutput
}

public struct SystemCommandRunner: CommandRunning {
  public init() {}

  public func run(_ invocation: CommandInvocation) throws -> CommandOutput {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [invocation.executable] + invocation.arguments

    let capture: CommandCapture?
    switch invocation.outputMode {
    case .captured:
      capture = try CommandCapture()
      process.standardOutput = capture?.standardOutputHandle
      process.standardError = capture?.standardErrorHandle
    case .inherited:
      capture = nil
      process.standardOutput = FileHandle.standardOutput
      process.standardError = FileHandle.standardError
    }
    defer { capture?.cleanup() }

    let standardInputPipe: Pipe?
    if invocation.standardInput != nil {
      standardInputPipe = Pipe()
      process.standardInput = standardInputPipe
    } else {
      standardInputPipe = nil
      process.standardInput = FileHandle.standardInput
    }

    do {
      try process.run()
    } catch {
      throw ReleaseToolError.message("Could not start \(invocation.displayName): \(error.localizedDescription)")
    }

    if let standardInput = invocation.standardInput, let standardInputPipe {
      standardInputPipe.fileHandleForWriting.write(standardInput)
      try standardInputPipe.fileHandleForWriting.close()
    }

    process.waitUntilExit()
    try capture?.close()
    let standardOutput = try capture?.standardOutput() ?? ""
    let standardError = try capture?.standardError() ?? ""
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      let diagnostic = [standardOutput, standardError]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
      let suffix = diagnostic.isEmpty ? "" : ":\n\(diagnostic)"
      throw ReleaseToolError.message(
        "\(invocation.displayName) failed with exit code \(process.terminationStatus)\(suffix)"
      )
    }
    return CommandOutput(standardOutput: standardOutput, standardError: standardError)
  }
}

private final class CommandCapture {
  let standardOutputHandle: FileHandle
  let standardErrorHandle: FileHandle

  private let directory: URL
  private let standardOutputURL: URL
  private let standardErrorURL: URL

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appending(path: "hubris-release-command.\(UUID().uuidString)")
    standardOutputURL = directory.appending(path: "stdout")
    standardErrorURL = directory.appending(path: "stderr")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      try Data().write(to: standardOutputURL)
      try Data().write(to: standardErrorURL)
      standardOutputHandle = try FileHandle(forWritingTo: standardOutputURL)
      standardErrorHandle = try FileHandle(forWritingTo: standardErrorURL)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  func close() throws {
    var firstError: Error?
    for handle in [standardOutputHandle, standardErrorHandle] {
      do {
        try handle.close()
      } catch {
        firstError = firstError ?? error
      }
    }
    if let firstError {
      throw firstError
    }
  }

  func standardOutput() throws -> String {
    try read(standardOutputURL)
  }

  func standardError() throws -> String {
    try read(standardErrorURL)
  }

  func cleanup() {
    try? standardOutputHandle.close()
    try? standardErrorHandle.close()
    try? FileManager.default.removeItem(at: directory)
  }

  private func read(_ source: URL) throws -> String {
    let data = try Data(contentsOf: source)
    guard let value = String(data: data, encoding: .utf8) else {
      throw ReleaseToolError.message("Command output was not valid UTF-8")
    }
    return value
  }
}
