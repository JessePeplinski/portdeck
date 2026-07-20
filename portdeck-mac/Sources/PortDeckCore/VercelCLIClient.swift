import Foundation

public enum VercelConnectionState: Equatable, Sendable {
  case checking
  case missingCLI
  case outdatedCLI(currentVersion: String)
  case unauthenticated
  case connecting
  case connected
  case failed(message: String)
}

public struct VercelCommandResult: Equatable, Sendable {
  public let stdout: Data
  public let stderr: Data
  public let terminationStatus: Int32

  public init(stdout: Data, stderr: Data = Data(), terminationStatus: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.terminationStatus = terminationStatus
  }
}

public protocol VercelCommandRunning: Sendable {
  func run(executableURL: URL, arguments: [String]) async throws -> VercelCommandResult
}

public protocol VercelCLIClientProtocol: Sendable {
  func inspectConnection() async -> VercelConnectionState
  func login() async throws
  func fetchProjectSnapshot() async throws -> VercelProjectSnapshot
  func fetchRecentProductionDeployments() async throws -> [VercelAPIRecentDeployment]
}

public struct SystemVercelCommandRunner: VercelCommandRunning {
  public init() {}

  public func run(executableURL: URL, arguments: [String]) async throws -> VercelCommandResult {
    try await Task.detached {
      try Self.runSync(executableURL: executableURL, arguments: arguments)
    }.value
  }

  private static func runSync(executableURL: URL, arguments: [String]) throws -> VercelCommandResult {
    let fileManager = FileManager.default
    let token = UUID().uuidString
    let stdoutURL = fileManager.temporaryDirectory.appendingPathComponent("portdeck-vercel-\(token)-stdout")
    let stderrURL = fileManager.temporaryDirectory.appendingPathComponent("portdeck-vercel-\(token)-stderr")

    guard fileManager.createFile(atPath: stdoutURL.path, contents: nil),
      fileManager.createFile(atPath: stderrURL.path, contents: nil)
    else {
      throw VercelCLIError.commandFailed("Could not create secure temporary command output files.")
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

    return VercelCommandResult(
      stdout: try Data(contentsOf: stdoutURL),
      stderr: try Data(contentsOf: stderrURL),
      terminationStatus: process.terminationStatus
    )
  }
}

public actor VercelCLIClient: VercelCLIClientProtocol {
  public static let minimumVersion = "50.5.1"
  public static let installCommand = "npm install -g vercel@latest"

  private let executableURLOverride: URL?
  private let runner: any VercelCommandRunning
  private let environment: [String: String]
  private let executableSearchPaths: [String]
  private var cachedExecutableURL: URL?

  public init(
    executableURL: URL? = nil,
    runner: any VercelCommandRunning = SystemVercelCommandRunner(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executableSearchPaths: [String] = ["/opt/homebrew/bin/vercel", "/usr/local/bin/vercel"]
  ) {
    executableURLOverride = executableURL
    self.runner = runner
    self.environment = environment
    self.executableSearchPaths = executableSearchPaths
  }

  public func inspectConnection() async -> VercelConnectionState {
    do {
      guard let executableURL = try await resolveExecutableURL() else {
        return .missingCLI
      }

      let versionResult = try await runner.run(executableURL: executableURL, arguments: ["--version"])
      guard versionResult.terminationStatus == 0 else {
        return .failed(message: commandFailureMessage(from: versionResult))
      }
      guard let version = SemanticVersion.first(in: versionResult.stdoutString),
        let minimum = SemanticVersion(string: Self.minimumVersion)
      else {
        return .failed(message: "Could not read the installed Vercel CLI version.")
      }
      guard version >= minimum else {
        return .outdatedCLI(currentVersion: version.description)
      }

      let authResult = try await runner.run(executableURL: executableURL, arguments: ["whoami"])
      return authResult.terminationStatus == 0 ? .connected : .unauthenticated
    } catch VercelCLIError.missingCLI {
      return .missingCLI
    } catch {
      return .failed(message: error.localizedDescription)
    }
  }

  public func login() async throws {
    let executableURL = try await requiredExecutableURL()
    let result = try await runner.run(executableURL: executableURL, arguments: ["login"])
    guard result.terminationStatus == 0 else {
      throw VercelCLIError.commandFailed(commandFailureMessage(from: result))
    }
  }

  public func fetchProjectSnapshot() async throws -> VercelProjectSnapshot {
    let executableURL = try await requiredExecutableURL()
    var projectsByID: [String: VercelAPIProject] = [:]
    var nextCursor: Int64?
    var seenCursors = Set<Int64>()

    repeat {
      var endpoint = "/v10/projects?limit=100"
      if let nextCursor {
        guard seenCursors.insert(nextCursor).inserted else {
          throw VercelCLIError.invalidResponse("Vercel returned a repeated pagination cursor.")
        }
        endpoint += "&until=\(nextCursor)"
      }

      let result = try await runner.run(executableURL: executableURL, arguments: ["api", endpoint])
      guard result.terminationStatus == 0 else {
        throw VercelCLIError.commandFailed(commandFailureMessage(from: result))
      }

      let page: VercelProjectsPage
      do {
        page = try JSONDecoder().decode(VercelProjectsPage.self, from: result.stdout)
      } catch {
        throw VercelCLIError.invalidResponse(error.localizedDescription)
      }

      for project in page.projects {
        projectsByID[project.id] = project
      }
      nextCursor = page.pagination.next
    } while nextCursor != nil

    let projects = Array(projectsByID.values)
    let scope = await fetchScope(for: projects, executableURL: executableURL)
    return VercelProjectSnapshot(
      scope: scope,
      projects: VercelProjectStatusBuilder.build(from: projects)
    )
  }

  public func fetchRecentProductionDeployments() async throws -> [VercelAPIRecentDeployment] {
    let executableURL = try await requiredExecutableURL()
    let endpoint = "/v7/deployments?limit=100&target=production"
    let result = try await runner.run(executableURL: executableURL, arguments: ["api", endpoint])
    guard result.terminationStatus == 0 else {
      throw VercelCLIError.commandFailed(commandFailureMessage(from: result))
    }

    do {
      return try JSONDecoder().decode(VercelDeploymentsPage.self, from: result.stdout).deployments
    } catch {
      throw VercelCLIError.invalidResponse(error.localizedDescription)
    }
  }

  private func fetchScope(
    for projects: [VercelAPIProject],
    executableURL: URL
  ) async -> VercelScope? {
    let accountIDs = Set(projects.compactMap { project in
      project.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    })
    guard accountIDs.count == 1, let accountID = accountIDs.first else {
      return nil
    }

    let fallback = VercelScope(id: accountID, name: nil, slug: nil)
    guard accountID.range(
      of: #"^[A-Za-z0-9_-]+$"#,
      options: .regularExpression
    ) != nil
    else {
      return fallback
    }

    do {
      let result = try await runner.run(
        executableURL: executableURL,
        arguments: ["api", "/v2/teams/\(accountID)"]
      )
      guard result.terminationStatus == 0,
        let team = try? JSONDecoder().decode(VercelAPITeam.self, from: result.stdout),
        team.id == accountID
      else {
        return fallback
      }
      return VercelScope(id: team.id, name: team.name, slug: team.slug)
    } catch {
      return fallback
    }
  }

  private func requiredExecutableURL() async throws -> URL {
    guard let executableURL = try await resolveExecutableURL() else {
      throw VercelCLIError.missingCLI
    }
    return executableURL
  }

  private func resolveExecutableURL() async throws -> URL? {
    if let cachedExecutableURL {
      return cachedExecutableURL
    }
    if let executableURLOverride {
      cachedExecutableURL = executableURLOverride
      return executableURLOverride
    }

    let fileManager = FileManager.default
    if let override = environment["PORTDECK_VERCEL_BIN"] {
      guard fileManager.isExecutableFile(atPath: override) else {
        throw VercelCLIError.missingCLI
      }
      let url = URL(fileURLWithPath: override)
      cachedExecutableURL = url
      return url
    }

    let shell = environment["SHELL"] ?? "/bin/zsh"
    if fileManager.isExecutableFile(atPath: shell) {
      let lookup = try await runner.run(
        executableURL: URL(fileURLWithPath: shell),
        arguments: ["-lc", "command -v vercel"]
      )
      if lookup.terminationStatus == 0 {
        let path = lookup.stdoutString
          .split(whereSeparator: \.isNewline)
          .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
          .last { !$0.isEmpty }
        if let path, fileManager.isExecutableFile(atPath: path) {
          let url = URL(fileURLWithPath: path)
          cachedExecutableURL = url
          return url
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

  private func commandFailureMessage(from result: VercelCommandResult) -> String {
    let rawMessage = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawMessage.isEmpty else {
      return "Vercel CLI command failed with exit code \(result.terminationStatus)."
    }
    return VercelProjectStatusBuilder.sanitizedFailureValue(rawMessage, limit: 500)
      ?? "Vercel CLI command failed with exit code \(result.terminationStatus)."
  }
}

public enum VercelCLIError: LocalizedError, Equatable, Sendable {
  case missingCLI
  case commandFailed(String)
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .missingCLI:
      return "Vercel CLI is not installed."
    case .commandFailed(let message):
      return message
    case .invalidResponse(let message):
      return "Could not parse Vercel status: \(message)"
    }
  }
}

private extension VercelCommandResult {
  var stdoutString: String {
    String(data: stdout, encoding: .utf8) ?? ""
  }

  var stderrString: String {
    String(data: stderr, encoding: .utf8) ?? ""
  }
}

private struct SemanticVersion: Comparable, CustomStringConvertible {
  let major: Int
  let minor: Int
  let patch: Int

  init?(string: String) {
    let parts = string.split(separator: ".")
    guard parts.count == 3,
      let major = Int(parts[0]),
      let minor = Int(parts[1]),
      let patch = Int(parts[2])
    else {
      return nil
    }
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  var description: String {
    "\(major).\(minor).\(patch)"
  }

  static func < (left: SemanticVersion, right: SemanticVersion) -> Bool {
    if left.major != right.major {
      return left.major < right.major
    }
    if left.minor != right.minor {
      return left.minor < right.minor
    }
    return left.patch < right.patch
  }

  static func first(in value: String) -> SemanticVersion? {
    guard let expression = try? NSRegularExpression(pattern: #"(\d+)\.(\d+)\.(\d+)"#),
      let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
      let range = Range(match.range, in: value)
    else {
      return nil
    }
    return SemanticVersion(string: String(value[range]))
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
