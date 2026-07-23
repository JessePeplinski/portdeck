import Foundation
import Testing
@testable import PortDeckCore

@Test func fetchesRailwaySnapshotWithExactReadOnlyScopesAndMinimalFields() async throws {
  let runner = FixtureRailwayRunner(fixtures: standardFixtures())
  let client = makeRailwayClient(
    runner: runner,
    environment: [
      "PATH": "/usr/bin",
      "RAILWAY_TOKEN": "must-not-leak",
      "RAILWAY_API_TOKEN": "must-not-leak-either"
    ]
  )

  let snapshot = try await client.fetchSnapshot()
  let project = try #require(snapshot.projects.first)
  let service = try #require(project.services.first)
  let commands = await runner.receivedCommands

  #expect(project.name == "Demo")
  #expect(project.workspace.name == "Demo Team")
  #expect(project.productionEnvironmentID == "environment-1")
  #expect(service.name == "API")
  #expect(service.latestDeployment?.branch == "main")
  #expect(service.latestDeployment?.commitSHA == "abcdef123456")
  #expect(service.latestDeployment?.commitMessage == "Ship API")
  #expect(service.regions.first?.location == "US East")
  #expect(service.replicas?.running == 1)
  #expect(service.productionURL?.absoluteString == "https://api.example")
  #expect(snapshot.successfulProjectIDs == ["project-1"])

  #expect(commands.map(\.arguments) == [
    ["--version"],
    ["whoami", "--json"],
    ["list", "--json"],
    ["service", "list", "--project", "project-1", "--environment", "production", "--json"],
    ["deployment", "list", "--project", "project-1", "--environment", "production", "--service", "service-1", "--limit", "1", "--json"]
  ])
  #expect(commands.allSatisfy { $0.environment["RAILWAY_TOKEN"] == nil })
  #expect(commands.allSatisfy { $0.environment["RAILWAY_API_TOKEN"] == nil })
  #expect(commands.allSatisfy { $0.environment["RAILWAY_NO_TELEMETRY"] == "1" })
  #expect(commands.allSatisfy { $0.environment["DO_NOT_TRACK"] == "1" })
  #expect(commands.allSatisfy { $0.currentDirectory == "/tmp/portdeck-railway-tests" })
  #expect(!commands.contains { $0.arguments.contains("status") || $0.arguments.contains("link") })
}

@Test func validatesRailwayVersionRangeOnceAndRejectsUnsupportedCLIs() async throws {
  let runner = FixtureRailwayRunner(fixtures: standardFixtures())
  let client = makeRailwayClient(runner: runner)
  _ = try await client.fetchSnapshot()
  _ = try await client.fetchSnapshot()
  #expect(await runner.receivedCommands.filter { $0.arguments == ["--version"] }.count == 1)

  for output in ["railway 5.26.1", "railway 6.0.0", "railway 5.26.2-beta.1"] {
    let incompatible = makeRailwayClient(runner: FixtureRailwayRunner(fixtures: ["--version": output]))
    await #expect(throws: RailwayCLIError.unsupportedCLI(currentVersion: output)) {
      try await incompatible.fetchSnapshot()
    }
  }
}

@Test func classifiesAuthenticationRateLimitsMalformedResponsesAndRedactsSecrets() async {
  let authentication = makeRailwayClient(runner: FixtureRailwayRunner(fixtures: [
    "--version": "railway 5.26.2",
    "whoami --json": "__ERROR__Warning: invalid_grant. Unauthorized. Please run `railway login` again."
  ]))
  await #expect(throws: RailwayCLIError.authenticationRequired) { try await authentication.fetchSnapshot() }

  let rateLimit = makeRailwayClient(runner: FixtureRailwayRunner(fixtures: [
    "--version": "railway 5.26.2",
    "whoami --json": identityJSON,
    "list --json": "__ERROR__HTTP 429: Too many requests"
  ]))
  await #expect(throws: RailwayCLIError.rateLimited) { try await rateLimit.fetchSnapshot() }

  let malformed = makeRailwayClient(runner: FixtureRailwayRunner(fixtures: [
    "--version": "railway 5.26.2", "whoami --json": identityJSON, "list --json": "not-json"
  ]))
  await #expect(throws: RailwayCLIError.invalidResponse("Could not parse Railway projects.")) {
    try await malformed.fetchSnapshot()
  }

  let secret = makeRailwayClient(runner: FixtureRailwayRunner(fixtures: [
    "--version": "railway 5.26.2",
    "whoami --json": "__ERROR__RAILWAY_API_TOKEN=super-secret-value Authorization: Bearer hidden-token eyJabcdefghijk.eyJabcdefghijk.signaturevalue"
  ]))
  do {
    _ = try await secret.fetchSnapshot()
    Issue.record("Expected Railway command failure")
  } catch {
    #expect(error.localizedDescription.contains("<redacted>"))
    #expect(!error.localizedDescription.contains("super-secret-value"))
    #expect(!error.localizedDescription.contains("hidden-token"))
    #expect(!error.localizedDescription.contains("eyJabcdefghijk"))
  }
}

@Test func preservesProjectsWithoutProductionAndCapturesScopedPartialFailures() async throws {
  var fixtures = standardFixtures()
  fixtures["list --json"] = """
  [
    {"id":"project-1","name":"Demo","deletedAt":null,"workspace":{"id":"workspace-1","name":"Demo Team"},"environments":{"edges":[{"node":{"id":"environment-1","name":"production","canAccess":true}}]}},
    {"id":"project-2","name":"No Production","deletedAt":null,"workspace":{"id":"workspace-1","name":"Demo Team"},"environments":{"edges":[{"node":{"id":"environment-2","name":"staging","canAccess":true}}]}}
  ]
  """
  fixtures["service list --project project-1 --environment production --json"] = "__ERROR__Temporary upstream failure"
  let snapshot = try await makeRailwayClient(runner: FixtureRailwayRunner(fixtures: fixtures)).fetchSnapshot()

  #expect(snapshot.projects.count == 2)
  #expect(snapshot.successfulProjectIDs == ["project-2"])
  #expect(snapshot.failures.count == 1)
  #expect(snapshot.projects.first { $0.id == "project-2" }?.productionState == .unavailable)
}

@Test func limitsScopedRailwayCommandsToFourConcurrentRequests() async throws {
  var fixtures: [String: String] = ["--version": "railway 5.26.2", "whoami --json": identityJSON]
  let projectRows = (1...8).map { index in
    fixtures["service list --project project-\(index) --environment production --json"] = "[]"
    return "{\"id\":\"project-\(index)\",\"name\":\"Project \(index)\",\"deletedAt\":null,\"workspace\":{\"id\":\"workspace-1\",\"name\":\"Demo Team\"},\"environments\":{\"edges\":[{\"node\":{\"id\":\"environment-\(index)\",\"name\":\"production\",\"canAccess\":true}}]}}"
  }
  fixtures["list --json"] = "[\(projectRows.joined(separator: ","))]"
  let runner = FixtureRailwayRunner(fixtures: fixtures, scopedDelayNanoseconds: 15_000_000)
  _ = try await makeRailwayClient(runner: runner).fetchSnapshot()
  #expect(await runner.maximumActiveScopedCommands == 4)
}

@Test func systemRailwayRunnerUsesPrivateWorkingDirectoryAndSecureSeparateOutputFiles() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("portdeck-railway-runner-test-\(UUID().uuidString)")
  let script = root.appendingPathComponent("fixture")
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let source = """
  #!/bin/sh
  printf 'DIR=%s\\n' "$(stat -f %Lp "$PWD")"
  for file in "$PWD"/command-*; do
    printf 'FILE=%s\\n' "$(stat -f %Lp "$file")"
  done
  printf 'separate stderr' >&2
  """
  FileManager.default.createFile(atPath: script.path, contents: Data(source.utf8))
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

  let result = try await SystemRailwayCommandRunner().run(
    executableURL: script,
    arguments: [],
    environment: [:],
    currentDirectoryURL: root.appendingPathComponent("private")
  )
  let stdout = String(decoding: result.stdout, as: UTF8.self)
  #expect(stdout.contains("DIR=700"))
  #expect(stdout.split(separator: "\n").filter { $0 == "FILE=600" }.count == 2)
  #expect(String(decoding: result.stderr, as: UTF8.self) == "separate stderr")
}

private let identityJSON = #"{"name":"Ignored","email":"ignored@example.com","workspaces":[{"id":"workspace-1","name":"Demo Team"}]}"#

private func standardFixtures() -> [String: String] {
  [
    "--version": "railway 5.26.2",
    "whoami --json": identityJSON,
    "list --json": #"[{"id":"project-1","name":"Demo","createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-16T00:00:00Z","deletedAt":null,"workspace":{"id":"workspace-1","name":"Demo Team"},"environments":{"edges":[{"node":{"id":"environment-1","name":"production","canAccess":true}}]},"services":{"edges":[{"node":{"id":"service-1","name":"API"}}]}}]"#,
    "service list --project project-1 --environment production --json": #"[{"id":"service-1","name":"API","isLinked":false,"source":{"repo":"demo/repo","image":null},"status":"SUCCESS","deploymentStopped":false,"deploymentId":"deployment-1","latestDeployment":{"id":"deployment-1","status":"SUCCESS","createdAt":"2026-07-16T12:34:56.123Z","deploymentStopped":false},"url":"https://api.example","volumes":[{"name":"ignored"}],"regions":[{"name":"us-east4-eqdc4a","location":"US East","configured":1}],"replicas":{"configured":1,"running":1,"crashed":0,"exited":0,"total":1},"volumeMigrating":false}]"#,
    "deployment list --project project-1 --environment production --service service-1 --limit 1 --json": #"[{"id":"deployment-1","status":"SUCCESS","createdAt":"2026-07-16T12:34:56.123Z","meta":{"branch":"main","commitHash":"abcdef123456","commitMessage":"Ship API","startCommand":"ignored","variables":{"SECRET":"ignored"}}}]"#
  ]
}

private func makeRailwayClient(
  runner: FixtureRailwayRunner,
  environment: [String: String] = [:]
) -> RailwayCLIClient {
  RailwayCLIClient(
    runner: runner,
    runtimeResolver: StaticRailwayRuntimeResolver(),
    environment: environment,
    currentDirectoryURL: URL(fileURLWithPath: "/tmp/portdeck-railway-tests")
  )
}

private struct StaticRailwayRuntimeResolver: RailwayRuntimeResolving {
  func resolveExecutableURL() throws -> URL { URL(fileURLWithPath: "/portdeck/runtime/railway") }
}

private actor FixtureRailwayRunner: RailwayCommandRunning {
  struct ReceivedCommand: Sendable {
    let arguments: [String]
    let environment: [String: String]
    let currentDirectory: String
  }

  let fixtures: [String: String]
  let scopedDelayNanoseconds: UInt64
  private(set) var receivedCommands: [ReceivedCommand] = []
  private var activeScopedCommands = 0
  private(set) var maximumActiveScopedCommands = 0

  init(fixtures: [String: String], scopedDelayNanoseconds: UInt64 = 0) {
    self.fixtures = fixtures
    self.scopedDelayNanoseconds = scopedDelayNanoseconds
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> RailwayCommandResult {
    receivedCommands.append(.init(arguments: arguments, environment: environment, currentDirectory: currentDirectoryURL.path))
    let key = arguments.joined(separator: " ")
    let scoped = arguments.starts(with: ["service", "list"]) || arguments.starts(with: ["deployment", "list"])
    if scoped {
      activeScopedCommands += 1
      maximumActiveScopedCommands = max(maximumActiveScopedCommands, activeScopedCommands)
      if scopedDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: scopedDelayNanoseconds) }
      activeScopedCommands -= 1
    }
    guard let fixture = fixtures[key] else {
      return RailwayCommandResult(stdout: Data(), stderr: Data("Missing fixture for \(key)".utf8), terminationStatus: 1)
    }
    if fixture.hasPrefix("__ERROR__") {
      return RailwayCommandResult(stdout: Data(), stderr: Data(fixture.dropFirst(9).utf8), terminationStatus: 1)
    }
    return RailwayCommandResult(stdout: Data(fixture.utf8), terminationStatus: 0)
  }
}
