import Foundation

public struct HostingerCommandResult: Equatable, Sendable {
  public let stdout: Data
  public let stderr: Data
  public let terminationStatus: Int32

  public init(stdout: Data, stderr: Data = Data(), terminationStatus: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.terminationStatus = terminationStatus
  }
}

public protocol HostingerCommandRunning: Sendable {
  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> HostingerCommandResult
}

public protocol HostingerCLIClientProtocol: Sendable {
  func fetchWebsites() async throws -> [HostingerWebsite]
}

public enum HostingerCommandAllowlist {
  public static func validate(_ arguments: [String]) throws {
    if arguments.count == 3,
      arguments[0] == "version",
      arguments[1] == "--config",
      isSafeConfigPath(arguments[2])
    {
      return
    }

    guard arguments.count == 11,
      arguments[0] == "hosting",
      arguments[1] == "websites",
      arguments[2] == "list",
      arguments[3] == "--page",
      let page = Int(arguments[4]),
      (1...HostingerCLIClient.maximumPageCount).contains(page),
      arguments[5] == "--per-page",
      arguments[6] == String(HostingerCLIClient.pageSize),
      arguments[7] == "--format",
      arguments[8] == "json",
      arguments[9] == "--config",
      isSafeConfigPath(arguments[10])
    else {
      throw HostingerCLIError.unsafeCommand
    }
  }

  private static func isSafeConfigPath(_ value: String) -> Bool {
    value.hasPrefix("/")
      && value.count <= 1_024
      && value.rangeOfCharacter(from: .controlCharacters) == nil
      && URL(fileURLWithPath: value).lastPathComponent == ".hostinger.yaml"
  }
}

public struct SystemHostingerCommandRunner: HostingerCommandRunning {
  public init() {}

  public func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> HostingerCommandResult {
    try HostingerCommandAllowlist.validate(arguments)
    let coordinator = HostingerRunningProcessCoordinator()
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
    coordinator: HostingerRunningProcessCoordinator
  ) throws -> HostingerCommandResult {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: currentDirectoryURL, withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: currentDirectoryURL.path)

    let nonce = UUID().uuidString
    let stdoutURL = currentDirectoryURL.appendingPathComponent("command-\(nonce)-stdout")
    let stderrURL = currentDirectoryURL.appendingPathComponent("command-\(nonce)-stderr")
    guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
      fileManager.createFile(atPath: stderrURL.path, contents: nil)
    else {
      throw HostingerCLIError.commandFailed("Could not create secure temporary Hostinger command output files.")
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
      if !coordinator.register(process) {
        process.terminate()
      }
      process.waitUntilExit()
      coordinator.clear(process)
    } catch {
      coordinator.clear(process)
      if coordinator.isCancelled {
        throw CancellationError()
      }
      throw error
    }

    if coordinator.isCancelled {
      throw CancellationError()
    }
    try stdoutHandle.close()
    try stderrHandle.close()
    return HostingerCommandResult(
      stdout: try Data(contentsOf: stdoutURL),
      stderr: process.terminationStatus == 0 ? Data() : try Data(contentsOf: stderrURL),
      terminationStatus: process.terminationStatus
    )
  }
}

public actor HostingerCLIClient: HostingerCLIClientProtocol {
  public static let supportedVersionRange = HostingerRuntimeResolver.supportedVersionRange
  public static let connectCommand = "hostinger hosting websites list --format json"
  public static let pageSize = 100
  public static let maximumPageCount = 100
  public static let maximumAuthoritativeWebsiteCount = pageSize * maximumPageCount

  public static let removedEnvironmentKeys: Set<String> = [
    "HOSTINGER_API_TOKEN",
    "HOSTINGER_API_URL",
    "HOSTINGER_OAUTH_ISSUER",
    "HAPI_API_TOKEN",
    "HAPI_API_URL"
  ]

  private static let disabledOAuthIssuer = "http://127.0.0.1:0"

  private let runner: any HostingerCommandRunning
  private let runtimeResolver: any HostingerRuntimeResolving
  private let environment: [String: String]
  private let currentDirectoryURL: URL
  private let configurationURL: URL
  private var cachedExecutableURL: URL?

  public init(
    runner: any HostingerCommandRunning = SystemHostingerCommandRunner(),
    runtimeResolver: any HostingerRuntimeResolving = HostingerRuntimeResolver(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectoryURL: URL? = nil,
    configurationURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".hostinger.yaml")
  ) {
    self.runner = runner
    self.runtimeResolver = runtimeResolver
    var environment = environment
    for key in Self.removedEnvironmentKeys {
      environment.removeValue(forKey: key)
    }
    environment["HOSTINGER_OAUTH_ISSUER"] = Self.disabledOAuthIssuer
    environment["NO_COLOR"] = "1"
    self.environment = environment
    self.currentDirectoryURL = currentDirectoryURL
      ?? FileManager.default.temporaryDirectory.appendingPathComponent("portdeck-hostinger-\(UUID().uuidString)")
    self.configurationURL = configurationURL.standardizedFileURL
  }

  public func fetchWebsites() async throws -> [HostingerWebsite] {
    let executableURL = try await validatedExecutableURL()
    var page = 1
    var expectedTotal: Int?
    var websites: [HostingerWebsite] = []
    var websiteIDs: Set<String> = []

    while page <= Self.maximumPageCount {
      let data = try await runJSON(
        executableURL: executableURL,
        arguments: [
          "hosting", "websites", "list",
          "--page", String(page),
          "--per-page", String(Self.pageSize),
          "--format", "json",
          "--config", configurationURL.path
        ]
      )

      let envelope: HostingerWebsitesEnvelope
      do {
        envelope = try hostingerDecoder().decode(HostingerWebsitesEnvelope.self, from: data)
      } catch {
        throw HostingerCLIError.malformedOutput("Could not parse the Hostinger website list.")
      }

      guard envelope.meta.currentPage == page,
        envelope.meta.perPage > 0,
        envelope.meta.perPage <= Self.pageSize,
        envelope.meta.total >= 0,
        envelope.meta.total <= Self.maximumAuthoritativeWebsiteCount
      else {
        throw HostingerCLIError.incompletePagination
      }

      if let expectedTotal {
        guard envelope.meta.total == expectedTotal else {
          throw HostingerCLIError.incompletePagination
        }
      } else {
        expectedTotal = envelope.meta.total
      }

      let pageWebsites = envelope.data.compactMap(\.snapshot)
      guard pageWebsites.count == envelope.data.count else {
        throw HostingerCLIError.malformedOutput("Hostinger returned an unusable website record.")
      }
      for website in pageWebsites {
        guard websiteIDs.insert(website.id).inserted else {
          throw HostingerCLIError.incompletePagination
        }
        websites.append(website)
      }

      guard let total = expectedTotal, websites.count <= total else {
        throw HostingerCLIError.incompletePagination
      }
      if websites.count == total {
        return HostingerStatusBuilder.sortedWebsites(websites)
      }
      guard !pageWebsites.isEmpty else {
        throw HostingerCLIError.incompletePagination
      }
      page += 1
    }

    throw HostingerCLIError.incompletePagination
  }

  private func validatedExecutableURL() async throws -> URL {
    if let cachedExecutableURL {
      return cachedExecutableURL
    }
    let executableURL = try runtimeResolver.resolveExecutableURL()
    let result = try await runCommand(
      executableURL: executableURL,
      arguments: ["version", "--config", configurationURL.path]
    )
    guard result.terminationStatus == 0 else {
      throw Self.classifiedFailure(from: result)
    }

    let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let version = ProviderCLIVersion.first(in: output),
      Self.supportedVersionRange.contains(version)
    else {
      throw HostingerCLIError.unsupportedCLI(currentVersion: String(output.prefix(120)))
    }
    cachedExecutableURL = executableURL
    return executableURL
  }

  private func runJSON(
    executableURL: URL,
    arguments: [String]
  ) async throws -> Data {
    let result = try await runCommand(executableURL: executableURL, arguments: arguments)
    guard result.terminationStatus == 0 else {
      throw Self.classifiedFailure(from: result)
    }
    return result.stdout
  }

  private func runCommand(
    executableURL: URL,
    arguments: [String]
  ) async throws -> HostingerCommandResult {
    try HostingerCommandAllowlist.validate(arguments)
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
      throw HostingerCLIError.cancelled
    }
  }

  private static func classifiedFailure(from result: HostingerCommandResult) -> HostingerCLIError {
    let rawMessage = [result.stdoutString, result.stderrString]
      .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    let normalized = rawMessage.lowercased()

    if normalized.contains("unauthenticated")
      || normalized.contains("unauthorized")
      || normalized.contains("status 401")
      || normalized.contains(#""status":401"#)
      || normalized.contains("api token")
      || normalized.contains("127.0.0.1:0")
    {
      return .authenticationRequired
    }
    if normalized.contains("rate limit")
      || normalized.contains("too many requests")
      || normalized.contains("status 429")
      || normalized.contains(#""status":429"#)
    {
      return .rateLimited
    }
    if normalized.contains("timed out")
      || normalized.contains("timeout")
      || normalized.contains("connection reset")
      || normalized.contains("temporarily unavailable")
      || normalized.contains("service unavailable")
      || normalized.contains("bad gateway")
      || normalized.contains("gateway timeout")
      || normalized.contains("status 502")
      || normalized.contains("status 503")
      || normalized.contains("status 504")
    {
      return .transientFailure
    }

    let message = sanitizedMessage(rawMessage)
    return .commandFailed(
      message.isEmpty
        ? "Hostinger CLI failed with exit code \(result.terminationStatus)."
        : message
    )
  }

  private static func sanitizedMessage(_ rawMessage: String) -> String {
    var message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacements = [
      (#"(?im)^Using config file:.*$"#, "Using Hostinger CLI config"),
      (#"(?i)((?:HOSTINGER|HAPI)_API_TOKEN\s*[=:]\s*)\S+"#, "$1<redacted>"),
      (#"(?i)((?:authorization:\s*bearer|bearer|access[_ -]?token|api[_ -]?token|token)\s*[=:]?\s*)\S+"#, "$1<redacted>"),
      (#"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]{10,})?"#, "<redacted>")
    ]
    for (pattern, replacement) in replacements {
      guard let expression = try? NSRegularExpression(pattern: pattern) else {
        continue
      }
      message = expression.stringByReplacingMatches(
        in: message,
        range: NSRange(message.startIndex..., in: message),
        withTemplate: replacement
      )
    }
    return String(message.prefix(500))
  }
}

public enum HostingerCLIError: LocalizedError, Equatable, Sendable {
  case missingCLI
  case unsupportedCLI(currentVersion: String)
  case authenticationRequired
  case rateLimited
  case malformedOutput(String)
  case incompletePagination
  case transientFailure
  case commandFailed(String)
  case unsafeCommand
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .missingCLI:
      return "Hostinger CLI is not installed."
    case .unsupportedCLI(let currentVersion):
      return "PortDeck found Hostinger CLI \(currentVersion), but supports \(HostingerCLIClient.supportedVersionRange.displayName)."
    case .authenticationRequired:
      return "Hostinger authentication required. Run `\(HostingerCLIClient.connectCommand)` in Terminal."
    case .rateLimited:
      return "Hostinger API rate limit reached. PortDeck will retry on the next scheduled refresh."
    case .malformedOutput(let message):
      return message
    case .incompletePagination:
      return "Hostinger returned an incomplete website list. PortDeck kept the prior snapshot instead of treating partial account data as authoritative."
    case .transientFailure:
      return "Hostinger is temporarily unavailable. PortDeck will retry on the next scheduled refresh."
    case .commandFailed(let message):
      return message
    case .unsafeCommand:
      return "PortDeck blocked a Hostinger command outside the read-only allowlist."
    case .cancelled:
      return "Hostinger refresh canceled."
    }
  }
}

private struct HostingerWebsitesEnvelope: Decodable {
  let data: [HostingerWebsiteRow]
  let meta: HostingerPaginationMetadata
}

private struct HostingerPaginationMetadata: Decodable {
  let currentPage: Int
  let perPage: Int
  let total: Int

  enum CodingKeys: String, CodingKey {
    case currentPage = "current_page"
    case perPage = "per_page"
    case total
  }
}

private struct HostingerWebsiteRow: Decodable {
  let domain: String?
  let isEnabled: Bool?
  let orderID: Int?
  let parentDomain: String?
  let vhostType: String?
  let createdAt: Date?

  enum CodingKeys: String, CodingKey {
    case domain
    case isEnabled = "is_enabled"
    case orderID = "order_id"
    case parentDomain = "parent_domain"
    case vhostType = "vhost_type"
    case createdAt = "created_at"
  }

  var snapshot: HostingerWebsite? {
    guard let domain = boundedHostingerValue(domain, limit: 253) else {
      return nil
    }
    return HostingerWebsite(
      domain: domain,
      isEnabled: isEnabled,
      orderID: orderID,
      parentDomain: boundedHostingerValue(parentDomain, limit: 253),
      vhostType: boundedHostingerValue(vhostType, limit: 80),
      createdAt: createdAt
    )
  }
}

private func boundedHostingerValue(_ value: String?, limit: Int) -> String? {
  guard let value else {
    return nil
  }
  let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !normalized.isEmpty,
    normalized.count <= limit,
    normalized.rangeOfCharacter(from: .controlCharacters) == nil
  else {
    return nil
  }
  return normalized
}

private func hostingerDecoder() -> JSONDecoder {
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .custom { decoder in
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: raw) {
      return date
    }
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    if let date = standard.date(from: raw) {
      return date
    }
    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "Invalid Hostinger timestamp."
    )
  }
  return decoder
}

private extension HostingerCommandResult {
  var stdoutString: String {
    String(data: stdout, encoding: .utf8) ?? ""
  }

  var stderrString: String {
    String(data: stderr, encoding: .utf8) ?? ""
  }
}

private final class HostingerRunningProcessCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private(set) var isCancelled = false

  func register(_ process: Process) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isCancelled else {
      return false
    }
    self.process = process
    return true
  }

  func clear(_ process: Process) {
    lock.lock()
    defer { lock.unlock() }
    if self.process === process {
      self.process = nil
    }
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    let process = process
    lock.unlock()
    if process?.isRunning == true {
      process?.terminate()
    }
  }
}
