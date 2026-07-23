import Foundation

public struct NetlifyCommandResult: Equatable, Sendable {
  public let stdout: Data
  public let stderr: Data
  public let terminationStatus: Int32

  public init(stdout: Data, stderr: Data = Data(), terminationStatus: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.terminationStatus = terminationStatus
  }
}

public protocol NetlifyCommandRunning: Sendable {
  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> NetlifyCommandResult
}

public protocol NetlifyCLIClientProtocol: Sendable {
  func fetchSnapshot() async throws -> NetlifySnapshotResult
}

public enum NetlifyCommandAllowlist {
  public static func validate(_ arguments: [String]) throws {
    if arguments == ["--version"] || arguments == ["sites:list", "--json"] {
      return
    }

    guard arguments.count == 4,
      arguments[0] == "api",
      arguments[1] == "listSiteDeploys",
      arguments[2] == "--data",
      let data = arguments[3].data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(object.keys) == ["site_id", "production", "per_page"],
      let siteID = object["site_id"] as? String,
      !siteID.isEmpty,
      siteID.count <= 160,
      siteID.rangeOfCharacter(from: .controlCharacters) == nil,
      object["production"] as? Bool == true,
      (object["per_page"] as? NSNumber)?.intValue == 1
    else {
      throw NetlifyCLIError.unsafeCommand
    }
  }
}

public struct SystemNetlifyCommandRunner: NetlifyCommandRunning {
  public init() {}

  public func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> NetlifyCommandResult {
    try NetlifyCommandAllowlist.validate(arguments)
    try Self.ensureNeutralDirectory(currentDirectoryURL)
    let coordinator = NetlifyRunningProcessCoordinator()
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
    coordinator: NetlifyRunningProcessCoordinator
  ) throws -> NetlifyCommandResult {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: currentDirectoryURL, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: currentDirectoryURL.path)

    let nonce = UUID().uuidString
    let stdoutURL = currentDirectoryURL.appendingPathComponent("command-\(nonce)-stdout")
    let stderrURL = currentDirectoryURL.appendingPathComponent("command-\(nonce)-stderr")
    guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
      fileManager.createFile(atPath: stderrURL.path, contents: nil)
    else {
      throw NetlifyCLIError.commandFailed("Could not create secure temporary Netlify command output files.")
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
    process.environment = ProviderCLIExecutionEnvironment.make(
      executableURL: executableURL,
      base: environment
    )
    process.currentDirectoryURL = currentDirectoryURL
    process.standardOutput = stdoutHandle
    process.standardError = stderrHandle

    do {
      try process.run()
      if !coordinator.register(process) { process.terminate() }
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
    return NetlifyCommandResult(
      stdout: try Data(contentsOf: stdoutURL),
      stderr: process.terminationStatus == 0 ? Data() : try Data(contentsOf: stderrURL),
      terminationStatus: process.terminationStatus
    )
  }

  private static func ensureNeutralDirectory(_ directory: URL) throws {
    let fileManager = FileManager.default
    var candidate = directory.standardizedFileURL
    for _ in 0..<20 {
      let stateURL = candidate.appendingPathComponent(".netlify/state.json")
      if fileManager.fileExists(atPath: stateURL.path) {
        throw NetlifyCLIError.unsafeWorkingDirectory
      }
      let parent = candidate.deletingLastPathComponent()
      if parent.path == candidate.path { break }
      candidate = parent
    }
  }
}

public actor NetlifyCLIClient: NetlifyCLIClientProtocol {
  public static let supportedVersionRange = NetlifyRuntimeResolver.supportedVersionRange
  public static let minimumNodeVersion = NetlifyRuntimeResolver.minimumNodeVersion
  public static let loginCommand = "netlify login"
  public static let maximumConcurrentScopedCommands = 4
  public static let maximumAuthoritativeSiteCount = 999

  public static let removedEnvironmentKeys: Set<String> = [
    "NETLIFY_AUTH_TOKEN", "NETLIFY_SITE_ID", "NETLIFY_ACCOUNT_ID", "NETLIFY_ACCOUNT_SLUG",
    "NETLIFY_API_URL", "NETLIFY_WEB_UI", "NETLIFY_PROXY_CERTIFICATE_FILENAME",
    "NETLIFY_CLI_EXECA_PATH", "NETLIFY_TEST_TRACK_URL", "NETLIFY_TEST_IDENTIFY_URL",
    "NETLIFY_TEST_ERROR_REPORT_URL", "NETLIFY_TEST_TELEMETRY_WAIT", "NETLIFY_BUILD_DEBUG",
    "NETLIFY_DEPLOY_SOURCE", "CONTEXT", "DEBUG", "XDG_CONFIG_HOME", "HTTP_PROXY", "HTTPS_PROXY",
    "NO_UPDATE_NOTIFIER", "NO_COLOR", "FORCE_COLOR", "CI", "CI_NAME", "GITHUB_ACTIONS",
    "GITLAB_CI", "TRAVIS", "CIRCLECI", "BUILDKITE", "DRONE"
  ]

  private let runner: any NetlifyCommandRunning
  private let runtimeResolver: any NetlifyRuntimeResolving
  private let environment: [String: String]
  private let currentDirectoryURL: URL
  private let limiter: NetlifyCommandLimiter
  private var cachedRuntime: (url: URL, evidence: NetlifyRuntimeEvidence)?

  public init(
    runner: any NetlifyCommandRunning = SystemNetlifyCommandRunner(),
    runtimeResolver: any NetlifyRuntimeResolving = NetlifyRuntimeResolver(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectoryURL: URL? = nil,
    maximumConcurrentScopedCommands: Int = NetlifyCLIClient.maximumConcurrentScopedCommands
  ) {
    self.runner = runner
    self.runtimeResolver = runtimeResolver
    var environment = environment
    for key in Self.removedEnvironmentKeys { environment.removeValue(forKey: key) }
    environment["CI"] = "1"
    environment["NO_UPDATE_NOTIFIER"] = "1"
    environment["NO_COLOR"] = "1"
    environment["FORCE_COLOR"] = "0"
    self.environment = environment
    self.currentDirectoryURL = currentDirectoryURL ?? Self.makeWorkingDirectory()
    limiter = NetlifyCommandLimiter(limit: maximumConcurrentScopedCommands)
  }

  public func runtimeEvidence() async throws -> NetlifyRuntimeEvidence {
    try await validatedRuntime().evidence
  }

  public func fetchSnapshot() async throws -> NetlifySnapshotResult {
    let executableURL = try await validatedRuntime().url
    let sitesData = try await Self.runJSON(
      runner: runner,
      executableURL: executableURL,
      arguments: ["sites:list", "--json"],
      environment: environment,
      currentDirectoryURL: currentDirectoryURL
    )

    let rows: [NetlifySiteRow]
    do {
      rows = try netlifyDecoder().decode([NetlifySiteRow].self, from: sitesData)
    } catch {
      throw NetlifyCLIError.malformedOutput("Could not parse the account-wide Netlify site list.")
    }
    guard rows.count <= Self.maximumAuthoritativeSiteCount else {
      throw NetlifyCLIError.incompletePagination
    }
    let baselineSites = rows.compactMap(\.snapshot)

    let runner = runner
    let environment = environment
    let currentDirectoryURL = currentDirectoryURL
    let limiter = limiter
    let outcomes = await withTaskGroup(of: NetlifyDeploymentOutcome.self) { group in
      for site in baselineSites {
        group.addTask {
          await Self.fetchLatestProductionDeployment(
            for: site,
            runner: runner,
            executableURL: executableURL,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            limiter: limiter
          )
        }
      }

      var values: [NetlifyDeploymentOutcome] = []
      for await value in group { values.append(value) }
      return values
    }

    if Task.isCancelled || outcomes.contains(where: { $0.error == .cancelled }) {
      throw NetlifyCLIError.cancelled
    }

    var deploymentBySiteID: [String: NetlifyDeployment] = [:]
    var successfulSiteIDs: Set<String> = []
    var failures: [NetlifyScopedFailure] = []
    for outcome in outcomes {
      if outcome.error == nil {
        successfulSiteIDs.insert(outcome.site.id)
        if let deployment = outcome.deployment { deploymentBySiteID[outcome.site.id] = deployment }
      } else if let error = outcome.error {
        failures.append(NetlifyScopedFailure(
          siteID: outcome.site.id,
          siteName: outcome.site.name,
          message: error.localizedDescription,
          isRateLimited: error == .rateLimited
        ))
      }
    }

    let sites = baselineSites.map { site in
      NetlifySite(
        id: site.id,
        name: site.name,
        account: site.account,
        productionURLString: site.productionURLString,
        dashboardURLString: site.dashboardURLString,
        latestDeployment: deploymentBySiteID[site.id],
        hasDeploymentFailure: !successfulSiteIDs.contains(site.id)
      )
    }

    return NetlifySnapshotResult(
      sites: NetlifyStatusBuilder.sortedSites(sites),
      successfulDeploymentSiteIDs: successfulSiteIDs,
      failures: failures.sorted { $0.siteName.localizedCaseInsensitiveCompare($1.siteName) == .orderedAscending }
    )
  }

  private func validatedRuntime() async throws -> (url: URL, evidence: NetlifyRuntimeEvidence) {
    if let cachedRuntime { return cachedRuntime }
    let executableURL = try runtimeResolver.resolveExecutableURL()
    let result = try await Self.runCommand(
      runner: runner,
      executableURL: executableURL,
      arguments: ["--version"],
      environment: environment,
      currentDirectoryURL: currentDirectoryURL
    )
    guard result.terminationStatus == 0 else { throw Self.classifiedFailure(from: result) }
    let rawVersion = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    let evidence = try Self.parseRuntimeEvidence(rawVersion)
    cachedRuntime = (executableURL, evidence)
    return (executableURL, evidence)
  }

  public static func parseRuntimeEvidence(_ rawVersion: String) throws -> NetlifyRuntimeEvidence {
    let pattern = #"^netlify-cli/([^ ]+) (darwin)-(arm64|x64) node-v([0-9]+\.[0-9]+\.[0-9]+)$"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(in: rawVersion, range: NSRange(rawVersion.startIndex..., in: rawVersion)),
      match.numberOfRanges == 5,
      let cliRange = Range(match.range(at: 1), in: rawVersion),
      let osRange = Range(match.range(at: 2), in: rawVersion),
      let archRange = Range(match.range(at: 3), in: rawVersion),
      let nodeRange = Range(match.range(at: 4), in: rawVersion)
    else {
      throw NetlifyCLIError.unsupportedCLI(currentVersion: String(rawVersion.prefix(120)))
    }
    let evidence = NetlifyRuntimeEvidence(
      cliVersion: String(rawVersion[cliRange]),
      operatingSystem: String(rawVersion[osRange]),
      architecture: String(rawVersion[archRange]),
      nodeVersion: String(rawVersion[nodeRange])
    )
    guard let version = ProviderCLIVersion(string: evidence.cliVersion),
      Self.supportedVersionRange.contains(version),
      isVersion(evidence.nodeVersion, atLeast: Self.minimumNodeVersion)
    else {
      throw NetlifyCLIError.unsupportedCLI(currentVersion: String(rawVersion.prefix(120)))
    }
    return evidence
  }

  private static func fetchLatestProductionDeployment(
    for site: NetlifySite,
    runner: any NetlifyCommandRunning,
    executableURL: URL,
    environment: [String: String],
    currentDirectoryURL: URL,
    limiter: NetlifyCommandLimiter
  ) async -> NetlifyDeploymentOutcome {
    do {
      let payload = try deploymentPayload(siteID: site.id)
      let data = try await limiter.withPermit {
        try await runJSON(
          runner: runner,
          executableURL: executableURL,
          arguments: ["api", "listSiteDeploys", "--data", payload],
          environment: environment,
          currentDirectoryURL: currentDirectoryURL
        )
      }
      let rows = try netlifyDecoder().decode([NetlifyDeploymentRow].self, from: data)
      if let row = rows.first {
        guard row.siteID == site.id else {
          throw NetlifyCLIError.malformedOutput("Netlify returned a deployment for a different site.")
        }
        guard let deployment = row.snapshot(siteName: site.name) else {
          throw NetlifyCLIError.malformedOutput("Netlify returned an unusable deployment record.")
        }
        return NetlifyDeploymentOutcome(site: site, deployment: deployment)
      }
      return NetlifyDeploymentOutcome(site: site)
    } catch let error as NetlifyCLIError {
      return NetlifyDeploymentOutcome(site: site, error: error)
    } catch is CancellationError {
      return NetlifyDeploymentOutcome(site: site, error: .cancelled)
    } catch {
      return NetlifyDeploymentOutcome(
        site: site,
        error: .malformedOutput("Could not parse the latest Netlify production deployment.")
      )
    }
  }

  public static func deploymentPayload(siteID: String) throws -> String {
    let object: [String: Any] = ["site_id": siteID, "production": true, "per_page": 1]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard let payload = String(data: data, encoding: .utf8) else { throw NetlifyCLIError.unsafeCommand }
    try NetlifyCommandAllowlist.validate(["api", "listSiteDeploys", "--data", payload])
    return payload
  }

  private static func runJSON(
    runner: any NetlifyCommandRunning,
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> Data {
    let result = try await runCommand(
      runner: runner,
      executableURL: executableURL,
      arguments: arguments,
      environment: environment,
      currentDirectoryURL: currentDirectoryURL
    )
    guard result.terminationStatus == 0 else { throw classifiedFailure(from: result) }
    return result.stdout
  }

  private static func runCommand(
    runner: any NetlifyCommandRunning,
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> NetlifyCommandResult {
    try NetlifyCommandAllowlist.validate(arguments)
    do {
      try Task.checkCancellation()
      let result = try await runner.run(
        executableURL: executableURL,
        arguments: arguments,
        environment: environment,
        currentDirectoryURL: currentDirectoryURL
      )
      try Task.checkCancellation()
      return result
    } catch is CancellationError {
      throw NetlifyCLIError.cancelled
    }
  }

  private static func classifiedFailure(from result: NetlifyCommandResult) -> NetlifyCLIError {
    let rawMessage = [result.stderrString, result.stdoutString]
      .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    let normalized = rawMessage.lowercased()
    if normalized.contains("authentication required") || normalized.contains("not logged in")
      || normalized.contains("unauthorized") || normalized.contains("status 401")
      || normalized.contains("netlify login")
    {
      return .authenticationRequired
    }
    if normalized.contains("rate limit") || normalized.contains("too many requests")
      || normalized.contains("status 429") || normalized.contains("http 429")
    {
      return .rateLimited
    }
    if normalized.contains("timed out") || normalized.contains("timeout")
      || normalized.contains("econnreset") || normalized.contains("connection reset")
      || normalized.contains("temporarily unavailable") || normalized.contains("service unavailable")
      || normalized.contains("bad gateway") || normalized.contains("gateway timeout")
      || normalized.contains("status 502") || normalized.contains("status 503")
      || normalized.contains("status 504")
    {
      return .transientFailure
    }
    let message = sanitizedMessage(rawMessage)
    return .commandFailed(message.isEmpty ? "Netlify CLI failed with exit code \(result.terminationStatus)." : message)
  }

  private static func sanitizedMessage(_ rawMessage: String) -> String {
    var message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacements = [
      (#"(?i)(NETLIFY_AUTH_TOKEN\s*[=:]\s*)\S+"#, "$1<redacted>"),
      (#"(?i)((?:authorization:\s*bearer|bearer|access[_ -]?token|auth[_ -]?token|token)\s*[=:]?\s*)\S+"#, "$1<redacted>"),
      (#"nfp_[A-Za-z0-9_-]{16,}"#, "<redacted>"),
      (#"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]{10,})?"#, "<redacted>")
    ]
    for (pattern, replacement) in replacements {
      guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
      message = expression.stringByReplacingMatches(
        in: message,
        range: NSRange(message.startIndex..., in: message),
        withTemplate: replacement
      )
    }
    return String(message.prefix(500))
  }

  private static func makeWorkingDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("portdeck-netlify-\(UUID().uuidString)")
  }

  private static func semanticVersion(_ value: String) -> [Int] {
    value.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
  }

  private static func isVersion(_ value: String, atLeast minimum: String) -> Bool {
    let current = semanticVersion(value)
    let required = semanticVersion(minimum)
    for index in 0..<max(current.count, required.count) {
      let currentPart = index < current.count ? current[index] : 0
      let requiredPart = index < required.count ? required[index] : 0
      if currentPart != requiredPart { return currentPart > requiredPart }
    }
    return true
  }
}

public enum NetlifyCLIError: LocalizedError, Equatable, Sendable {
  case missingCLI
  case unsupportedCLI(currentVersion: String)
  case authenticationRequired
  case rateLimited
  case malformedOutput(String)
  case incompletePagination
  case transientFailure
  case commandFailed(String)
  case unsafeCommand
  case unsafeWorkingDirectory
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .missingCLI:
      return "Netlify CLI is not installed."
    case .unsupportedCLI(let currentVersion):
      return "PortDeck found \(currentVersion), but supports netlify-cli \(NetlifyCLIClient.supportedVersionRange.displayName) on Node \(NetlifyCLIClient.minimumNodeVersion) or newer."
    case .authenticationRequired:
      return "Netlify authentication required. Run `\(NetlifyCLIClient.loginCommand)` in Terminal."
    case .rateLimited:
      return "Netlify API rate limit reached. PortDeck will retry on the next scheduled refresh."
    case .malformedOutput(let message): return message
    case .incompletePagination:
      return "Netlify returned 1,000 sites, which is the CLI pagination cap. PortDeck kept the prior snapshot rather than treating an incomplete list as authoritative."
    case .transientFailure:
      return "Netlify is temporarily unavailable. PortDeck will retry on the next scheduled refresh."
    case .commandFailed(let message): return message
    case .unsafeCommand:
      return "PortDeck blocked a Netlify command outside the read-only allowlist."
    case .unsafeWorkingDirectory:
      return "PortDeck refused to run Netlify from a directory with linked-site state."
    case .cancelled: return "Netlify refresh canceled."
    }
  }
}

private struct NetlifySiteRow: Decodable {
  let id: String?
  let name: String?
  let url: String?
  let sslURL: String?
  let adminURL: String?
  let accountID: String?
  let accountName: String?
  let accountSlug: String?

  enum CodingKeys: String, CodingKey {
    case id, name, url
    case sslURL = "ssl_url"
    case adminURL = "admin_url"
    case accountID = "account_id"
    case accountName = "account_name"
    case accountSlug = "account_slug"
  }

  var snapshot: NetlifySite? {
    guard let id = bounded(id, limit: 160), let name = bounded(name, limit: 160) else { return nil }
    let accountName = bounded(accountName, limit: 160)
      ?? bounded(accountSlug, limit: 160)
      ?? bounded(accountID, limit: 160)
      ?? "Netlify account"
    let accountID = bounded(accountID, limit: 160)
      ?? bounded(accountSlug, limit: 160)
      ?? "account:\(accountName.lowercased())"
    let account = NetlifyAccount(
      id: accountID,
      name: accountName,
      slug: bounded(accountSlug, limit: 160)
    )
    let dashboard = NetlifySafeLink.dashboardURL(adminURL)
      ?? NetlifySafeLink.siteDashboardURL(siteName: name)
    return NetlifySite(
      id: id,
      name: name,
      account: account,
      productionURLString: NetlifySafeLink.publicURL(sslURL)?.absoluteString
        ?? NetlifySafeLink.publicURL(url)?.absoluteString,
      dashboardURLString: dashboard?.absoluteString
    )
  }
}

private struct NetlifyDeploymentRow: Decodable {
  let id: String?
  let siteID: String?
  let state: String?
  let sslURL: String?
  let deploySSLURL: String?
  let adminURL: String?
  let errorMessage: String?
  let branch: String?
  let commitReference: String?
  let createdAt: Date?
  let updatedAt: Date?
  let publishedAt: Date?
  let title: String?
  let context: String?

  enum CodingKeys: String, CodingKey {
    case id, state, branch, title, context
    case siteID = "site_id"
    case sslURL = "ssl_url"
    case deploySSLURL = "deploy_ssl_url"
    case adminURL = "admin_url"
    case errorMessage = "error_message"
    case commitReference = "commit_ref"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case publishedAt = "published_at"
  }

  func snapshot(siteName: String) -> NetlifyDeployment? {
    guard let id = bounded(id, limit: 160),
      let siteID = bounded(siteID, limit: 160),
      let state = bounded(state, limit: 80)
    else {
      return nil
    }
    let dashboard = NetlifySafeLink.dashboardURL(adminURL)
      ?? NetlifySafeLink.deploymentDashboardURL(siteName: siteName, deploymentID: id)
    return NetlifyDeployment(
      id: id,
      siteID: siteID,
      rawState: state,
      context: context,
      createdAt: createdAt,
      updatedAt: updatedAt,
      publishedAt: publishedAt,
      branch: branch,
      commitReference: commitReference,
      title: title,
      errorSummary: errorMessage,
      deployURLString: NetlifySafeLink.publicURL(deploySSLURL)?.absoluteString
        ?? NetlifySafeLink.publicURL(sslURL)?.absoluteString,
      dashboardURLString: dashboard?.absoluteString
    )
  }
}

private struct NetlifyDeploymentOutcome: Sendable {
  let site: NetlifySite
  let deployment: NetlifyDeployment?
  let error: NetlifyCLIError?

  init(site: NetlifySite, deployment: NetlifyDeployment? = nil, error: NetlifyCLIError? = nil) {
    self.site = site
    self.deployment = deployment
    self.error = error
  }
}

private actor NetlifyCommandLimiter {
  private let limit: Int
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) { self.limit = max(1, limit) }

  func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    await acquire()
    defer { release() }
    try Task.checkCancellation()
    return try await operation()
  }

  private func acquire() async {
    if active < limit {
      active += 1
      return
    }
    await withCheckedContinuation { continuation in waiters.append(continuation) }
    active += 1
  }

  private func release() {
    active -= 1
    if !waiters.isEmpty { waiters.removeFirst().resume() }
  }
}

private final class NetlifyRunningProcessCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private(set) var isCancelled = false

  func register(_ process: Process) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isCancelled else { return false }
    self.process = process
    return true
  }

  func clear(_ process: Process) {
    lock.lock()
    defer { lock.unlock() }
    if self.process === process { self.process = nil }
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    let process = process
    lock.unlock()
    if process?.isRunning == true { process?.terminate() }
  }
}

private func netlifyDecoder() -> JSONDecoder {
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .custom { decoder in
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    if let date = standard.date(from: value) { return date }
    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid Netlify timestamp")
  }
  return decoder
}

private func bounded(_ value: String?, limit: Int) -> String? {
  guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
    return nil
  }
  return String(trimmed.prefix(limit))
}

private extension NetlifyCommandResult {
  var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
  var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
}
