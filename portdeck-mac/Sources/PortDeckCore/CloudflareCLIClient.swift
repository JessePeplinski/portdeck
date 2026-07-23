import Foundation

public struct CloudflareCommandResult: Equatable, Sendable {
  public let stdout: Data
  public let stderr: Data
  public let terminationStatus: Int32

  public init(stdout: Data, stderr: Data = Data(), terminationStatus: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.terminationStatus = terminationStatus
  }
}

public protocol CloudflareCommandRunning: Sendable {
  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> CloudflareCommandResult
}

public protocol CloudflareCLIClientProtocol: Sendable {
  func fetchAccounts() async throws -> [CloudflareAccount]
  func fetchPages(accounts: [CloudflareAccount]) async throws -> CloudflarePagesFetchResult
  func fetchWorkers(
    candidates: [CloudflareWorkerCandidate],
    accounts: [CloudflareAccount]
  ) async throws -> CloudflareWorkersFetchResult
}

public struct SystemCloudflareCommandRunner: CloudflareCommandRunning {
  public init() {}

  public func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> CloudflareCommandResult {
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
  ) throws -> CloudflareCommandResult {
    let fileManager = FileManager.default
    let nonce = UUID().uuidString
    let stdoutURL = fileManager.temporaryDirectory.appendingPathComponent("portdeck-cloudflare-\(nonce)-stdout")
    let stderrURL = fileManager.temporaryDirectory.appendingPathComponent("portdeck-cloudflare-\(nonce)-stderr")

    guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
      fileManager.createFile(atPath: stderrURL.path, contents: nil)
    else {
      throw CloudflareCLIError.commandFailed("Could not create secure temporary command output files.")
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
    return CloudflareCommandResult(
      stdout: try Data(contentsOf: stdoutURL),
      stderr: try Data(contentsOf: stderrURL),
      terminationStatus: process.terminationStatus
    )
  }
}

public actor CloudflareCLIClient: CloudflareCLIClientProtocol {
  public static let supportedVersionRange = CloudflareRuntimeResolver.supportedVersionRange
  public static let loginCommand = "wrangler login"

  private let runner: any CloudflareCommandRunning
  private let runtimeResolver: any CloudflareRuntimeResolving
  private let environment: [String: String]
  private let currentDirectoryURL: URL
  private var cachedExecutableURL: URL?

  public init(
    runner: any CloudflareCommandRunning = SystemCloudflareCommandRunner(),
    runtimeResolver: any CloudflareRuntimeResolving = CloudflareRuntimeResolver(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectoryURL: URL? = nil
  ) {
    self.runner = runner
    self.runtimeResolver = runtimeResolver
    var environment = environment
    environment["WRANGLER_SEND_METRICS"] = "false"
    environment["WRANGLER_SEND_ERROR_REPORTS"] = "false"
    environment["WRANGLER_LOG_SANITIZE"] = "true"
    environment.removeValue(forKey: "WRANGLER_LOG")
    environment.removeValue(forKey: "WRANGLER_LOG_PATH")
    environment.removeValue(forKey: "CLOUDFLARE_ACCOUNT_ID")
    self.environment = environment
    self.currentDirectoryURL = currentDirectoryURL ?? Self.makeWorkingDirectory()
  }

  public func fetchAccounts() async throws -> [CloudflareAccount] {
    let data = try await runJSON(arguments: ["whoami", "--json"], accountID: nil)
    do {
      let response = try JSONDecoder().decode(WhoAmIResponse.self, from: data)
      guard response.loggedIn else { throw CloudflareCLIError.authenticationRequired }
      return response.accounts
    } catch let error as CloudflareCLIError {
      throw error
    } catch {
      throw CloudflareCLIError.invalidResponse("Could not parse Wrangler account information: \(error.localizedDescription)")
    }
  }

  public func fetchPages(accounts: [CloudflareAccount]) async throws -> CloudflarePagesFetchResult {
    var projects: [CloudflarePagesProject] = []
    var successfulAccountIDs: Set<String> = []
    var failures: [CloudflareScopedFailure] = []

    for account in accounts {
      do {
        let data = try await runJSON(arguments: ["pages", "project", "list", "--json"], accountID: account.id)
        let rows = try JSONDecoder().decode([CloudflarePagesProjectRow].self, from: data)
        successfulAccountIDs.insert(account.id)

        for row in rows {
          let projectID = "\(account.id)|pages|\(row.name)"
          do {
            let deploymentData = try await runJSON(
              arguments: [
                "pages", "deployment", "list",
                "--project-name", row.name,
                "--environment", "production",
                "--json"
              ],
              accountID: account.id
            )
            let deployments = try JSONDecoder().decode([CloudflarePagesDeployment].self, from: deploymentData)
            projects.append(makePagesProject(account: account, row: row, deployment: deployments.first))
          } catch {
            projects.append(makePagesProject(account: account, row: row, deployment: nil))
            failures.append(scopedFailure(id: projectID, error: error))
          }
        }
      } catch {
        failures.append(scopedFailure(id: account.id, error: error))
      }
    }

    return CloudflarePagesFetchResult(
      projects: CloudflareStatusBuilder.sortedPages(projects),
      successfulAccountIDs: successfulAccountIDs,
      failures: failures
    )
  }

  public func fetchWorkers(
    candidates: [CloudflareWorkerCandidate],
    accounts: [CloudflareAccount]
  ) async throws -> CloudflareWorkersFetchResult {
    let candidates = resolvedCandidates(candidates, accounts: accounts)
    var resources: [CloudflareWorkerResource] = []
    var successfulCandidateIDs: Set<String> = []
    var failures: [CloudflareScopedFailure] = []

    for candidate in candidates {
      guard let accountID = candidate.accountID else {
        resources.append(CloudflareWorkerResource(account: nil, candidate: candidate, deployment: nil))
        failures.append(CloudflareScopedFailure(
          scopeID: candidate.id,
          message: "Multiple Cloudflare accounts are available. Add a top-level account_id to this Worker's Wrangler configuration to select one.",
          isRateLimited: false
        ))
        continue
      }

      guard let account = accounts.first(where: { $0.id == accountID }) else {
        resources.append(CloudflareWorkerResource(account: nil, candidate: candidate, deployment: nil))
        failures.append(CloudflareScopedFailure(
          scopeID: candidate.id,
          message: "The Worker's account_id does not match an authenticated Wrangler account.",
          isRateLimited: false
        ))
        continue
      }

      do {
        let listData = try await runJSON(
          arguments: ["deployments", "list", "--name", candidate.name, "--json"],
          accountID: account.id
        )
        _ = try decodeWorkerDeployments(listData)
        let statusData = try await runJSON(
          arguments: ["deployments", "status", "--name", candidate.name, "--json"],
          accountID: account.id
        )
        let deployment = try decodeWorkerDeployment(statusData)
        resources.append(CloudflareWorkerResource(account: account, candidate: candidate, deployment: deployment))
        successfulCandidateIDs.insert(candidate.id)
      } catch {
        resources.append(CloudflareWorkerResource(account: account, candidate: candidate, deployment: nil))
        failures.append(scopedFailure(id: candidate.id, error: error))
      }
    }

    return CloudflareWorkersFetchResult(
      resources: CloudflareStatusBuilder.sortedWorkers(resources),
      currentCandidateIDs: Set(candidates.map(\.id)),
      successfulCandidateIDs: successfulCandidateIDs,
      failures: failures
    )
  }

  private func runJSON(arguments: [String], accountID: String?) async throws -> Data {
    let executableURL = try await validatedExecutableURL()
    var commandEnvironment = environment
    if let accountID { commandEnvironment["CLOUDFLARE_ACCOUNT_ID"] = accountID }
    else { commandEnvironment.removeValue(forKey: "CLOUDFLARE_ACCOUNT_ID") }

    let result = try await runner.run(
      executableURL: executableURL,
      arguments: arguments,
      environment: commandEnvironment,
      currentDirectoryURL: currentDirectoryURL
    )
    guard result.terminationStatus == 0 else { throw classifiedFailure(from: result) }
    return result.stdout
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
    guard result.terminationStatus == 0 else { throw classifiedFailure(from: result) }
    let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty else {
      throw CloudflareCLIError.invalidResponse("Could not read the installed Wrangler version.")
    }
    guard let version = ProviderCLIVersion.first(in: output) else {
      throw CloudflareCLIError.unsupportedCLI(currentVersion: String(output.prefix(80)))
    }
    guard Self.supportedVersionRange.contains(version) else {
      throw CloudflareCLIError.unsupportedCLI(currentVersion: String(output.prefix(80)))
    }
    cachedExecutableURL = executableURL
    return executableURL
  }

  private func makePagesProject(
    account: CloudflareAccount,
    row: CloudflarePagesProjectRow,
    deployment: CloudflarePagesDeployment?
  ) -> CloudflarePagesProject {
    CloudflarePagesProject(
      account: account,
      name: row.name,
      domains: row.domains,
      usesGitProvider: row.usesGitProvider,
      lastModified: row.lastModified,
      deployment: deployment
    )
  }

  private func resolvedCandidates(
    _ candidates: [CloudflareWorkerCandidate],
    accounts: [CloudflareAccount]
  ) -> [CloudflareWorkerCandidate] {
    var resolved: [String: CloudflareWorkerCandidate] = [:]
    for candidate in candidates {
      let accountID = candidate.accountID ?? (accounts.count == 1 ? accounts[0].id : nil)
      let candidate = CloudflareWorkerCandidate(
        name: candidate.name,
        accountID: accountID,
        associatedProjectNames: candidate.associatedProjectNames,
        configurationPath: candidate.configurationPath
      )
      if let existing = resolved[candidate.id] {
        resolved[candidate.id] = CloudflareWorkerCandidate(
          name: candidate.name,
          accountID: candidate.accountID,
          associatedProjectNames: Array(Set(existing.associatedProjectNames + candidate.associatedProjectNames)),
          configurationPath: existing.configurationPath
        )
      } else {
        resolved[candidate.id] = candidate
      }
    }
    return resolved.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private func decodeWorkerDeployments(_ data: Data) throws -> [CloudflareWorkerDeployment] {
    do { return try workerJSONDecoder().decode([CloudflareWorkerDeployment].self, from: data) }
    catch { throw CloudflareCLIError.invalidResponse("Could not parse Worker deployment history: \(error.localizedDescription)") }
  }

  private func decodeWorkerDeployment(_ data: Data) throws -> CloudflareWorkerDeployment {
    do { return try workerJSONDecoder().decode(CloudflareWorkerDeployment.self, from: data) }
    catch { throw CloudflareCLIError.invalidResponse("Could not parse current Worker deployment: \(error.localizedDescription)") }
  }

  private func workerJSONDecoder() -> JSONDecoder {
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

  private func scopedFailure(id: String, error: Error) -> CloudflareScopedFailure {
    CloudflareScopedFailure(
      scopeID: id,
      message: error.localizedDescription,
      isRateLimited: error as? CloudflareCLIError == .rateLimited
    )
  }

  private func classifiedFailure(from result: CloudflareCommandResult) -> CloudflareCLIError {
    let rawMessage = [result.stderrString, result.stdoutString]
      .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    let normalized = rawMessage.lowercased()
    if normalized.contains("not logged in")
      || normalized.contains("auth token has expired")
      || normalized.contains("authentication required")
      || normalized.contains("wrangler login")
      || normalized.contains("not authenticated")
    {
      return .authenticationRequired
    }
    if normalized.contains("rate limit") || normalized.contains("too many requests") || normalized.contains("429") {
      return .rateLimited
    }
    let message = sanitizedMessage(rawMessage)
    return .commandFailed(message.isEmpty ? "Wrangler failed with exit code \(result.terminationStatus)." : message)
  }

  private func sanitizedMessage(_ rawMessage: String) -> String {
    var message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacements = [
      (#"(?i)(CLOUDFLARE_API_TOKEN\s*[=:]\s*)\S+"#, "$1<redacted>"),
      (#"(?i)((?:authorization:\s*bearer|bearer|api[_ -]?token)\s*[=:]?\s*)\S+"#, "$1<redacted>"),
      (#"(?i)(X-Auth-Key\s*[=:]\s*)\S+"#, "$1<redacted>"),
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
    let fileManager = FileManager.default
    let url = fileManager.temporaryDirectory.appendingPathComponent("portdeck-cloudflare-\(UUID().uuidString)", isDirectory: true)
    try? fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return url
  }
}

public enum CloudflareCLIError: LocalizedError, Equatable, Sendable {
  case missingCLI
  case unsupportedCLI(currentVersion: String)
  case authenticationRequired
  case rateLimited
  case commandFailed(String)
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .missingCLI:
      return "Wrangler is not installed."
    case .unsupportedCLI(let currentVersion):
      return "PortDeck found Wrangler \(currentVersion), but supports \(CloudflareCLIClient.supportedVersionRange.displayName)."
    case .authenticationRequired:
      return "Cloudflare authentication required. Run `\(CloudflareCLIClient.loginCommand)` in Terminal."
    case .rateLimited:
      return "Cloudflare API rate limit reached. PortDeck will retry on the next scheduled refresh."
    case .commandFailed(let message):
      return message
    case .invalidResponse(let message):
      return message
    }
  }
}

private struct WhoAmIResponse: Decodable {
  let loggedIn: Bool
  let accounts: [CloudflareAccount]
}

private extension CloudflareCommandResult {
  var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
  var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
}
