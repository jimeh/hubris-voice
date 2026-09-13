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

    let standardOutputPipe: Pipe?
    let standardErrorPipe: Pipe?
    switch invocation.outputMode {
    case .captured:
      standardOutputPipe = Pipe()
      standardErrorPipe = Pipe()
      process.standardOutput = standardOutputPipe
      process.standardError = standardErrorPipe
    case .inherited:
      standardOutputPipe = nil
      standardErrorPipe = nil
      process.standardOutput = FileHandle.standardOutput
      process.standardError = FileHandle.standardError
    }

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
    let standardOutput = try read(standardOutputPipe)
    let standardError = try read(standardErrorPipe)
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

  private func read(_ pipe: Pipe?) throws -> String {
    guard let pipe else {
      return ""
    }
    let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
    guard let value = String(data: data, encoding: .utf8) else {
      throw ReleaseToolError.message("Command output was not valid UTF-8")
    }
    return value
  }
}
