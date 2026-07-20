import Foundation
import Testing
@testable import PortDeckCore

@Test func fetchesAccountProjectsWithExactReadOnlyCommandAndTelemetryDisabled() async throws {
  let runner = FakeSupabaseCommandRunner(responses: [
    supabaseResult("2.109.1"),
    supabaseResult(projectsJSON())
  ])
  let client = SupabaseCLIClient(
    runner: runner,
    runtimeResolver: StaticSupabaseRuntimeResolver(path: "/portdeck/runtime/supabase"),
    environment: ["PATH": "/usr/bin", "SUPABASE_ACCESS_TOKEN": "inherited-by-cli-only"],
    currentDirectoryURL: URL(fileURLWithPath: "/tmp/portdeck-supabase")
  )

  let projects = try await client.fetchProjects()
  let commands = await runner.receivedCommands

  #expect(projects.map(\.name) == ["Demo"])
  #expect(commands.map(\.arguments) == [
    ["--version"],
    ["projects", "list", "--output-format", "json"]
  ])
  #expect(commands.allSatisfy { $0.executablePath == "/portdeck/runtime/supabase" })
  #expect(commands.allSatisfy { $0.currentDirectory == "/tmp/portdeck-supabase" })
  #expect(commands.allSatisfy { $0.environment["SUPABASE_TELEMETRY_DISABLED"] == "1" })
  #expect(commands.allSatisfy { $0.environment["SUPABASE_ACCESS_TOKEN"] == "inherited-by-cli-only" })
}

@Test func validatesPinnedSupabaseRuntimeOnce() async throws {
  let runner = FakeSupabaseCommandRunner(responses: [
    supabaseResult("2.109.1"),
    supabaseResult(projectsJSON()),
    supabaseResult(projectsJSON())
  ])
  let client = managedSupabaseClient(runner: runner)

  _ = try await client.fetchProjects()
  _ = try await client.fetchProjects()

  #expect(await runner.receivedCommands.map(\.arguments) == [
    ["--version"],
    ["projects", "list", "--output-format", "json"],
    ["projects", "list", "--output-format", "json"]
  ])
}

@Test func rejectsMissingAndNonPinnedSupabaseRuntimes() async {
  let missing = SupabaseCLIClient(
    runner: FakeSupabaseCommandRunner(responses: []),
    runtimeResolver: FailingSupabaseRuntimeResolver()
  )
  await #expect(throws: SupabaseCLIError.missingRuntime) {
    try await missing.fetchProjects()
  }

  for version in ["2.109.0", "2.110.0", "2.109.1-beta.1"] {
    let client = managedSupabaseClient(runner: FakeSupabaseCommandRunner(responses: [supabaseResult(version)]))
    await #expect(throws: SupabaseCLIError.incompatibleRuntime(currentVersion: version)) {
      try await client.fetchProjects()
    }
  }
}

@Test func classifiesAuthenticationRateLimitsMalformedAndTransientFailures() async {
  let authentication = managedSupabaseClient(runner: FakeSupabaseCommandRunner(responses: [
    supabaseResult("2.109.1"),
    supabaseResult(
      #"{"_tag":"Error","error":{"code":"LegacyPlatformAuthRequiredError","message":"Access token not provided. Supply an access token by running `supabase login`."}}"#,
      status: 1
    )
  ]))
  await #expect(throws: SupabaseCLIError.authenticationRequired) {
    try await authentication.fetchProjects()
  }

  let rateLimited = managedSupabaseClient(runner: FakeSupabaseCommandRunner(responses: [
    supabaseResult("2.109.1"),
    supabaseResult("", error: "HTTP 429: Too many requests", status: 1)
  ]))
  await #expect(throws: SupabaseCLIError.rateLimited) {
    try await rateLimited.fetchProjects()
  }

  for malformed in ["not-json", #"{"message":"missing projects"}"#] {
    let client = managedSupabaseClient(runner: FakeSupabaseCommandRunner(responses: [
      supabaseResult("2.109.1"),
      supabaseResult(malformed)
    ]))
    await #expect(throws: SupabaseCLIError.self) {
      try await client.fetchProjects()
    }
  }

  let transient = managedSupabaseClient(runner: FakeSupabaseCommandRunner(responses: [
    supabaseResult("2.109.1"),
    supabaseResult("", error: "Temporary upstream failure", status: 1)
  ]))
  await #expect(throws: SupabaseCLIError.commandFailed("Temporary upstream failure")) {
    try await transient.fetchProjects()
  }
}

@Test func acceptsSuccessfulEmptySupabaseProjectListAndRedactsCredentials() async throws {
  let empty = managedSupabaseClient(runner: FakeSupabaseCommandRunner(responses: [
    supabaseResult("2.109.1"),
    supabaseResult(#"{"projects":[]}"#)
  ]))
  #expect(try await empty.fetchProjects().isEmpty)

  for secret in [
    "SUPABASE_ACCESS_TOKEN=sbp_abcdefghijklmnopqrstuvwxyz0123456789",
    "Authorization: Bearer super-secret-token",
    "eyJabcdefghijk.eyJabcdefghijk.signaturevalue"
  ] {
    let client = managedSupabaseClient(runner: FakeSupabaseCommandRunner(responses: [
      supabaseResult("2.109.1"),
      supabaseResult("", error: secret, status: 1)
    ]))
    do {
      _ = try await client.fetchProjects()
      Issue.record("Expected Supabase command failure")
    } catch {
      #expect(error.localizedDescription.contains("<redacted>"))
      #expect(!error.localizedDescription.contains("super-secret"))
      #expect(!error.localizedDescription.contains("abcdefghijklmnopqrstuvwxyz"))
      #expect(!error.localizedDescription.contains("eyJabcdefghijk"))
    }
  }
}

private actor FakeSupabaseCommandRunner: SupabaseCommandRunning {
  struct ReceivedCommand: Sendable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
    let currentDirectory: String
  }

  private var responses: [SupabaseCommandResult]
  private(set) var receivedCommands: [ReceivedCommand] = []

  init(responses: [SupabaseCommandResult]) {
    self.responses = responses
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> SupabaseCommandResult {
    receivedCommands.append(.init(
      executablePath: executableURL.path,
      arguments: arguments,
      environment: environment,
      currentDirectory: currentDirectoryURL.path
    ))
    guard !responses.isEmpty else { throw FakeSupabaseRunnerError.missingResponse }
    return responses.removeFirst()
  }
}

private struct StaticSupabaseRuntimeResolver: SupabaseRuntimeResolving {
  let path: String
  func resolveExecutableURL() throws -> URL { URL(fileURLWithPath: path) }
}

private struct FailingSupabaseRuntimeResolver: SupabaseRuntimeResolving {
  func resolveExecutableURL() throws -> URL { throw SupabaseCLIError.missingRuntime }
}

private enum FakeSupabaseRunnerError: Error { case missingResponse }

private func managedSupabaseClient(runner: FakeSupabaseCommandRunner) -> SupabaseCLIClient {
  SupabaseCLIClient(
    runner: runner,
    runtimeResolver: StaticSupabaseRuntimeResolver(path: "/portdeck/runtime/supabase"),
    environment: [:],
    currentDirectoryURL: URL(fileURLWithPath: "/tmp/portdeck-supabase")
  )
}

private func supabaseResult(_ output: String, error: String = "", status: Int32 = 0) -> SupabaseCommandResult {
  SupabaseCommandResult(stdout: Data(output.utf8), stderr: Data(error.utf8), terminationStatus: status)
}

private func projectsJSON() -> String {
  #"{"message":"","projects":[{"id":"abcdefghijklmnopqrst","ref":"abcdefghijklmnopqrst","name":"Demo","organization_id":"org-id","organization_slug":"demo-org","region":"us-east-1","status":"ACTIVE_HEALTHY","created_at":"2026-05-27T01:02:03.123Z","database":{"host":"ignored"},"linked":false}]}"#
}
