import Foundation

public struct RailwayCommandResult: Equatable, Sendable {
  public let stdout: Data
  public let stderr: Data
  public let terminationStatus: Int32

  public init(stdout: Data, stderr: Data = Data(), terminationStatus: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.terminationStatus = terminationStatus
  }
}

public protocol RailwayCommandRunning: Sendable {
  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> RailwayCommandResult
}

public protocol RailwayCLIClientProtocol: Sendable {
  func fetchSnapshot() async throws -> RailwaySnapshotResult
}

public struct SystemRailwayCommandRunner: RailwayCommandRunning {
  public init() {}

  public func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> RailwayCommandResult {
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
  ) throws -> RailwayCommandResult {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: currentDirectoryURL, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: currentDirectoryURL.path)

    let nonce = UUID().uuidString
    let stdoutURL = currentDirectoryURL.appendingPathComponent("command-\(nonce)-stdout")
    let stderrURL = currentDirectoryURL.appendingPathComponent("command-\(nonce)-stderr")
    guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
      fileManager.createFile(atPath: stderrURL.path, contents: nil)
    else {
      throw RailwayCLIError.commandFailed("Could not create secure temporary command output files.")
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
      base: environment
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
    return RailwayCommandResult(
      stdout: try Data(contentsOf: stdoutURL),
      stderr: try Data(contentsOf: stderrURL),
      terminationStatus: process.terminationStatus
    )
  }
}

public actor RailwayCLIClient: RailwayCLIClientProtocol {
  public static let supportedVersionRange = RailwayRuntimeResolver.supportedVersionRange
  public static let loginCommand = "railway login"
  public static let maximumConcurrentScopedCommands = 4

  private let runner: any RailwayCommandRunning
  private let runtimeResolver: any RailwayRuntimeResolving
  private let environment: [String: String]
  private let currentDirectoryURL: URL
  private let limiter: RailwayCommandLimiter
  private var cachedExecutableURL: URL?

  public init(
    runner: any RailwayCommandRunning = SystemRailwayCommandRunner(),
    runtimeResolver: any RailwayRuntimeResolving = RailwayRuntimeResolver(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectoryURL: URL? = nil,
    maximumConcurrentScopedCommands: Int = RailwayCLIClient.maximumConcurrentScopedCommands
  ) {
    self.runner = runner
    self.runtimeResolver = runtimeResolver
    var environment = environment
    environment.removeValue(forKey: "RAILWAY_TOKEN")
    environment.removeValue(forKey: "RAILWAY_API_TOKEN")
    environment["RAILWAY_NO_TELEMETRY"] = "1"
    environment["DO_NOT_TRACK"] = "1"
    self.environment = environment
    self.currentDirectoryURL = currentDirectoryURL ?? Self.makeWorkingDirectory()
    limiter = RailwayCommandLimiter(limit: maximumConcurrentScopedCommands)
  }

  public func fetchSnapshot() async throws -> RailwaySnapshotResult {
    let executableURL = try await validatedExecutableURL()

    let identityData = try await Self.runJSON(
      runner: runner,
      executableURL: executableURL,
      arguments: ["whoami", "--json"],
      environment: environment,
      currentDirectoryURL: currentDirectoryURL
    )
    do {
      _ = try JSONDecoder().decode(RailwayIdentityResponse.self, from: identityData)
    } catch {
      throw RailwayCLIError.invalidResponse("Could not parse Railway account information.")
    }

    let projectsData = try await Self.runJSON(
      runner: runner,
      executableURL: executableURL,
      arguments: ["list", "--json"],
      environment: environment,
      currentDirectoryURL: currentDirectoryURL
    )
    let projectRows: [RailwayProjectRow]
    do {
      projectRows = try Self.railwayDecoder().decode([RailwayProjectRow].self, from: projectsData)
    } catch {
      throw RailwayCLIError.invalidResponse("Could not parse Railway projects.")
    }

    let baselineProjects = projectRows.map(\.project)
    let runner = runner
    let environment = environment
    let currentDirectoryURL = currentDirectoryURL
    let limiter = limiter

    return await withTaskGroup(of: RailwayProjectOutcome.self) { group in
      for project in baselineProjects {
        group.addTask {
          await Self.fetchProject(
            project,
            runner: runner,
            executableURL: executableURL,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            limiter: limiter
          )
        }
      }

      var projects: [RailwayProject] = []
      var successfulProjectIDs: Set<String> = []
      var failures: [RailwayScopedFailure] = []
      for await outcome in group {
        projects.append(outcome.project)
        if outcome.projectSucceeded { successfulProjectIDs.insert(outcome.project.id) }
        failures.append(contentsOf: outcome.failures)
      }
      return RailwaySnapshotResult(
        projects: RailwayStatusBuilder.sortedProjects(projects),
        successfulProjectIDs: successfulProjectIDs,
        failures: failures
      )
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
    guard result.terminationStatus == 0 else { throw Self.classifiedFailure(from: result) }
    let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty else {
      throw RailwayCLIError.invalidResponse("Could not read the installed Railway CLI version.")
    }
    guard let version = ProviderCLIVersion.first(in: output) else {
      throw RailwayCLIError.unsupportedCLI(currentVersion: String(output.prefix(80)))
    }
    guard Self.supportedVersionRange.contains(version) else {
      throw RailwayCLIError.unsupportedCLI(currentVersion: String(output.prefix(80)))
    }
    cachedExecutableURL = executableURL
    return executableURL
  }

  private static func fetchProject(
    _ project: RailwayProject,
    runner: any RailwayCommandRunning,
    executableURL: URL,
    environment: [String: String],
    currentDirectoryURL: URL,
    limiter: RailwayCommandLimiter
  ) async -> RailwayProjectOutcome {
    guard !project.isArchived, project.productionEnvironmentID != nil else {
      let unavailable = RailwayProject(
        id: project.id,
        name: project.name,
        workspace: project.workspace,
        productionEnvironmentID: project.productionEnvironmentID,
        isArchived: project.isArchived,
        productionState: .unavailable,
        services: []
      )
      return RailwayProjectOutcome(project: unavailable, projectSucceeded: true, failures: [])
    }

    do {
      let serviceData = try await limiter.withPermit {
        try await runJSON(
          runner: runner,
          executableURL: executableURL,
          arguments: [
            "service", "list",
            "--project", project.id,
            "--environment", "production",
            "--json"
          ],
          environment: environment,
          currentDirectoryURL: currentDirectoryURL
        )
      }
      let rows = try railwayDecoder().decode([RailwayServiceRow].self, from: serviceData)
      let baselineServices = rows.map(\.service)

      let enrichments = await withTaskGroup(of: RailwayDeploymentOutcome.self) { group in
        for service in baselineServices where service.latestDeployment != nil {
          group.addTask {
            do {
              let data = try await limiter.withPermit {
                try await runJSON(
                  runner: runner,
                  executableURL: executableURL,
                  arguments: [
                    "deployment", "list",
                    "--project", project.id,
                    "--environment", "production",
                    "--service", service.id,
                    "--limit", "1",
                    "--json"
                  ],
                  environment: environment,
                  currentDirectoryURL: currentDirectoryURL
                )
              }
              let rows = try railwayDecoder().decode([RailwayDeploymentRow].self, from: data)
              return RailwayDeploymentOutcome(serviceID: service.id, deployment: rows.first?.deployment, error: nil)
            } catch {
              return RailwayDeploymentOutcome(serviceID: service.id, deployment: nil, error: error)
            }
          }
        }

        var values: [RailwayDeploymentOutcome] = []
        for await value in group { values.append(value) }
        return values
      }

      let enrichmentByService = Dictionary(uniqueKeysWithValues: enrichments.map { ($0.serviceID, $0) })
      let services = baselineServices.map { service in
        service.mergingDeploymentMetadata(enrichmentByService[service.id]?.deployment)
      }
      let failures = enrichments.compactMap { outcome -> RailwayScopedFailure? in
        guard let error = outcome.error else { return nil }
        return scopedFailure(projectID: project.id, serviceID: outcome.serviceID, error: error)
      }
      let connected = RailwayProject(
        id: project.id,
        name: project.name,
        workspace: project.workspace,
        productionEnvironmentID: project.productionEnvironmentID,
        isArchived: project.isArchived,
        productionState: .available,
        services: RailwayStatusBuilder.sortedServices(services)
      )
      return RailwayProjectOutcome(project: connected, projectSucceeded: true, failures: failures)
    } catch {
      let message = error.localizedDescription
      let failed = RailwayProject(
        id: project.id,
        name: project.name,
        workspace: project.workspace,
        productionEnvironmentID: project.productionEnvironmentID,
        isArchived: project.isArchived,
        productionState: .failed(message: message),
        services: []
      )
      return RailwayProjectOutcome(
        project: failed,
        projectSucceeded: false,
        failures: [scopedFailure(projectID: project.id, error: error)]
      )
    }
  }

  private static func runJSON(
    runner: any RailwayCommandRunning,
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> Data {
    let result = try await runner.run(
      executableURL: executableURL,
      arguments: arguments,
      environment: environment,
      currentDirectoryURL: currentDirectoryURL
    )
    guard result.terminationStatus == 0 else { throw classifiedFailure(from: result) }
    return result.stdout
  }

  private static func scopedFailure(
    projectID: String,
    serviceID: String? = nil,
    error: Error
  ) -> RailwayScopedFailure {
    RailwayScopedFailure(
      projectID: projectID,
      serviceID: serviceID,
      message: error.localizedDescription,
      isRateLimited: error as? RailwayCLIError == .rateLimited
    )
  }

  private static func classifiedFailure(from result: RailwayCommandResult) -> RailwayCLIError {
    let rawMessage = [result.stderrString, result.stdoutString]
      .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    let normalized = rawMessage.lowercased()
    if normalized.contains("invalid_grant")
      || normalized.contains("unauthorized")
      || normalized.contains("please run `railway login`")
      || normalized.contains("please run railway login")
      || normalized.contains("not logged in")
    {
      return .authenticationRequired
    }
    if normalized.contains("rate limit")
      || normalized.contains("too many requests")
      || normalized.contains("http 429")
      || normalized.contains("status 429")
    {
      return .rateLimited
    }
    let message = sanitizedMessage(rawMessage)
    return .commandFailed(message.isEmpty
      ? "Railway CLI failed with exit code \(result.terminationStatus)."
      : message)
  }

  private static func sanitizedMessage(_ rawMessage: String) -> String {
    var message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacements = [
      (#"(?i)((?:RAILWAY_TOKEN|RAILWAY_API_TOKEN)\s*[=:]\s*)\S+"#, "$1<redacted>"),
      (#"(?i)((?:authorization:\s*bearer|bearer|access[_ -]?token)\s*[=:]?\s*)\S+"#, "$1<redacted>"),
      (#"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]{10,})?"#, "<redacted>")
    ]
    for (pattern, replacement) in replacements {
      guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(message.startIndex..., in: message)
      message = expression.stringByReplacingMatches(in: message, range: range, withTemplate: replacement)
    }
    return String(message.prefix(500))
  }

  private static func makeWorkingDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("portdeck-railway-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  private static func railwayDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 timestamp")
    }
    return decoder
  }
}

public enum RailwayCLIError: LocalizedError, Equatable, Sendable {
  case missingCLI
  case unsupportedCLI(currentVersion: String)
  case authenticationRequired
  case rateLimited
  case commandFailed(String)
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .missingCLI:
      return "Railway CLI is not installed."
    case .unsupportedCLI(let currentVersion):
      return "PortDeck found Railway CLI \(currentVersion), but supports \(RailwayCLIClient.supportedVersionRange.displayName)."
    case .authenticationRequired:
      return "Railway authentication required. Run `\(RailwayCLIClient.loginCommand)` in Terminal."
    case .rateLimited:
      return "Railway API rate limit reached. PortDeck will retry on the next scheduled refresh."
    case .commandFailed(let message):
      return message
    case .invalidResponse(let message):
      return message
    }
  }
}

private actor RailwayCommandLimiter {
  private var availablePermits: Int
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    availablePermits = max(1, limit)
  }

  func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    await acquire()
    do {
      let result = try await operation()
      release()
      return result
    } catch {
      release()
      throw error
    }
  }

  private func acquire() async {
    if availablePermits > 0 {
      availablePermits -= 1
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  private func release() {
    if waiters.isEmpty {
      availablePermits += 1
    } else {
      waiters.removeFirst().resume()
    }
  }
}

private struct RailwayIdentityResponse: Decodable {
  let workspaces: [RailwayWorkspace]
}

private struct RailwayConnection<Node: Decodable & Sendable>: Decodable, Sendable {
  let edges: [RailwayEdge<Node>]
}

private struct RailwayEdge<Node: Decodable & Sendable>: Decodable, Sendable {
  let node: Node
}

private struct RailwayEnvironmentRow: Decodable, Sendable {
  let id: String
  let name: String
  let canAccess: Bool?
}

private struct RailwayProjectRow: Decodable, Sendable {
  let id: String
  let name: String
  let deletedAt: String?
  let workspace: RailwayWorkspace
  let environments: RailwayConnection<RailwayEnvironmentRow>?

  var project: RailwayProject {
    let production = environments?.edges
      .map(\.node)
      .first { $0.name.caseInsensitiveCompare("production") == .orderedSame && $0.canAccess != false }
    return RailwayProject(
      id: id,
      name: name,
      workspace: workspace,
      productionEnvironmentID: production?.id,
      isArchived: deletedAt != nil,
      productionState: production == nil ? .unavailable : .available
    )
  }
}

private struct RailwayServiceRow: Decodable, Sendable {
  struct LatestDeployment: Decodable, Sendable {
    let id: String
    let status: String?
    let createdAt: Date?
  }

  let id: String
  let name: String
  let status: String?
  let latestDeployment: LatestDeployment?
  let url: String?
  let regions: [RailwayRegion]?
  let replicas: RailwayReplicas?

  var service: RailwayService {
    RailwayService(
      id: id,
      name: name,
      currentRawStatus: status,
      latestDeployment: latestDeployment.map {
        RailwayDeployment(id: $0.id, rawStatus: $0.status, createdAt: $0.createdAt)
      },
      productionURLString: url,
      regions: regions ?? [],
      replicas: replicas
    )
  }
}

private struct RailwayDeploymentRow: Decodable, Sendable {
  struct Metadata: Decodable, Sendable {
    let branch: String?
    let sourceBranch: String?
    let commitHash: String?
    let commitSha: String?
    let commitSHA: String?
    let commitMessage: String?
  }

  let id: String
  let status: String?
  let createdAt: Date?
  let meta: Metadata?

  var deployment: RailwayDeployment {
    RailwayDeployment(
      id: id,
      rawStatus: status,
      createdAt: createdAt,
      branch: meta?.branch ?? meta?.sourceBranch,
      commitSHA: meta?.commitHash ?? meta?.commitSha ?? meta?.commitSHA,
      commitMessage: meta?.commitMessage
    )
  }
}

private struct RailwayProjectOutcome: Sendable {
  let project: RailwayProject
  let projectSucceeded: Bool
  let failures: [RailwayScopedFailure]
}

private struct RailwayDeploymentOutcome: @unchecked Sendable {
  let serviceID: String
  let deployment: RailwayDeployment?
  let error: Error?
}

private extension RailwayCommandResult {
  var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
  var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
}
