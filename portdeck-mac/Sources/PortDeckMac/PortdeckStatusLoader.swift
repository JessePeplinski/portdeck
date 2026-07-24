import Foundation
import PortDeckCore

struct LoadedPortdeckStatus: Sendable {
  let status: PortdeckStatus
  let rawJSON: String
}

protocol PortdeckStatusLoading: Sendable {
  func load() async throws -> LoadedPortdeckStatus
  func stopService(id serviceId: String) async throws -> PortdeckStopResult
}

struct LivePortdeckStatusLoader: PortdeckStatusLoading {
  func load() async throws -> LoadedPortdeckStatus {
    try await PortdeckStatusLoader.load()
  }

  func stopService(id serviceId: String) async throws -> PortdeckStopResult {
    try await PortdeckStatusLoader.stopService(id: serviceId)
  }
}

enum PortdeckStatusLoader {
  static func load() async throws -> LoadedPortdeckStatus {
    try await Task.detached {
      try loadSync()
    }.value
  }

  static func stopService(id serviceId: String) async throws -> PortdeckStopResult {
    try await Task.detached {
      try stopServiceSync(id: serviceId)
    }.value
  }

  private static func loadSync() throws -> LoadedPortdeckStatus {
    let result = try runPortdeckCommand(arguments: ["status", "--json"])
    let rawJSON = result.stdoutString

    guard result.terminationStatus == 0 else {
      throw PortdeckStatusLoaderError.commandFailed(result.errorMessage ?? "portdeck status --json failed")
    }

    do {
      let status = try JSONDecoder().decode(PortdeckStatus.self, from: result.stdout)
      return LoadedPortdeckStatus(status: status, rawJSON: rawJSON)
    } catch {
      throw PortdeckStatusLoaderError.invalidJSON(error.localizedDescription)
    }
  }

  private static func stopServiceSync(id serviceId: String) throws -> PortdeckStopResult {
    let result = try runPortdeckCommand(arguments: ["stop", "--service-id", serviceId, "--json"])

    do {
      return try JSONDecoder().decode(PortdeckStopResult.self, from: result.stdout)
    } catch {
      if result.terminationStatus != 0 {
        throw PortdeckStatusLoaderError.commandFailed(result.errorMessage ?? "portdeck stop failed")
      }
      throw PortdeckStatusLoaderError.invalidJSON(error.localizedDescription)
    }
  }

  private static func runPortdeckCommand(arguments: [String]) throws -> PortdeckCommandResult {
    let runtime = try PortdeckRuntimeResolver().resolveRuntime()
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()

    process.executableURL = runtime.nodeURL
    process.arguments = [runtime.cliURL.path] + arguments
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()

    return PortdeckCommandResult(
      stdout: output,
      stderr: errorOutput,
      terminationStatus: process.terminationStatus
    )
  }

}

private struct PortdeckCommandResult {
  let stdout: Data
  let stderr: Data
  let terminationStatus: Int32

  var stdoutString: String {
    String(data: stdout, encoding: .utf8) ?? ""
  }

  var errorMessage: String? {
    let message = String(data: stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return message?.isEmpty == false ? message : nil
  }
}

enum PortdeckStatusLoaderError: LocalizedError {
  case commandFailed(String)
  case invalidJSON(String)

  var errorDescription: String? {
    switch self {
    case .commandFailed(let message):
      return message
    case .invalidJSON(let message):
      return "Could not parse portdeck status JSON: \(message)"
    }
  }
}
