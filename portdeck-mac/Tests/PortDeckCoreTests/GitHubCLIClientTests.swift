import Foundation
import Testing
@testable import PortDeckCore

@Test func resolvesGitHubCLIByAuthoritativeOverrideThenShellThenStandardPaths() async throws {
  let fixture = try GitHubExecutableFixture()
  defer { fixture.remove() }
  let overrideURL = try fixture.makeExecutable("override/gh")
  let injectedURL = try fixture.makeExecutable("injected/gh")
  let shellURL = try fixture.makeExecutable("bin/zsh")
  let shellGitHubURL = try fixture.makeExecutable("shell/gh")
  let standardURL = try fixture.makeExecutable("homebrew/gh")

  let overrideRunner = FakeGitHubCommandRunner(responses: [commandResult(#"{"login":"developer"}"#)])
  let overrideClient = GitHubCLIClient(
    executableURL: injectedURL,
    runner: overrideRunner,
    environment: [GitHubCLIClient.overrideEnvironmentKey: overrideURL.path],
    executableSearchPaths: [standardURL.path]
  )
  #expect(await overrideClient.inspectConnection() == .connected)
  #expect(await overrideRunner.receivedExecutables == [overrideURL])
  #expect(await overrideRunner.receivedArguments == [["api", "--include", "user"]])

  let shellRunner = FakeGitHubCommandRunner(responses: [
    commandResult(shellGitHubURL.path + "\n"),
    commandResult("gh version 2.76.2 (2026-07-01)\n"),
    commandResult(#"{"login":"developer"}"#)
  ])
  let shellClient = GitHubCLIClient(
    runner: shellRunner,
    environment: ["SHELL": shellURL.path],
    executableSearchPaths: [standardURL.path]
  )
  #expect(await shellClient.inspectConnection() == .connected)
  #expect(await shellRunner.receivedExecutables == [shellURL, shellGitHubURL, shellGitHubURL])
  #expect(await shellRunner.receivedArguments == [
    ["-lc", "command -v gh"],
    ["--version"],
    ["api", "--include", "user"]
  ])

  let invalidShellRunner = FakeGitHubCommandRunner(responses: [
    commandResult(shellGitHubURL.path + "\n"),
    commandResult("not the GitHub CLI\n"),
    commandResult(#"{"login":"developer"}"#)
  ])
  let invalidShellClient = GitHubCLIClient(
    runner: invalidShellRunner,
    environment: ["SHELL": shellURL.path],
    executableSearchPaths: [standardURL.path]
  )
  #expect(await invalidShellClient.inspectConnection() == .connected)
  #expect(await invalidShellRunner.receivedExecutables == [shellURL, shellGitHubURL, standardURL])

  let standardRunner = FakeGitHubCommandRunner(responses: [commandResult(#"{"login":"developer"}"#)])
  let standardClient = GitHubCLIClient(
    runner: standardRunner,
    environment: ["SHELL": "/missing-shell"],
    executableSearchPaths: [standardURL.path]
  )
  #expect(await standardClient.inspectConnection() == .connected)
  #expect(await standardRunner.receivedExecutables == [standardURL])
}

@Test func reportsMissingAndUnauthenticatedGitHubCLIStates() async throws {
  let missing = GitHubCLIClient(
    runner: FakeGitHubCommandRunner(responses: []),
    environment: ["SHELL": "/missing-shell"],
    executableSearchPaths: []
  )
  #expect(await missing.inspectConnection() == .missingCLI)

  let fixture = try GitHubExecutableFixture()
  defer { fixture.remove() }
  _ = try fixture.makeExecutable("fallback/gh")
  let invalidOverride = GitHubCLIClient(
    runner: FakeGitHubCommandRunner(responses: []),
    environment: [GitHubCLIClient.overrideEnvironmentKey: fixture.root.appendingPathComponent("missing").path],
    executableSearchPaths: [fixture.root.appendingPathComponent("fallback/gh").path]
  )
  #expect(await invalidOverride.inspectConnection() == .missingCLI)

  let unauthenticated = GitHubCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/gh"),
    runner: FakeGitHubCommandRunner(responses: [
      commandResult("", error: "To get started with GitHub CLI, run: gh auth login", status: 1)
    ]),
    environment: [:]
  )
  #expect(await unauthenticated.inspectConnection() == .unauthenticated)
  #expect(GitHubCLIClient.loginCommand == "gh auth login")

  let rateLimited = GitHubCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/gh"),
    runner: FakeGitHubCommandRunner(responses: [
      includedResponse(
        #"{"message":"API rate limit exceeded"}"#,
        statusCode: 429,
        headers: ["Retry-After": "90"],
        terminationStatus: 1
      )
    ]),
    environment: [:],
    now: { Date(timeIntervalSince1970: 1_700_000_000) }
  )
  guard case .rateLimited(let until, _) = await rateLimited.inspectConnection() else {
    Issue.record("Expected authentication check rate limit")
    return
  }
  #expect(until == Date(timeIntervalSince1970: 1_700_000_090))
}

@Test func fetchesDefaultBranchWithFiveMinuteCacheAndUsesExactWorkflowEndpoint() async throws {
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let runner = FakeGitHubCommandRunner(responses: [
    includedResponse(#"{"default_branch":"feature/primary","ignored":"future"}"#),
    includedResponse(workflowPageJSON()),
    includedResponse(#"{"default_branch":"main"}"#)
  ])
  let client = GitHubCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/gh"),
    runner: runner,
    environment: [:],
    now: { now }
  )
  let candidate = GitHubRepositoryCandidate(owner: "OpenAI", repository: "codex", projectNames: ["Codex"])

  let first = try await client.fetchRepositoryMetadata(for: candidate, forceRefresh: false)
  let cached = try await client.fetchRepositoryMetadata(for: candidate, forceRefresh: false)
  let runs = try await client.fetchWorkflowRuns(for: candidate, defaultBranch: first.defaultBranch)
  let forced = try await client.fetchRepositoryMetadata(for: candidate, forceRefresh: true)

  #expect(first == cached)
  #expect(first.defaultBranch == "feature/primary")
  #expect(forced.defaultBranch == "main")
  #expect(runs.count == 1)
  #expect(runs[0].name == "Verify")
  #expect(await runner.receivedArguments == [
    ["api", "--include", "repos/OpenAI/codex"],
    ["api", "--include", "repos/OpenAI/codex/actions/runs?branch=feature/primary&per_page=50"],
    ["api", "--include", "repos/OpenAI/codex"]
  ])
}

@Test func expiresGitHubDefaultBranchMetadataAfterFiveMinutes() async throws {
  let clock = LockedGitHubTestClock(Date(timeIntervalSince1970: 1_700_000_000))
  let runner = FakeGitHubCommandRunner(responses: [
    includedResponse(#"{"default_branch":"main"}"#),
    includedResponse(#"{"default_branch":"trunk"}"#)
  ])
  let client = GitHubCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/gh"),
    runner: runner,
    environment: [:],
    now: { clock.current() }
  )
  let candidate = GitHubRepositoryCandidate(owner: "OpenAI", repository: "codex", projectNames: ["Codex"])

  #expect(try await client.fetchRepositoryMetadata(for: candidate, forceRefresh: false).defaultBranch == "main")
  clock.advance(by: 299)
  #expect(try await client.fetchRepositoryMetadata(for: candidate, forceRefresh: false).defaultBranch == "main")
  clock.advance(by: 2)
  #expect(try await client.fetchRepositoryMetadata(for: candidate, forceRefresh: false).defaultBranch == "trunk")
  #expect(await runner.receivedArguments.count == 2)
}

@Test func surfacesRateLimitsMalformedJSONTransientFailuresAndRedactsCredentials() async throws {
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let candidate = GitHubRepositoryCandidate(owner: "OpenAI", repository: "codex", projectNames: ["Codex"])
  let rateLimited = GitHubCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/gh"),
    runner: FakeGitHubCommandRunner(responses: [
      includedResponse(
        #"{"message":"API rate limit exceeded"}"#,
        statusCode: 403,
        headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1700000120"],
        terminationStatus: 1
      )
    ]),
    environment: [:],
    now: { now }
  )
  do {
    _ = try await rateLimited.fetchRepositoryMetadata(for: candidate, forceRefresh: false)
    Issue.record("Expected rate limit failure")
  } catch let GitHubCLIError.rateLimited(until, message) {
    #expect(until == Date(timeIntervalSince1970: 1_700_000_120))
    #expect(message.contains("retry after"))
  }

  let malformed = GitHubCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/gh"),
    runner: FakeGitHubCommandRunner(responses: [includedResponse("not-json")]),
    environment: [:]
  )
  await #expect(throws: GitHubCLIError.self) {
    try await malformed.fetchRepositoryMetadata(for: candidate, forceRefresh: false)
  }

  let fineGrainedToken = "github" + "_pat_" + "super_secret_credential"
  let legacyToken = "gh" + "p_" + String(repeating: "a", count: 22)
  let credentialMessage = "Authorization: Bearer \(fineGrainedToken) GH_TOKEN=\(legacyToken)"
  let credentialFailure = GitHubCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/gh"),
    runner: FakeGitHubCommandRunner(responses: [commandResult("", error: credentialMessage, status: 1)]),
    environment: [:]
  )
  do {
    _ = try await credentialFailure.fetchRepositoryMetadata(for: candidate, forceRefresh: false)
    Issue.record("Expected credential failure")
  } catch {
    #expect(error.localizedDescription.contains("<redacted>"))
    #expect(!error.localizedDescription.contains("super_secret"))
    #expect(!error.localizedDescription.contains(legacyToken))
  }

  let forbidden = GitHubCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/gh"),
    runner: FakeGitHubCommandRunner(responses: [
      includedResponse(#"{"message":"Resource not accessible"}"#, statusCode: 403, terminationStatus: 1)
    ]),
    environment: [:]
  )
  await #expect(throws: GitHubCLIError.commandFailed(#"{"message":"Resource not accessible"}"#)) {
    try await forbidden.fetchRepositoryMetadata(for: candidate, forceRefresh: false)
  }
}

private actor FakeGitHubCommandRunner: GitHubCommandRunning {
  private var responses: [GitHubCommandResult]
  private(set) var receivedArguments: [[String]] = []
  private(set) var receivedExecutables: [URL] = []

  init(responses: [GitHubCommandResult]) {
    self.responses = responses
  }

  func run(executableURL: URL, arguments: [String]) async throws -> GitHubCommandResult {
    receivedExecutables.append(executableURL)
    receivedArguments.append(arguments)
    guard !responses.isEmpty else { throw FakeGitHubRunnerError.missingResponse }
    return responses.removeFirst()
  }
}

private enum FakeGitHubRunnerError: Error {
  case missingResponse
}

private struct GitHubExecutableFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("portdeck-github-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func makeExecutable(_ relativePath: String) throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private final class LockedGitHubTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) {
    self.date = date
  }

  func current() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return date
  }

  func advance(by interval: TimeInterval) {
    lock.lock()
    date = date.addingTimeInterval(interval)
    lock.unlock()
  }
}

private func commandResult(_ output: String, error: String = "", status: Int32 = 0) -> GitHubCommandResult {
  GitHubCommandResult(stdout: Data(output.utf8), stderr: Data(error.utf8), terminationStatus: status)
}

private func includedResponse(
  _ body: String,
  statusCode: Int = 200,
  headers: [String: String] = [:],
  terminationStatus: Int32 = 0
) -> GitHubCommandResult {
  let reason = statusCode == 200 ? "OK" : "Error"
  let renderedHeaders = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
  let output = "HTTP/2.0 \(statusCode) \(reason)\r\n\(renderedHeaders)\r\n\r\n\(body)"
  return commandResult(output, error: statusCode >= 400 ? body : "", status: terminationStatus)
}

private func workflowPageJSON() -> String {
  """
  {
    "total_count": 1,
    "future_field": true,
    "workflow_runs": [{
      "id": 42,
      "workflow_id": 7,
      "name": "Verify",
      "display_title": "Update README",
      "event": "push",
      "status": "completed",
      "conclusion": "success",
      "head_branch": "feature/primary",
      "run_number": 8,
      "run_attempt": 1,
      "created_at": "2026-07-16T12:00:00Z",
      "updated_at": "2026-07-16T12:04:00Z",
      "html_url": "https://github.com/OpenAI/codex/actions/runs/42",
      "future_run_field": "ignored"
    }]
  }
  """
}
