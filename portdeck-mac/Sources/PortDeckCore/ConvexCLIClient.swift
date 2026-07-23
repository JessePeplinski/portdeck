import Foundation

public struct ConvexCommandResult: Equatable, Sendable {
  public let stdout: Data
  public let stderr: Data
  public let terminationStatus: Int32

  public init(stdout: Data, stderr: Data = Data(), terminationStatus: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.terminationStatus = terminationStatus
  }
}

public protocol ConvexCommandRunning: Sendable {
  func run(executableURL: URL, arguments: [String], currentDirectoryURL: URL) async throws -> ConvexCommandResult
}

public protocol ConvexCLIClientProtocol: Sendable {
  func fetchProductionHealth(
    for candidate: ConvexProjectCandidate,
    target: ConvexProductionTarget
  ) async throws -> ConvexInsightsResponse
  func login(using candidate: ConvexProjectCandidate) async throws
}

public struct SystemConvexCommandRunner: ConvexCommandRunning {
  public init() {}

  public func run(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL
  ) async throws -> ConvexCommandResult {
    try await Task.detached {
      try Self.runSync(
        executableURL: executableURL,
        arguments: arguments,
        currentDirectoryURL: currentDirectoryURL
      )
    }.value
  }

  private static func runSync(
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL
  ) throws -> ConvexCommandResult {
    let fileManager = FileManager.default
    let token = UUID().uuidString
    let stdoutURL = fileManager.temporaryDirectory.appendingPathComponent("portdeck-convex-\(token)-stdout")
    let stderrURL = fileManager.temporaryDirectory.appendingPathComponent("portdeck-convex-\(token)-stderr")

    guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
      fileManager.createFile(atPath: stderrURL.path, contents: nil)
    else {
      throw ConvexCLIError.commandFailed("Could not create secure temporary command output files.")
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
    process.environment = ProviderCLIExecutionEnvironment.make(
      executableURL: executableURL,
      base: ProcessInfo.processInfo.environment
    )
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

    return ConvexCommandResult(
      stdout: try Data(contentsOf: stdoutURL),
      stderr: try Data(contentsOf: stderrURL),
      terminationStatus: process.terminationStatus
    )
  }
}

public actor ConvexCLIClient: ConvexCLIClientProtocol {
  public static let supportedVersionRange = ConvexRuntimeResolver.supportedVersionRange

  private let runner: any ConvexCommandRunning
  private let runtimeResolver: any ConvexRuntimeResolving
  private var cachedExecutableURL: URL?

  public init(
    runner: any ConvexCommandRunning = SystemConvexCommandRunner(),
    runtimeResolver: any ConvexRuntimeResolving = ConvexRuntimeResolver()
  ) {
    self.runner = runner
    self.runtimeResolver = runtimeResolver
  }

  public func fetchProductionHealth(
    for candidate: ConvexProjectCandidate,
    target: ConvexProductionTarget
  ) async throws -> ConvexInsightsResponse {
    let packageURL = URL(fileURLWithPath: candidate.packagePath)
    let executableURL = try await validatedExecutableURL(currentDirectoryURL: packageURL)
    let result = try await runner.run(
      executableURL: executableURL,
      arguments: ["insights", "--json", "--deployment", target.deploymentReference],
      currentDirectoryURL: packageURL
    )
    guard result.terminationStatus == 0 else {
      throw classifiedFailure(from: result)
    }

    do {
      let response = try JSONDecoder().decode(ConvexInsightsResponse.self, from: result.stdout)
      guard response.deploymentName == target.deploymentName else {
        throw ConvexCLIError.invalidResponse("Convex returned health for an unexpected deployment.")
      }
      return response
    } catch let error as ConvexCLIError {
      throw error
    } catch {
      throw ConvexCLIError.invalidResponse(error.localizedDescription)
    }
  }

  public func login(using candidate: ConvexProjectCandidate) async throws {
    let packageURL = URL(fileURLWithPath: candidate.packagePath)
    let executableURL = try await validatedExecutableURL(currentDirectoryURL: packageURL)
    let result = try await runner.run(
      executableURL: executableURL,
      arguments: ["login", "--device-name", "PortDeck", "--login-flow", "poll"],
      currentDirectoryURL: packageURL
    )
    guard result.terminationStatus == 0 else {
      throw classifiedFailure(from: result)
    }
  }

  private func validatedExecutableURL(currentDirectoryURL: URL) async throws -> URL {
    if let cachedExecutableURL {
      return cachedExecutableURL
    }
    let executableURL = try runtimeResolver.resolveExecutableURL()
    let versionResult = try await runner.run(
      executableURL: executableURL,
      arguments: ["--version"],
      currentDirectoryURL: currentDirectoryURL
    )
    guard versionResult.terminationStatus == 0 else {
      throw classifiedFailure(from: versionResult)
    }
    let output = versionResult.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty else {
      throw ConvexCLIError.invalidResponse("Could not read the installed Convex CLI version.")
    }
    guard let version = ProviderCLIVersion.first(in: output) else {
      throw ConvexCLIError.unsupportedCLI(currentVersion: String(output.prefix(80)))
    }
    guard Self.supportedVersionRange.contains(version) else {
      throw ConvexCLIError.unsupportedCLI(currentVersion: version.description)
    }
    cachedExecutableURL = executableURL
    return executableURL
  }

  private func classifiedFailure(from result: ConvexCommandResult) -> ConvexCLIError {
    let rawMessage = [result.stderrString, result.stdoutString]
      .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    let normalized = rawMessage.lowercased()

    if normalized.contains("insights require to be logged in")
      || normalized.contains("not logged in")
      || normalized.contains("convex login")
    {
      return .unauthenticated
    }
    if normalized.contains("convex_deployment")
      || normalized.contains("configure a new or existing project")
      || normalized.contains("run `npx convex dev`")
    {
      return .unconfigured
    }

    let message = sanitizedMessage(rawMessage)
    if message.isEmpty {
      return .commandFailed("Convex CLI command failed with exit code \(result.terminationStatus).")
    }
    return .commandFailed(message)
  }

  private func sanitizedMessage(_ rawMessage: String) -> String {
    var message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacements = [
      (#"(?i)(CONVEX_DEPLOY_KEY\s*[=:]\s*)\S+"#, "$1<redacted>"),
      (#"(?i)((?:authorization:\s*bearer|bearer|access[_ -]?token|CONVEX_ACCESS_TOKEN)\s*[=:]?\s*)\S+"#, "$1<redacted>"),
      (#"\|[A-Za-z0-9_+./=-]{20,}"#, "<redacted>"),
      (#"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]{10,})?"#, "<redacted>")
    ]
    for (pattern, replacement) in replacements {
      guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(message.startIndex..., in: message)
      message = expression.stringByReplacingMatches(
        in: message,
        range: range,
        withTemplate: replacement
      )
    }
    return String(message.prefix(500))
  }
}

public enum ConvexCLIError: LocalizedError, Equatable, Sendable {
  case missingCLI
  case unsupportedCLI(currentVersion: String)
  case unauthenticated
  case unconfigured
  case commandFailed(String)
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .missingCLI:
      return "Convex CLI is not installed."
    case .unsupportedCLI(let currentVersion):
      return "PortDeck found Convex CLI \(currentVersion), but supports \(ConvexCLIClient.supportedVersionRange.displayName)."
    case .unauthenticated:
      return "Sign in with Convex CLI to read production health."
    case .unconfigured:
      return "This package is not linked to a Convex project."
    case .commandFailed(let message):
      return message
    case .invalidResponse(let message):
      return "Could not parse Convex health: \(message)"
    }
  }
}

private extension ConvexCommandResult {
  var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
  var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
}
