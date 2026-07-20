import Foundation

public struct FlyCommandResult: Equatable, Sendable {
  public let stdout: Data
  public let stderr: Data
  public let terminationStatus: Int32

  public init(stdout: Data, stderr: Data = Data(), terminationStatus: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.terminationStatus = terminationStatus
  }
}

public protocol FlyCommandRunning: Sendable {
  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> FlyCommandResult
}

public protocol FlyCLIClientProtocol: Sendable {
  func fetchSnapshot() async throws -> FlySnapshotResult
}

public struct SystemFlyCommandRunner: FlyCommandRunning {
  public init() {}

  public func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> FlyCommandResult {
    let coordinator = FlyRunningProcessCoordinator()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await Task.detached {
        try Self.runSync(
          executableURL: executableURL,
          arguments: arguments,
          environment: environment,
          currentDirectoryURL: currentDirectoryURL,
          coordinator: coordinator
        )
      }.value
    } onCancel: {
      coordinator.cancel()
    }
  }

  private static func runSync(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL,
    coordinator: FlyRunningProcessCoordinator
  ) throws -> FlyCommandResult {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: currentDirectoryURL, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: currentDirectoryURL.path)

    let nonce = UUID().uuidString
    let stdoutURL = currentDirectoryURL.appendingPathComponent("command-\(nonce)-stdout")
    let stderrURL = currentDirectoryURL.appendingPathComponent("command-\(nonce)-stderr")
    guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
      fileManager.createFile(atPath: stderrURL.path, contents: nil)
    else {
      throw FlyCLIError.commandFailed("Could not create secure temporary Fly command output files.")
    }
    defer {
      try? fileManager.removeItem(at: stdoutURL)
      try? fileManager.removeItem(at: stderrURL)
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stdoutURL.path)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stderrURL.path)

    let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
    let stderrHandle = try FileHandle(forWritingTo: stderrURL)
    defer {
      try? stdoutHandle.close()
      try? stderrHandle.close()
    }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = currentDirectoryURL
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle

    do {
      try process.run()
      if !coordinator.register(process) {
        process.terminate()
      }
      process.waitUntilExit()
      coordinator.clear(process)
    } catch {
      coordinator.clear(process)
      if coordinator.isCancelled { throw CancellationError() }
      throw error
    }

    if coordinator.isCancelled { throw CancellationError() }
    try stdoutHandle.close()
    try stderrHandle.close()
    let stdout = try Data(contentsOf: stdoutURL)
    let stderr = process.terminationStatus == 0 ? Data() : try Data(contentsOf: stderrURL)
    return FlyCommandResult(
      stdout: stdout,
      stderr: stderr,
      terminationStatus: process.terminationStatus
    )
  }
}

public actor FlyCLIClient: FlyCLIClientProtocol {
  public static let pinnedVersion = FlyRuntimeResolver.pinnedVersion
  public static let loginCommand = "flyctl auth login"
  public static let maximumConcurrentScopedCommands = 4

  private let runner: any FlyCommandRunning
  private let runtimeResolver: any FlyRuntimeResolving
  private let environment: [String: String]
  private let currentDirectoryURL: URL
  private let limiter: FlyCommandLimiter
  private var cachedExecutableURL: URL?

  public init(
    runner: any FlyCommandRunning = SystemFlyCommandRunner(),
    runtimeResolver: any FlyRuntimeResolving = FlyRuntimeResolver(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectoryURL: URL? = nil
  ) {
    self.runner = runner
    self.runtimeResolver = runtimeResolver
    var environment = environment
    for key in Self.removedEnvironmentKeys {
      environment.removeValue(forKey: key)
    }
    environment["FLY_SEND_METRICS"] = "0"
    environment["DO_NOT_TRACK"] = "1"
    environment["NO_COLOR"] = "1"
    self.environment = environment
    self.currentDirectoryURL = currentDirectoryURL ?? Self.makeWorkingDirectory()
    limiter = FlyCommandLimiter(limit: Self.maximumConcurrentScopedCommands)
  }

  public func fetchSnapshot() async throws -> FlySnapshotResult {
    let executableURL = try await validatedExecutableURL()

    let identityData = try await Self.runJSON(
      runner: runner,
      executableURL: executableURL,
      arguments: ["auth", "whoami", "--json"],
      environment: environment,
      currentDirectoryURL: currentDirectoryURL
    )
    do {
      _ = try JSONDecoder().decode(FlyIdentityResponse.self, from: identityData)
    } catch {
      throw FlyCLIError.malformedOutput("Could not parse Fly authentication evidence.")
    }

    let organizationsData = try await Self.runJSON(
      runner: runner,
      executableURL: executableURL,
      arguments: ["orgs", "list", "--json"],
      environment: environment,
      currentDirectoryURL: currentDirectoryURL
    )
    let organizationMap: [String: String]
    do {
      organizationMap = try JSONDecoder().decode([String: String].self, from: organizationsData)
    } catch {
      throw FlyCLIError.malformedOutput("Could not parse Fly organizations.")
    }
    let organizations = organizationMap.map { FlyOrganization(slug: $0.key, name: $0.value) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    let appsData = try await Self.runJSON(
      runner: runner,
      executableURL: executableURL,
      arguments: ["apps", "list", "--json"],
      environment: environment,
      currentDirectoryURL: currentDirectoryURL
    )
    let appRows: [FlyAppRow]
    do {
      appRows = try JSONDecoder().decode([FlyAppRow].self, from: appsData)
    } catch {
      throw FlyCLIError.malformedOutput("Could not parse Fly apps.")
    }
    let baselineApps = appRows.compactMap { $0.snapshot(organizationMap: organizationMap) }

    let runner = runner
    let environment = environment
    let currentDirectoryURL = currentDirectoryURL
    let limiter = limiter
    let outcomes = await withTaskGroup(of: FlyScopedCommandOutcome.self) { group in
      for app in baselineApps {
        group.addTask {
          await Self.fetchStatus(
            for: app, runner: runner, executableURL: executableURL,
            environment: environment, currentDirectoryURL: currentDirectoryURL, limiter: limiter
          )
        }
        group.addTask {
          await Self.fetchRelease(
            for: app, runner: runner, executableURL: executableURL,
            environment: environment, currentDirectoryURL: currentDirectoryURL, limiter: limiter
          )
        }
      }

      var values: [FlyScopedCommandOutcome] = []
      for await value in group { values.append(value) }
      return values
    }

    if Task.isCancelled || outcomes.contains(where: { $0.error == .cancelled }) {
      throw FlyCLIError.cancelled
    }

    var statusByKey: [String: FlyStatusResponse] = [:]
    var releaseByKey: [String: FlyRelease] = [:]
    var successfulStatusKeys: Set<String> = []
    var successfulReleaseKeys: Set<String> = []
    var failures: [FlyScopedFailure] = []
    for outcome in outcomes {
      if let status = outcome.status {
        statusByKey[outcome.app.identityKey] = status
        successfulStatusKeys.insert(outcome.app.identityKey)
      } else if outcome.scope == .status, let error = outcome.error {
        failures.append(Self.scopedFailure(app: outcome.app, scope: .status, error: error))
      }

      if outcome.scope == .release, outcome.error == nil {
        successfulReleaseKeys.insert(outcome.app.identityKey)
        if let release = outcome.release { releaseByKey[outcome.app.identityKey] = release }
      } else if outcome.scope == .release, let error = outcome.error {
        failures.append(Self.scopedFailure(app: outcome.app, scope: .release, error: error))
      }
    }

    let apps = baselineApps.map { baseline -> FlyApp in
      let statusApp = statusByKey[baseline.identityKey]?.merging(into: baseline) ?? baseline
      return FlyApp(
        id: statusApp.id, name: statusApp.name, rawStatus: statusApp.rawStatus,
        deployed: statusApp.deployed, organization: statusApp.organization,
        hostname: statusApp.hostname, appURLString: statusApp.appURLString,
        currentReleaseVersion: statusApp.currentReleaseVersion, machines: statusApp.machines,
        latestRelease: releaseByKey[baseline.identityKey]
      )
    }

    return FlySnapshotResult(
      organizations: organizations,
      apps: FlyStatusBuilder.sortedApps(apps),
      successfulStatusAppKeys: successfulStatusKeys,
      successfulReleaseAppKeys: successfulReleaseKeys,
      failures: failures.sorted { left, right in
        if left.appName != right.appName { return left.appName < right.appName }
        return left.scope.rawValue < right.scope.rawValue
      }
    )
  }

  private func validatedExecutableURL() async throws -> URL {
    if let cachedExecutableURL { return cachedExecutableURL }
    let executableURL = try runtimeResolver.resolveExecutableURL()
    let result: FlyCommandResult
    do {
      result = try await runner.run(
        executableURL: executableURL,
        arguments: ["version", "--json"],
        environment: environment,
        currentDirectoryURL: currentDirectoryURL
      )
    } catch is CancellationError {
      throw FlyCLIError.cancelled
    }
    guard result.terminationStatus == 0 else { throw Self.classifiedFailure(from: result) }
    let response: FlyVersionResponse
    do {
      response = try JSONDecoder().decode(FlyVersionResponse.self, from: result.stdout)
    } catch {
      throw FlyCLIError.malformedOutput("Could not parse the Fly runtime version.")
    }
    let supportedArchitectures: Set<String> = ["arm64", "x86_64"]
    guard response.name == "flyctl", response.version == Self.pinnedVersion,
      response.os == "darwin", supportedArchitectures.contains(response.architecture)
    else {
      let description = "\(response.name) \(response.version) \(response.os)/\(response.architecture)"
      throw FlyCLIError.incompatibleRuntime(currentVersion: String(description.prefix(120)))
    }
    cachedExecutableURL = executableURL
    return executableURL
  }

  private static func fetchStatus(
    for app: FlyApp,
    runner: any FlyCommandRunning,
    executableURL: URL,
    environment: [String: String],
    currentDirectoryURL: URL,
    limiter: FlyCommandLimiter
  ) async -> FlyScopedCommandOutcome {
    do {
      let data = try await limiter.withPermit {
        try await runJSON(
          runner: runner, executableURL: executableURL,
          arguments: ["status", "--app", app.name, "--json"],
          environment: environment, currentDirectoryURL: currentDirectoryURL
        )
      }
      let response = try JSONDecoder().decode(FlyStatusResponse.self, from: data)
      return .init(app: app, scope: .status, status: response)
    } catch let error as FlyCLIError {
      return .init(app: app, scope: .status, error: error)
    } catch is CancellationError {
      return .init(app: app, scope: .status, error: .cancelled)
    } catch {
      return .init(app: app, scope: .status, error: .malformedOutput("Could not parse Fly app status."))
    }
  }

  private static func fetchRelease(
    for app: FlyApp,
    runner: any FlyCommandRunning,
    executableURL: URL,
    environment: [String: String],
    currentDirectoryURL: URL,
    limiter: FlyCommandLimiter
  ) async -> FlyScopedCommandOutcome {
    do {
      let data = try await limiter.withPermit {
        try await runJSON(
          runner: runner, executableURL: executableURL,
          arguments: ["releases", "--app", app.name, "--json"],
          environment: environment, currentDirectoryURL: currentDirectoryURL
        )
      }
      let rows = try JSONDecoder().decode([FlyReleaseRow].self, from: data)
      let release = rows.compactMap(\.snapshot).sorted { $0.version > $1.version }.first
      return .init(app: app, scope: .release, release: release)
    } catch let error as FlyCLIError {
      return .init(app: app, scope: .release, error: error)
    } catch is CancellationError {
      return .init(app: app, scope: .release, error: .cancelled)
    } catch {
      return .init(app: app, scope: .release, error: .malformedOutput("Could not parse Fly releases."))
    }
  }

  private static func runJSON(
    runner: any FlyCommandRunning,
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> Data {
    do {
      try Task.checkCancellation()
      let result = try await runner.run(
        executableURL: executableURL,
        arguments: arguments,
        environment: environment,
        currentDirectoryURL: currentDirectoryURL
      )
      try Task.checkCancellation()
      guard result.terminationStatus == 0 else { throw classifiedFailure(from: result) }
      return result.stdout
    } catch is CancellationError {
      throw FlyCLIError.cancelled
    }
  }

  private static func scopedFailure(app: FlyApp, scope: FlyScopedFailure.Scope, error: FlyCLIError) -> FlyScopedFailure {
    FlyScopedFailure(
      appKey: app.identityKey,
      appName: app.name,
      scope: scope,
      message: error.localizedDescription,
      isRateLimited: error == .rateLimited
    )
  }

  private static func classifiedFailure(from result: FlyCommandResult) -> FlyCLIError {
    let rawMessage = [result.stderrString, result.stdoutString]
      .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    let normalized = rawMessage.lowercased()
    if normalized.contains("not authenticated")
      || normalized.contains("not logged in")
      || normalized.contains("unauthorized")
      || normalized.contains("authentication required")
      || normalized.contains("fly auth login")
      || normalized.contains("flyctl auth login")
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
    if normalized.contains("timed out")
      || normalized.contains("timeout")
      || normalized.contains("temporarily unavailable")
      || normalized.contains("connection reset")
      || normalized.contains("service unavailable")
      || normalized.contains("bad gateway")
      || normalized.contains("gateway timeout")
      || normalized.contains("http 502")
      || normalized.contains("http 503")
      || normalized.contains("http 504")
    {
      return .transientFailure
    }
    let message = sanitizedMessage(rawMessage)
    return .commandFailed(message.isEmpty
      ? "Fly CLI failed with exit code \(result.terminationStatus)."
      : message)
  }

  private static func sanitizedMessage(_ rawMessage: String) -> String {
    var message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacements = [
      (#"(?i)((?:FLY_ACCESS_TOKEN|FLY_API_TOKEN|FLY_METRICS_TOKEN)\s*[=:]\s*)\S+"#, "$1<redacted>"),
      (#"(?i)((?:authorization:\s*bearer|bearer|access[_ -]?token)\s*[=:]?\s*)\S+"#, "$1<redacted>"),
      (#"(?i)((?:[A-Z0-9_]*(?:TOKEN|SECRET|API_KEY|AUTH)[A-Z0-9_]*)\s*[=:]\s*)\S+"#, "$1<redacted>"),
      (#"(?i)([?&](?:access_token|api_token|token|api_key|key)=)[^&\s]+"#, "$1<redacted>"),
      (#"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]{10,})?"#, "<redacted>"),
      (#"(?i)\bFlyV1\s+[A-Za-z0-9_=.-]+"#, "<redacted>"),
      (#"\bfm2_[A-Za-z0-9_-]{12,}\b"#, "<redacted>")
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
      .appendingPathComponent("portdeck-fly-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  private static let removedEnvironmentKeys = [
    "FLY_ACCESS_TOKEN", "FLY_API_TOKEN", "FLY_METRICS_TOKEN", "FLY_ORG",
    "FLY_ORGANIZATION", "FLY_REGION", "FLY_APP", "FLY_API_BASE_URL",
    "FLY_FLAPS_BASE_URL", "FLY_METRICS_BASE_URL", "FLY_SYNTHETICS_BASE_URL",
    "FLY_REGISTRY_HOST", "FLY_JSON", "FLY_VERBOSE", "FLY_LOG_GQL_ERRORS"
  ]
}

public enum FlyCLIError: LocalizedError, Equatable, Sendable {
  case missingRuntime
  case incompatibleRuntime(currentVersion: String)
  case authenticationRequired
  case rateLimited
  case cancelled
  case transientFailure
  case commandFailed(String)
  case malformedOutput(String)

  public var errorDescription: String? {
    switch self {
    case .missingRuntime:
      return "PortDeck's managed Fly runtime is unavailable."
    case .incompatibleRuntime(let currentVersion):
      return "PortDeck found \(currentVersion), but this build requires flyctl \(FlyCLIClient.pinnedVersion) for Darwin."
    case .authenticationRequired:
      return "Fly authentication required. Run `\(FlyCLIClient.loginCommand)` in Terminal."
    case .rateLimited:
      return "Fly API rate limit reached. PortDeck will retry on the next scheduled refresh."
    case .cancelled:
      return "Fly refresh cancelled."
    case .transientFailure:
      return "Fly is temporarily unavailable. PortDeck will retry on the next scheduled refresh."
    case .commandFailed(let message), .malformedOutput(let message):
      return message
    }
  }
}

private final class FlyRunningProcessCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func register(_ process: Process) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { return false }
    self.process = process
    return true
  }

  func clear(_ process: Process) {
    lock.lock()
    defer { lock.unlock() }
    if self.process === process { self.process = nil }
  }

  func cancel() {
    let process: Process?
    lock.lock()
    cancelled = true
    process = self.process
    lock.unlock()
    if let process, process.isRunning { process.terminate() }
  }
}

private actor FlyCommandLimiter {
  private var availablePermits: Int
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    availablePermits = max(1, limit)
  }

  func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    await acquire()
    do {
      try Task.checkCancellation()
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
    await withCheckedContinuation { continuation in waiters.append(continuation) }
  }

  private func release() {
    if waiters.isEmpty { availablePermits += 1 }
    else { waiters.removeFirst().resume() }
  }
}

private struct FlyVersionResponse: Decodable, Sendable {
  let name: String
  let version: String
  let os: String
  let architecture: String

  enum CodingKeys: String, CodingKey {
    case name = "Name"
    case version = "Version"
    case os = "OS"
    case architecture = "Architecture"
  }
}

private struct FlyIdentityResponse: Decodable, Sendable {
  let email: String
}

private struct FlyOrganizationRow: Decodable, Sendable {
  let slug: String
  let name: String

  enum CodingKeys: String, CodingKey {
    case slug = "Slug"
    case name = "Name"
  }
}

private struct FlyAppRow: Decodable, Sendable {
  let id: String?
  let name: String?
  let status: String?
  let deployed: Bool?
  let hostname: String?
  let appURL: String?
  let organization: FlyOrganizationRow?

  enum CodingKeys: String, CodingKey {
    case id = "ID"
    case name = "Name"
    case status = "Status"
    case deployed = "Deployed"
    case hostname = "Hostname"
    case appURL = "AppURL"
    case organization = "Organization"
  }

  func snapshot(organizationMap: [String: String]) -> FlyApp? {
    guard let name, !name.isEmpty else { return nil }
    let slug = organization?.slug ?? "unknown"
    let organizationName = organization?.name ?? organizationMap[slug] ?? slug
    return FlyApp(
      id: id ?? "", name: name, rawStatus: status, deployed: deployed ?? false,
      organization: FlyOrganization(slug: slug, name: organizationName),
      hostname: hostname, appURLString: appURL
    )
  }
}

private struct FlyStatusResponse: Decodable, Sendable {
  let id: String?
  let name: String?
  let deployed: Bool?
  let status: String?
  let hostname: String?
  let version: Int?
  let appURL: String?
  let organization: FlyOrganizationRow?
  let machines: [FlyMachineRow]?

  enum CodingKeys: String, CodingKey {
    case id = "ID"
    case name = "Name"
    case deployed = "Deployed"
    case status = "Status"
    case hostname = "Hostname"
    case version = "Version"
    case appURL = "AppURL"
    case organization = "Organization"
    case machines = "Machines"
  }

  func merging(into baseline: FlyApp) -> FlyApp {
    let slug = organization?.slug ?? baseline.organization.slug
    let organization = FlyOrganization(slug: slug, name: self.organization?.name ?? baseline.organization.name)
    return FlyApp(
      id: id ?? baseline.id, name: name ?? baseline.name,
      rawStatus: status ?? baseline.rawStatus, deployed: deployed ?? baseline.deployed,
      organization: organization, hostname: hostname ?? baseline.hostname,
      appURLString: appURL ?? baseline.appURLString,
      currentReleaseVersion: (version ?? 0) > 0 ? version : nil,
      machines: (machines ?? []).compactMap(\.snapshot)
    )
  }
}

private struct FlyMachineRow: Decodable, Sendable {
  let id: String?
  let name: String?
  let state: String?
  let region: String?
  let hostStatus: String?
  let updatedAt: String?
  let checks: [FlyMachineCheckRow]?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case state
    case region
    case hostStatus = "host_status"
    case updatedAt = "updated_at"
    case checks
  }

  var snapshot: FlyMachine? {
    guard let id, !id.isEmpty else { return nil }
    return FlyMachine(
      id: id, name: name, rawState: state, region: region, rawHostStatus: hostStatus,
      updatedAt: FlyDateParser.parse(updatedAt), checks: (checks ?? []).compactMap(\.snapshot)
    )
  }
}

private struct FlyMachineCheckRow: Decodable, Sendable {
  let name: String?
  let status: String?
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case name
    case status
    case updatedAt = "updated_at"
  }

  var snapshot: FlyMachineCheck? {
    guard let name, !name.isEmpty else { return nil }
    return FlyMachineCheck(name: name, rawStatus: status, updatedAt: FlyDateParser.parse(updatedAt))
  }
}

private struct FlyReleaseRow: Decodable, Sendable {
  let id: String?
  let version: Int?
  let status: String?
  let description: String?
  let createdAt: String?

  enum CodingKeys: String, CodingKey {
    case id = "ID"
    case version = "Version"
    case status = "Status"
    case description = "Description"
    case createdAt = "CreatedAt"
  }

  var snapshot: FlyRelease? {
    guard let id, !id.isEmpty, let version, version > 0 else { return nil }
    return FlyRelease(
      id: id, version: version, rawStatus: status, description: description,
      createdAt: FlyDateParser.parse(createdAt)
    )
  }
}

private struct FlyScopedCommandOutcome: Sendable {
  let app: FlyApp
  let scope: FlyScopedFailure.Scope
  let status: FlyStatusResponse?
  let release: FlyRelease?
  let error: FlyCLIError?

  init(
    app: FlyApp,
    scope: FlyScopedFailure.Scope,
    status: FlyStatusResponse? = nil,
    release: FlyRelease? = nil,
    error: FlyCLIError? = nil
  ) {
    self.app = app
    self.scope = scope
    self.status = status
    self.release = release
    self.error = error
  }
}

private enum FlyDateParser {
  static func parse(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}

private extension FlyCommandResult {
  var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
  var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}
