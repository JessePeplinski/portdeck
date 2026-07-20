import Foundation

public struct GitHubCommandResult: Equatable, Sendable {
  public let stdout: Data
  public let stderr: Data
  public let terminationStatus: Int32

  public init(stdout: Data, stderr: Data = Data(), terminationStatus: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.terminationStatus = terminationStatus
  }
}

public protocol GitHubCommandRunning: Sendable {
  func run(executableURL: URL, arguments: [String]) async throws -> GitHubCommandResult
}

public protocol GitHubCLIClientProtocol: Sendable {
  func inspectConnection() async -> GitHubConnectionState
  func fetchRepositoryMetadata(
    for candidate: GitHubRepositoryCandidate,
    forceRefresh: Bool
  ) async throws -> GitHubRepositoryMetadata
  func fetchWorkflowRuns(
    for candidate: GitHubRepositoryCandidate,
    defaultBranch: String
  ) async throws -> [GitHubWorkflowRun]
}

public struct SystemGitHubCommandRunner: GitHubCommandRunning {
  public init() {}

  public func run(executableURL: URL, arguments: [String]) async throws -> GitHubCommandResult {
    try await Task.detached {
      try Self.runSync(executableURL: executableURL, arguments: arguments)
    }.value
  }

  private static func runSync(executableURL: URL, arguments: [String]) throws -> GitHubCommandResult {
    let fileManager = FileManager.default
    let nonce = UUID().uuidString
    let stdoutURL = fileManager.temporaryDirectory.appendingPathComponent("portdeck-github-\(nonce)-stdout")
    let stderrURL = fileManager.temporaryDirectory.appendingPathComponent("portdeck-github-\(nonce)-stderr")

    guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
      fileManager.createFile(atPath: stderrURL.path, contents: nil)
    else {
      throw GitHubCLIError.commandFailed("Could not create secure temporary command output files.")
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
    process.currentDirectoryURL = fileManager.homeDirectoryForCurrentUser
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
    return GitHubCommandResult(
      stdout: try Data(contentsOf: stdoutURL),
      stderr: try Data(contentsOf: stderrURL),
      terminationStatus: process.terminationStatus
    )
  }
}

public actor GitHubCLIClient: GitHubCLIClientProtocol {
  public static let loginCommand = "gh auth login"
  public static let overrideEnvironmentKey = "PORTDECK_GH_BIN"
  public static let metadataCacheDuration: TimeInterval = 5 * 60

  private let executableURLOverride: URL?
  private let runner: any GitHubCommandRunning
  private let environment: [String: String]
  private let executableSearchPaths: [String]
  private let fileManager: FileManager
  private let now: @Sendable () -> Date
  private var cachedExecutableURL: URL?
  private var metadataCache: [String: GitHubRepositoryMetadata] = [:]

  public init(
    executableURL: URL? = nil,
    runner: any GitHubCommandRunning = SystemGitHubCommandRunner(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executableSearchPaths: [String] = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"],
    fileManager: FileManager = .default,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    executableURLOverride = executableURL
    self.runner = runner
    self.environment = environment
    self.executableSearchPaths = executableSearchPaths
    self.fileManager = fileManager
    self.now = now
  }

  public func inspectConnection() async -> GitHubConnectionState {
    do {
      guard let executableURL = try await resolveExecutableURL() else {
        return .missingCLI
      }

      let result = try await runner.run(executableURL: executableURL, arguments: ["api", "--include", "user"])
      let response = try? GitHubIncludedResponse.parse(result.stdout)
      if result.terminationStatus != 0 || (response?.statusCode ?? 200) >= 400 {
        switch classifiedFailure(result: result, response: response) {
        case .unauthenticated:
          return .unauthenticated
        case .rateLimited(let until, let message):
          return .rateLimited(until: until, message: message)
        case .missingCLI:
          return .missingCLI
        case .commandFailed(let message), .invalidResponse(let message):
          return .failed(message: message)
        }
      }
      return .connected
    } catch GitHubCLIError.missingCLI {
      return .missingCLI
    } catch {
      return .failed(message: sanitizedMessage(error.localizedDescription))
    }
  }

  public func fetchRepositoryMetadata(
    for candidate: GitHubRepositoryCandidate,
    forceRefresh: Bool = false
  ) async throws -> GitHubRepositoryMetadata {
    if !forceRefresh,
      let cached = metadataCache[candidate.id],
      now().timeIntervalSince(cached.fetchedAt) >= 0,
      now().timeIntervalSince(cached.fetchedAt) < Self.metadataCacheDuration
    {
      return cached
    }

    let response = try await performAPI(endpoint: "repos/\(candidate.owner)/\(candidate.repository)")
    let payload: GitHubRepositoryResponse
    do {
      payload = try decoder.decode(GitHubRepositoryResponse.self, from: response.body)
    } catch {
      throw GitHubCLIError.invalidResponse(error.localizedDescription)
    }
    guard !payload.defaultBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GitHubCLIError.invalidResponse("GitHub returned an empty default branch.")
    }

    let metadata = GitHubRepositoryMetadata(defaultBranch: payload.defaultBranch, fetchedAt: now())
    metadataCache[candidate.id] = metadata
    return metadata
  }

  public func fetchWorkflowRuns(
    for candidate: GitHubRepositoryCandidate,
    defaultBranch: String
  ) async throws -> [GitHubWorkflowRun] {
    guard let encodedBranch = encodedQueryValue(defaultBranch) else {
      throw GitHubCLIError.invalidResponse("The repository default branch could not be encoded.")
    }
    let endpoint = "repos/\(candidate.owner)/\(candidate.repository)/actions/runs?branch=\(encodedBranch)&per_page=50"
    let response = try await performAPI(endpoint: endpoint)

    do {
      let page = try decoder.decode(GitHubWorkflowRunsPage.self, from: response.body)
      return GitHubWorkflowStatusBuilder.latestRunsByWorkflow(page.workflowRuns)
    } catch {
      throw GitHubCLIError.invalidResponse(error.localizedDescription)
    }
  }

  private var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private func performAPI(endpoint: String) async throws -> GitHubIncludedResponse {
    let executableURL = try await requiredExecutableURL()
    let result = try await runner.run(
      executableURL: executableURL,
      arguments: ["api", "--include", endpoint]
    )
    let response = try? GitHubIncludedResponse.parse(result.stdout)

    if result.terminationStatus != 0 || (response?.statusCode ?? 200) >= 400 {
      throw classifiedFailure(result: result, response: response)
    }
    guard let response else {
      throw GitHubCLIError.invalidResponse("GitHub CLI did not return HTTP response headers.")
    }
    return response
  }

  private func requiredExecutableURL() async throws -> URL {
    guard let executableURL = try await resolveExecutableURL() else {
      throw GitHubCLIError.missingCLI
    }
    return executableURL
  }

  private func resolveExecutableURL() async throws -> URL? {
    if let cachedExecutableURL { return cachedExecutableURL }

    if let override = environment[Self.overrideEnvironmentKey] {
      guard fileManager.isExecutableFile(atPath: override) else {
        throw GitHubCLIError.missingCLI
      }
      let url = URL(fileURLWithPath: override)
      cachedExecutableURL = url
      return url
    }

    if let executableURLOverride {
      cachedExecutableURL = executableURLOverride
      return executableURLOverride
    }

    let shell = environment["SHELL"] ?? "/bin/zsh"
    if fileManager.isExecutableFile(atPath: shell) {
      let lookup = try await runner.run(
        executableURL: URL(fileURLWithPath: shell),
        arguments: ["-lc", "command -v gh"]
      )
      if lookup.terminationStatus == 0 {
        let path = lookup.stdoutString
          .split(whereSeparator: \.isNewline)
          .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
          .last { !$0.isEmpty }
        if let path, fileManager.isExecutableFile(atPath: path) {
          let url = URL(fileURLWithPath: path)
          if await isGitHubCLI(url) {
            cachedExecutableURL = url
            return url
          }
        }
      }
    }

    for path in executableSearchPaths where fileManager.isExecutableFile(atPath: path) {
      let url = URL(fileURLWithPath: path)
      cachedExecutableURL = url
      return url
    }
    return nil
  }

  private func isGitHubCLI(_ executableURL: URL) async -> Bool {
    guard let result = try? await runner.run(executableURL: executableURL, arguments: ["--version"]),
      result.terminationStatus == 0
    else {
      return false
    }
    return result.stdoutString.range(
      of: #"(?m)^gh version \d+\.\d+\.\d+(?:\s|$)"#,
      options: .regularExpression
    ) != nil
  }

  private func classifiedFailure(
    result: GitHubCommandResult,
    response: GitHubIncludedResponse?
  ) -> GitHubCLIError {
    let rawMessage = [response?.bodyString, result.stderrString, result.stdoutString]
      .compactMap { $0 }
      .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    let statusCode = response?.statusCode

    if isAuthenticationFailure(statusCode: statusCode, message: rawMessage) {
      return .unauthenticated
    }
    let headers = response?.headers ?? [:]
    let isRateLimited = statusCode == 429
      || rawMessage.lowercased().contains("rate limit")
      || headers["retry-after"] != nil
      || headers["x-ratelimit-remaining"] == "0"
    if isRateLimited {
      let until = rateLimitResumeDate(headers: response?.headers ?? [:])
      return .rateLimited(
        until: until,
        message: "GitHub API rate limit reached. PortDeck will retry after \(formattedTime(until))."
      )
    }
    return .commandFailed(sanitizedMessage(rawMessage, fallbackExitCode: result.terminationStatus))
  }

  private func rateLimitResumeDate(headers: [String: String]) -> Date {
    if let retryAfter = headers["retry-after"], let seconds = TimeInterval(retryAfter) {
      return now().addingTimeInterval(max(1, seconds))
    }
    if headers["x-ratelimit-remaining"] == "0",
      let reset = headers["x-ratelimit-reset"],
      let timestamp = TimeInterval(reset)
    {
      return max(Date(timeIntervalSince1970: timestamp), now().addingTimeInterval(1))
    }
    return now().addingTimeInterval(60)
  }

  private func isAuthenticationFailure(statusCode: Int?, message: String) -> Bool {
    if statusCode == 401 { return true }
    let normalized = message.lowercased()
    return normalized.contains("gh auth login")
      || normalized.contains("not logged in")
      || normalized.contains("authentication required")
      || normalized.contains("http 401")
      || normalized.contains("bad credentials")
  }

  private func sanitizedMessage(_ rawMessage: String, fallbackExitCode: Int32? = nil) -> String {
    var message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    let replacements = [
      (#"(?i)(authorization\s*:\s*(?:bearer|token)\s+)\S+"#, "$1<redacted>"),
      (#"(?i)((?:GH_TOKEN|GITHUB_TOKEN|access[_ -]?token|oauth[_ -]?token|token)\s*[=:]\s*)\S+"#, "$1<redacted>"),
      (#"(?i)\b(?:gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,})\b"#, "<redacted>"),
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

    if message.isEmpty, let fallbackExitCode {
      message = "GitHub CLI command failed with exit code \(fallbackExitCode)."
    }
    return String(message.prefix(500))
  }

  private func encodedQueryValue(_ value: String) -> String? {
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=+#")
    return value.addingPercentEncoding(withAllowedCharacters: allowed)
  }

  private func formattedTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter.string(from: date)
  }
}

public enum GitHubCLIError: LocalizedError, Equatable, Sendable {
  case missingCLI
  case unauthenticated
  case rateLimited(until: Date, message: String)
  case commandFailed(String)
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .missingCLI:
      return "GitHub CLI is not installed."
    case .unauthenticated:
      return "GitHub authentication required. Run `\(GitHubCLIClient.loginCommand)`."
    case .rateLimited(_, let message), .commandFailed(let message):
      return message
    case .invalidResponse(let message):
      return "Could not parse GitHub Actions health: \(message)"
    }
  }
}

private struct GitHubRepositoryResponse: Decodable {
  let defaultBranch: String

  enum CodingKeys: String, CodingKey {
    case defaultBranch = "default_branch"
  }
}

private struct GitHubIncludedResponse {
  let statusCode: Int
  let headers: [String: String]
  let body: Data

  var bodyString: String {
    String(data: body, encoding: .utf8) ?? ""
  }

  static func parse(_ data: Data) throws -> GitHubIncludedResponse {
    guard let output = String(data: data, encoding: .utf8) else {
      throw GitHubCLIError.invalidResponse("GitHub CLI returned non-UTF-8 output.")
    }

    let separator: Range<String.Index>?
    if let range = output.range(of: "\r\n\r\n") {
      separator = range
    } else {
      separator = output.range(of: "\n\n")
    }
    guard let separator else {
      throw GitHubCLIError.invalidResponse("GitHub CLI omitted HTTP response headers.")
    }

    let headerText = String(output[..<separator.lowerBound])
    let bodyText = String(output[separator.upperBound...])
    let lines = headerText.split(whereSeparator: \.isNewline).map(String.init)
    guard let statusLine = lines.first,
      statusLine.hasPrefix("HTTP/"),
      let statusCode = Int(statusLine.split(separator: " ").dropFirst().first ?? "")
    else {
      throw GitHubCLIError.invalidResponse("GitHub CLI returned an invalid HTTP status line.")
    }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
      headers[name] = value
    }
    return GitHubIncludedResponse(
      statusCode: statusCode,
      headers: headers,
      body: Data(bodyText.utf8)
    )
  }
}

private extension GitHubCommandResult {
  var stdoutString: String { String(data: stdout, encoding: .utf8) ?? "" }
  var stderrString: String { String(data: stderr, encoding: .utf8) ?? "" }
}
