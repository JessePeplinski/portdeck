import Foundation

public struct SupabaseCommandResult: Equatable, Sendable {
  public let stdout: Data
  public let stderr: Data
  public let terminationStatus: Int32

  public init(stdout: Data, stderr: Data = Data(), terminationStatus: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.terminationStatus = terminationStatus
  }
}

public protocol SupabaseCommandRunning: Sendable {
  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> SupabaseCommandResult
}

public protocol SupabaseCLIClientProtocol: Sendable {
  func fetchProjects() async throws -> [SupabaseProject]
}

public struct SystemSupabaseCommandRunner: SupabaseCommandRunning {
  public init() {}

  public func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> SupabaseCommandResult {
    try await Task.detached {
      try Self.runSync(
        executableURL: executableURL,
        arguments: arguments,
        environment: environment,
        currentDirectoryURL: currentDirectoryURL
      )
    }.value
  }

  private static func runSync(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) throws -> SupabaseCommandResult {
    let fileManager = FileManager.default
    let nonce = UUID().uuidString
    let stdoutURL = fileManager.temporaryDirectory.appendingPathComponent("portdeck-supabase-\(nonce)-stdout")
    let stderrURL = fileManager.temporaryDirectory.appendingPathComponent("portdeck-supabase-\(nonce)-stderr")

    guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
      fileManager.createFile(atPath: stderrURL.path, contents: nil)
    else {
      throw SupabaseCLIError.commandFailed("Could not create secure temporary command output files.")
    }

    defer {
      try? fileManager.removeItem(at: stdoutURL)
      try? fileManager.removeItem(at: stderrURL)
    }

    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stdoutURL.path)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stderrURL.path)

    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = currentDirectoryURL
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      try? stdoutHandle.close()
      try? stderrHandle.close()
      throw error
    }

    try stdoutHandle.close()
    try stderrHandle.close()
    return SupabaseCommandResult(
      stdout: try Data(contentsOf: stdoutURL),
      stderr: try Data(contentsOf: stderrURL),
      terminationStatus: process.terminationStatus
    )
  }
}

public actor SupabaseCLIClient: SupabaseCLIClientProtocol {
  public static let pinnedVersion = SupabaseRuntimeResolver.pinnedVersion
  public static let loginCommand = "supabase login"

  private let runner: any SupabaseCommandRunning
  private let runtimeResolver: any SupabaseRuntimeResolving
  private let environment: [String: String]
  private let currentDirectoryURL: URL
  private var cachedExecutableURL: URL?

  public init(
    runner: any SupabaseCommandRunning = SystemSupabaseCommandRunner(),
    runtimeResolver: any SupabaseRuntimeResolving = SupabaseRuntimeResolver(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectoryURL: URL = FileManager.default.temporaryDirectory
  ) {
    self.runner = runner
    self.runtimeResolver = runtimeResolver
    var environment = environment
    environment["SUPABASE_TELEMETRY_DISABLED"] = "1"
    self.environment = environment
    self.currentDirectoryURL = currentDirectoryURL
  }

  public func fetchProjects() async throws -> [SupabaseProject] {
    let executableURL = try await validatedExecutableURL()
    let result = try await runner.run(
      executableURL: executableURL,
      arguments: ["projects", "list", "--output-format", "json"],
      environment: environment,
      currentDirectoryURL: currentDirectoryURL
    )
    guard result.terminationStatus == 0 else {
      throw classifiedFailure(from: result)
    }

    do {
      return try JSONDecoder().decode(SupabaseProjectsEnvelope.self, from: result.stdout).projects
    } catch {
      throw SupabaseCLIError.invalidResponse(error.localizedDescription)
    }
  }

  private func validatedExecutableURL() async throws -> URL {
    if let cachedExecutableURL { return cachedExecutableURL }
    let executableURL = try runtimeResolver.resolveExecutableURL()
    let result = try await runner.run(
      executableURL: executableURL,
      arguments: ["--version"],
      environment: environment,
      currentDirectoryURL: currentDirectoryURL
    )
    guard result.terminationStatus == 0 else {
      throw classifiedFailure(from: result)
    }

    let version = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !version.isEmpty else {
      throw SupabaseCLIError.invalidResponse("Could not read the PortDeck-managed Supabase CLI version.")
    }
    guard version == Self.pinnedVersion else {
      throw SupabaseCLIError.incompatibleRuntime(currentVersion: String(version.prefix(80)))
    }
    cachedExecutableURL = executableURL
    return executableURL
  }

  private func classifiedFailure(from result: SupabaseCommandResult) -> SupabaseCLIError {
    let envelope = try? JSONDecoder().decode(SupabaseCLIErrorEnvelope.self, from: result.stdout)
    let rawMessage = envelope?.error.message ?? [result.stderrString, result.stdoutString]
      .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    let code = envelope?.error.code.lowercased() ?? ""
    let normalized = rawMessage.lowercased()

    if code.contains("authrequired")
      || normalized.contains("access token not provided")
      || normalized.contains("supabase login")
    {
      return .authenticationRequired
    }
    if normalized.contains("rate limit")
      || normalized.contains("too many requests")
      || normalized.contains("429")
    {
      return .rateLimited
    }

    let message = sanitizedMessage(rawMessage)
    if message.isEmpty {
      return .commandFailed("Supabase CLI failed with exit code \(result.terminationStatus).")
    }
    return .commandFailed(message)
  }

  private func sanitizedMessage(_ rawMessage: String) -> String {
    var message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacements = [
      (#"(?i)(SUPABASE_ACCESS_TOKEN\s*[=:]\s*)\S+"#, "$1<redacted>"),
      (#"(?i)((?:authorization:\s*bearer|bearer|access[_ -]?token)\s*[=:]?\s*)\S+"#, "$1<redacted>"),
      (#"sbp_[A-Za-z0-9_-]{20,}"#, "<redacted>"),
      (#"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]{10,})?"#, "<redacted>")
    ]
    for (pattern, replacement) in replacements {
      guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(message.startIndex..., in: message)
      message = expression.stringByReplacingMatches(in: message, range: range, withTemplate: replacement)
    }
    return String(message.prefix(500))
  }
}

public enum SupabaseCLIError: LocalizedError, Equatable, Sendable {
  case missingRuntime
  case incompatibleRuntime(currentVersion: String)
  case authenticationRequired
  case rateLimited
  case commandFailed(String)
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .missingRuntime:
      return "PortDeck's managed Supabase runtime is unavailable."
    case .incompatibleRuntime(let currentVersion):
      return "PortDeck found Supabase CLI \(currentVersion), but this build requires exactly \(SupabaseCLIClient.pinnedVersion)."
    case .authenticationRequired:
      return "Supabase authentication required. Run `\(SupabaseCLIClient.loginCommand)` in Terminal."
    case .rateLimited:
      return "Supabase API rate limit reached. PortDeck will retry on the next scheduled refresh."
    case .commandFailed(let message):
      return message
    case .invalidResponse(let message):
      return "Could not parse Supabase projects: \(message)"
    }
  }
}

private struct SupabaseCLIErrorEnvelope: Decodable {
  struct Payload: Decodable {
    let code: String
    let message: String
  }

  let error: Payload
}

private extension SupabaseCommandResult {
  var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
  var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
}
