import Foundation
import Testing
@testable import PortDeckCore

@Test func fetchesFlySnapshotWithExactReadOnlyCommandsAndNarrowFields() async throws {
  let runner = FixtureFlyRunner(fixtures: standardFlyFixtures())
  let client = makeFlyClient(
    runner: runner,
    environment: sensitiveFlyEnvironment()
  )

  let snapshot = try await client.fetchSnapshot()
  let app = try #require(snapshot.apps.first)
  let machine = try #require(app.machines.first)
  let release = try #require(app.latestRelease)
  let commands = await runner.receivedCommands

  #expect(snapshot.organizations == [FlyOrganization(slug: "demo-team", name: "Demo Team")])
  #expect(app.id == "app-1")
  #expect(app.name == "demo-api")
  #expect(app.currentReleaseVersion == 8)
  #expect(machine.id == "machine-1")
  #expect(machine.checks.first?.name == "readiness")
  #expect(release.version == 8)
  #expect(release.description == "Ship demo")
  #expect(snapshot.successfulStatusAppKeys == [app.identityKey])
  #expect(snapshot.successfulReleaseAppKeys == [app.identityKey])

  #expect(commands.prefix(4).map(\.arguments) == [
    ["version", "--json"],
    ["auth", "whoami", "--json"],
    ["orgs", "list", "--json"],
    ["apps", "list", "--json"]
  ])
  #expect(Set(commands.dropFirst(4).map(\.arguments)) == Set([
    ["status", "--app", "demo-api", "--json"],
    ["releases", "--app", "demo-api", "--json"]
  ]))
  #expect(commands.allSatisfy { !$0.arguments.contains("--config") })
  #expect(commands.allSatisfy { $0.currentDirectory == "/tmp/portdeck-fly-tests" })
  for key in sensitiveFlyEnvironment().keys where key.hasPrefix("FLY_") {
    if ["FLY_SEND_METRICS"].contains(key) { continue }
    #expect(commands.allSatisfy { $0.environment[key] == nil })
  }
  #expect(commands.allSatisfy { $0.environment["FLY_SEND_METRICS"] == "0" })
  #expect(commands.allSatisfy { $0.environment["DO_NOT_TRACK"] == "1" })
  #expect(commands.allSatisfy { $0.environment["NO_COLOR"] == "1" })
}

@Test func validatesExactFlyVersionOnceAndRejectsWrongIdentityVersionOSOrArchitecture() async throws {
  let runner = FixtureFlyRunner(fixtures: standardFlyFixtures())
  let client = makeFlyClient(runner: runner)
  _ = try await client.fetchSnapshot()
  _ = try await client.fetchSnapshot()
  #expect(await runner.receivedCommands.filter { $0.arguments == ["version", "--json"] }.count == 1)

  let invalidVersions = [
    flyVersionJSON(name: "fly", version: "0.4.71", os: "darwin", architecture: "arm64"),
    flyVersionJSON(name: "flyctl", version: "0.4.70", os: "darwin", architecture: "arm64"),
    flyVersionJSON(name: "flyctl", version: "0.4.71", os: "linux", architecture: "arm64"),
    flyVersionJSON(name: "flyctl", version: "0.4.71", os: "darwin", architecture: "riscv64")
  ]
  for output in invalidVersions {
    let invalid = makeFlyClient(runner: FixtureFlyRunner(fixtures: ["version --json": output]))
    await #expect(throws: FlyCLIError.self) { try await invalid.fetchSnapshot() }
  }

  let malformed = makeFlyClient(runner: FixtureFlyRunner(fixtures: ["version --json": "not-json"]))
  await #expect(throws: FlyCLIError.malformedOutput("Could not parse the Fly runtime version.")) {
    try await malformed.fetchSnapshot()
  }
}

@Test func classifiesFlyFailuresAndRedactsCredentialShapes() async {
  let authentication = makeFlyClient(runner: FixtureFlyRunner(fixtures: [
    "version --json": flyVersionJSON(),
    "auth whoami --json": "__ERROR__Error: not logged in. Run flyctl auth login"
  ]))
  await #expect(throws: FlyCLIError.authenticationRequired) { try await authentication.fetchSnapshot() }

  let rateLimit = makeFlyClient(runner: FixtureFlyRunner(fixtures: [
    "version --json": flyVersionJSON(), "auth whoami --json": identityJSON,
    "orgs list --json": "__ERROR__HTTP 429: Too many requests"
  ]))
  await #expect(throws: FlyCLIError.rateLimited) { try await rateLimit.fetchSnapshot() }

  let transient = makeFlyClient(runner: FixtureFlyRunner(fixtures: [
    "version --json": flyVersionJSON(), "auth whoami --json": identityJSON,
    "orgs list --json": "__ERROR__503 Service Unavailable"
  ]))
  await #expect(throws: FlyCLIError.transientFailure) { try await transient.fetchSnapshot() }

  let secret = makeFlyClient(runner: FixtureFlyRunner(fixtures: [
    "version --json": flyVersionJSON(),
    "auth whoami --json": "__ERROR__FLY_API_TOKEN=super-secret Authorization: Bearer hidden-token token=credential eyJabcdefghijk.eyJabcdefghijk.signaturevalue FlyV1 fm2_abcdefghijklmnopqrstuv"
  ]))
  do {
    _ = try await secret.fetchSnapshot()
    Issue.record("Expected Fly command failure")
  } catch {
    let message = error.localizedDescription
    #expect(message.contains("<redacted>"))
    for value in ["super-secret", "hidden-token", "credential", "eyJabcdefghijk", "fm2_abcdefghijklmnopqrstuv"] {
      #expect(!message.contains(value))
    }
  }
}

@Test func preservesScopedFlyFailuresAndSelectsNewestUsableRelease() async throws {
  var fixtures = standardFlyFixtures()
  fixtures["releases --app demo-api --json"] = """
  [
    {"ID":"release-7","Version":7,"Status":"complete","Description":"Old","CreatedAt":"2026-07-15T00:00:00Z","User":{"Email":"ignored@example.com"},"ImageRef":"registry/secret"},
    {"ID":"release-9","Version":9,"Status":"running","Description":"Newest","CreatedAt":"2026-07-17T00:00:00Z","User":{"Email":"ignored@example.com"}},
    {"ID":"","Version":10,"Status":"complete","Description":"Unusable","CreatedAt":"2026-07-18T00:00:00Z"}
  ]
  """
  let snapshot = try await makeFlyClient(runner: FixtureFlyRunner(fixtures: fixtures)).fetchSnapshot()
  #expect(snapshot.apps.first?.latestRelease?.version == 9)

  fixtures["status --app demo-api --json"] = "__ERROR__Temporary app failure"
  let partial = try await makeFlyClient(runner: FixtureFlyRunner(fixtures: fixtures)).fetchSnapshot()
  #expect(partial.apps.count == 1)
  #expect(partial.apps.first?.machines.isEmpty == true)
  #expect(partial.failures.count == 1)
  #expect(partial.successfulReleaseAppKeys.count == 1)
  #expect(partial.successfulStatusAppKeys.isEmpty)
}

@Test func limitsAllFlyAppScopedCommandsToFourConcurrentRequests() async throws {
  var fixtures: [String: String] = [
    "version --json": flyVersionJSON(), "auth whoami --json": identityJSON,
    "orgs list --json": #"{"demo-team":"Demo Team"}"#
  ]
  let rows = (1...8).map { index in
    fixtures["status --app app-\(index) --json"] = flyStatusJSON(id: "app-\(index)", name: "app-\(index)", machines: "[]")
    fixtures["releases --app app-\(index) --json"] = "[]"
    return flyAppListRow(id: "app-\(index)", name: "app-\(index)")
  }
  fixtures["apps list --json"] = "[\(rows.joined(separator: ","))]"
  let runner = FixtureFlyRunner(fixtures: fixtures, scopedDelay: .milliseconds(15))
  _ = try await makeFlyClient(runner: runner).fetchSnapshot()
  #expect(await runner.maximumActiveScopedCommands == 4)
}

@Test func systemFlyRunnerUsesSecureFilesDiscardsSuccessfulStderrAndTerminatesOnCancellation() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("portdeck-fly-runner-tests-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

  let permissionScript = try makeExecutable(at: root.appendingPathComponent("permissions"), source: """
  #!/bin/sh
  printf 'DIR=%s\\n' "$(stat -f %Lp "$PWD")"
  for file in "$PWD"/command-*; do printf 'FILE=%s\\n' "$(stat -f %Lp "$file")"; done
  printf 'discard me' >&2
  """)
  let privateDirectory = root.appendingPathComponent("private")
  let result = try await SystemFlyCommandRunner().run(
    executableURL: permissionScript, arguments: [], environment: [:], currentDirectoryURL: privateDirectory
  )
  let stdout = String(decoding: result.stdout, as: UTF8.self)
  #expect(stdout.contains("DIR=700"))
  #expect(stdout.split(separator: "\n").filter { $0 == "FILE=600" }.count == 2)
  #expect(result.stderr.isEmpty)
  #expect((try FileManager.default.contentsOfDirectory(atPath: privateDirectory.path)).isEmpty)

  let blockingScript = try makeExecutable(at: root.appendingPathComponent("blocking"), source: """
  #!/bin/sh
  while :; do sleep 0.05; done
  """)
  let task = Task {
    try await SystemFlyCommandRunner().run(
      executableURL: blockingScript, arguments: [], environment: [:],
      currentDirectoryURL: root.appendingPathComponent("cancel-private")
    )
  }
  try await Task.sleep(for: .milliseconds(80))
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
}

private let identityJSON = #"{"email":"ignored@example.com"}"#

private func standardFlyFixtures() -> [String: String] {
  [
    "version --json": flyVersionJSON(),
    "auth whoami --json": identityJSON,
    "orgs list --json": #"{"demo-team":"Demo Team"}"#,
    "apps list --json": "[\(flyAppListRow(id: "app-1", name: "demo-api"))]",
    "status --app demo-api --json": flyStatusJSON(id: "app-1", name: "demo-api", machines: """
    [{
      "id":"machine-1","name":"blue-sun","state":"started","region":"ord","host_status":"ok",
      "updated_at":"2026-07-16T12:34:56Z","private_ip":"fdaa::1","image_ref":{"registry":"secret"},
      "config":{"env":{"SECRET":"ignored"}},"events":[{"type":"ignored"}],
      "checks":[{"name":"readiness","status":"passing","output":"private output","updated_at":"2026-07-16T12:35:00Z"}]
    }]
    """),
    "releases --app demo-api --json": """
    [
      {"ID":"release-7","Version":7,"Status":"complete","Description":"Old","CreatedAt":"2026-07-15T00:00:00Z"},
      {"ID":"release-8","Version":8,"Status":"complete","Description":"Ship demo","CreatedAt":"2026-07-16T12:34:56Z","User":{"Email":"ignored@example.com"},"ImageRef":"registry/secret"}
    ]
    """
  ]
}

private func flyVersionJSON(
  name: String = "flyctl", version: String = "0.4.71", os: String = "darwin", architecture: String = "arm64"
) -> String {
  #"{"Name":"\#(name)","Version":"\#(version)","Commit":"ignored","BuildDate":"ignored","OS":"\#(os)","Architecture":"\#(architecture)","Environment":"production"}"#
}

private func flyAppListRow(id: String, name: String) -> String {
  #"{"ID":"\#(id)","Name":"\#(name)","Status":"deployed","Deployed":true,"Hostname":"\#(name).fly.dev","AppURL":"https://\#(name).fly.dev","Organization":{"Slug":"demo-team","Name":"Demo Team"},"CurrentRelease":{"Status":"complete","User":{"Email":"ignored@example.com"}}}"#
}

private func flyStatusJSON(id: String, name: String, machines: String) -> String {
  """
  {"ID":"\(id)","Name":"\(name)","Deployed":true,"Status":"deployed","Hostname":"\(name).fly.dev","Version":8,"AppURL":"https://\(name).fly.dev","Organization":{"Slug":"demo-team","Name":"Demo Team"},"PlatformVersion":"machines","Machines":\(machines)}
  """
}

private func sensitiveFlyEnvironment() -> [String: String] {
  [
    "PATH": "/usr/bin", "FLY_ACCESS_TOKEN": "secret", "FLY_API_TOKEN": "secret",
    "FLY_METRICS_TOKEN": "secret", "FLY_ORG": "secret", "FLY_ORGANIZATION": "secret",
    "FLY_REGION": "secret", "FLY_APP": "secret", "FLY_API_BASE_URL": "secret",
    "FLY_FLAPS_BASE_URL": "secret", "FLY_METRICS_BASE_URL": "secret",
    "FLY_SYNTHETICS_BASE_URL": "secret", "FLY_REGISTRY_HOST": "secret",
    "FLY_JSON": "secret", "FLY_VERBOSE": "secret", "FLY_LOG_GQL_ERRORS": "secret"
  ]
}

private func makeFlyClient(
  runner: FixtureFlyRunner,
  environment: [String: String] = [:]
) -> FlyCLIClient {
  FlyCLIClient(
    runner: runner, runtimeResolver: StaticFlyRuntimeResolver(), environment: environment,
    currentDirectoryURL: URL(fileURLWithPath: "/tmp/portdeck-fly-tests")
  )
}

private struct StaticFlyRuntimeResolver: FlyRuntimeResolving {
  func resolveExecutableURL() throws -> URL { URL(fileURLWithPath: "/portdeck/runtime/flyctl") }
}

private actor FixtureFlyRunner: FlyCommandRunning {
  struct ReceivedCommand: Sendable {
    let arguments: [String]
    let environment: [String: String]
    let currentDirectory: String
  }

  let fixtures: [String: String]
  let scopedDelay: Duration
  private(set) var receivedCommands: [ReceivedCommand] = []
  private var activeScopedCommands = 0
  private(set) var maximumActiveScopedCommands = 0

  init(fixtures: [String: String], scopedDelay: Duration = .zero) {
    self.fixtures = fixtures
    self.scopedDelay = scopedDelay
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> FlyCommandResult {
    receivedCommands.append(.init(
      arguments: arguments, environment: environment, currentDirectory: currentDirectoryURL.path
    ))
    let key = arguments.joined(separator: " ")
    let scoped = arguments.first == "status" || arguments.first == "releases"
    if scoped {
      activeScopedCommands += 1
      maximumActiveScopedCommands = max(maximumActiveScopedCommands, activeScopedCommands)
      if scopedDelay != .zero { try await Task.sleep(for: scopedDelay) }
      activeScopedCommands -= 1
    }
    guard let fixture = fixtures[key] else {
      return FlyCommandResult(stdout: Data(), stderr: Data("Missing fixture for \(key)".utf8), terminationStatus: 1)
    }
    if fixture.hasPrefix("__ERROR__") {
      return FlyCommandResult(stdout: Data(), stderr: Data(fixture.dropFirst(9).utf8), terminationStatus: 1)
    }
    return FlyCommandResult(stdout: Data(fixture.utf8), terminationStatus: 0)
  }
}

private func makeExecutable(at url: URL, source: String) throws -> URL {
  FileManager.default.createFile(atPath: url.path, contents: Data(source.utf8))
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  return url
}
