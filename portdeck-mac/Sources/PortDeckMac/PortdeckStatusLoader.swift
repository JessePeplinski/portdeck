import Foundation
import PortDeckCore

struct LoadedPortdeckStatus: Sendable {
  let status: PortdeckStatus
  let rawJSON: String
}

protocol PortdeckStatusLoading: Sendable {
  func load() async throws -> LoadedPortdeckStatus
  func stopService(id serviceId: String) async throws -> PortdeckStopResult
  func suggestProject(path: String, serviceIDs: [String]) async throws -> SavedProjectSuggestionResult
  func saveProject(_ draft: SavedProjectDraft) async throws
  func removeProject(id projectId: String) async throws
  func startProject(id projectId: String, port: Int?) async throws -> SavedProjectRunResult
  func stopProject(id projectId: String) async throws -> SavedProjectRunResult
  func restartProject(id projectId: String, port: Int) async throws -> SavedProjectRunResult
}

extension PortdeckStatusLoading {
  func suggestProject(path: String, serviceIDs: [String]) async throws -> SavedProjectSuggestionResult { throw PortdeckStatusLoaderError.unsupported }
  func saveProject(_ draft: SavedProjectDraft) async throws { throw PortdeckStatusLoaderError.unsupported }
  func removeProject(id projectId: String) async throws { throw PortdeckStatusLoaderError.unsupported }
  func startProject(id projectId: String, port: Int?) async throws -> SavedProjectRunResult { throw PortdeckStatusLoaderError.unsupported }
  func stopProject(id projectId: String) async throws -> SavedProjectRunResult { throw PortdeckStatusLoaderError.unsupported }
  func restartProject(id projectId: String, port: Int) async throws -> SavedProjectRunResult { throw PortdeckStatusLoaderError.unsupported }
}

struct LivePortdeckStatusLoader: PortdeckStatusLoading {
  func load() async throws -> LoadedPortdeckStatus {
    try await PortdeckStatusLoader.load()
  }

  func stopService(id serviceId: String) async throws -> PortdeckStopResult {
    try await PortdeckStatusLoader.stopService(id: serviceId)
  }

  func suggestProject(path: String, serviceIDs: [String]) async throws -> SavedProjectSuggestionResult {
    try await PortdeckStatusLoader.suggestProject(path: path, serviceIDs: serviceIDs)
  }

  func saveProject(_ draft: SavedProjectDraft) async throws {
    try await PortdeckStatusLoader.saveProject(draft)
  }

  func removeProject(id projectId: String) async throws {
    try await PortdeckStatusLoader.removeProject(id: projectId)
  }

  func startProject(id projectId: String, port: Int?) async throws -> SavedProjectRunResult {
    try await PortdeckStatusLoader.startProject(id: projectId, port: port)
  }

  func stopProject(id projectId: String) async throws -> SavedProjectRunResult {
    try await PortdeckStatusLoader.stopProject(id: projectId)
  }

  func restartProject(id projectId: String, port: Int) async throws -> SavedProjectRunResult {
    try await PortdeckStatusLoader.restartProject(id: projectId, port: port)
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

  static func suggestProject(path: String, serviceIDs: [String]) async throws -> SavedProjectSuggestionResult {
    var arguments = ["projects", "suggest", "--path", path]
    for serviceID in serviceIDs {
      arguments += ["--service-id", serviceID]
    }
    arguments.append("--json")
    return try await runJSON(arguments: arguments)
  }

  static func saveProject(_ draft: SavedProjectDraft) async throws {
    let data = try JSONEncoder().encode(draft)
    guard let input = String(data: data, encoding: .utf8) else {
      throw PortdeckStatusLoaderError.invalidJSON("Could not encode saved project.")
    }
    let result = try await runResult(arguments: ["projects", "save", "--input", input, "--json"])
    guard result.terminationStatus == 0 else {
      throw PortdeckStatusLoaderError.commandFailed(decodedErrorMessage(result))
    }
  }

  static func removeProject(id projectId: String) async throws {
    let result = try await runResult(arguments: ["projects", "remove", "--project-id", projectId, "--json"])
    guard result.terminationStatus == 0 else {
      throw PortdeckStatusLoaderError.commandFailed(decodedErrorMessage(result))
    }
  }

  static func startProject(id projectId: String, port: Int?) async throws -> SavedProjectRunResult {
    var arguments = ["run", "start", "--project-id", projectId]
    if let port { arguments += ["--port", String(port)] }
    arguments.append("--json")
    return try await runActionJSON(arguments: arguments)
  }

  static func stopProject(id projectId: String) async throws -> SavedProjectRunResult {
    try await runActionJSON(arguments: ["run", "stop", "--project-id", projectId, "--json"])
  }

  static func restartProject(id projectId: String, port: Int) async throws -> SavedProjectRunResult {
    try await runActionJSON(arguments: ["run", "restart", "--project-id", projectId, "--port", String(port), "--json"])
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

  private static func runResult(arguments: [String]) async throws -> PortdeckCommandResult {
    try await Task.detached { try runPortdeckCommand(arguments: arguments) }.value
  }

  private static func runJSON<T: Decodable & Sendable>(arguments: [String]) async throws -> T {
    let result = try await runResult(arguments: arguments)
    guard result.terminationStatus == 0 else {
      throw PortdeckStatusLoaderError.commandFailed(decodedErrorMessage(result))
    }
    do {
      return try JSONDecoder().decode(T.self, from: result.stdout)
    } catch {
      throw PortdeckStatusLoaderError.invalidJSON(error.localizedDescription)
    }
  }

  private static func runActionJSON(arguments: [String]) async throws -> SavedProjectRunResult {
    let result = try await runResult(arguments: arguments)
    do {
      return try JSONDecoder().decode(SavedProjectRunResult.self, from: result.stdout)
    } catch {
      if result.terminationStatus != 0 {
        throw PortdeckStatusLoaderError.commandFailed(decodedErrorMessage(result))
      }
      throw PortdeckStatusLoaderError.invalidJSON(error.localizedDescription)
    }
  }

  private static func decodedErrorMessage(_ result: PortdeckCommandResult) -> String {
    if let decoded = try? JSONDecoder().decode(SavedProjectMutationResult.self, from: result.stdout),
      let message = decoded.message
    {
      return message
    }
    return result.errorMessage ?? "PortDeck project command failed."
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
  case unsupported

  var errorDescription: String? {
    switch self {
    case .commandFailed(let message):
      return message
    case .invalidJSON(let message):
      return "Could not parse portdeck status JSON: \(message)"
    case .unsupported:
      return "Saved project actions are unavailable."
    }
  }
}
