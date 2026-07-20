import Foundation
import Testing
@testable import PortDeckCore

@Test func fetchesNetlifySnapshotWithExactReadOnlyCommandsScopesAndNarrowFields() async throws {
  let runner = FixtureNetlifyRunner(fixtures: standardNetlifyFixtures())
  let client = makeNetlifyClient(runner: runner, environment: sensitiveNetlifyEnvironment())

  let snapshot = try await client.fetchSnapshot()
  let site = try #require(snapshot.sites.first)
  let deployment = try #require(site.latestDeployment)
  let commands = await runner.receivedCommands

  #expect(site.id == "site-1")
  #expect(site.name == "demo-site")
  #expect(site.account == NetlifyAccount(id: "account-1", name: "Demo Team", slug: "demo-team"))
  #expect(site.productionURLString == "https://demo-site.netlify.app")
  #expect(site.dashboardURLString == "https://app.netlify.com/sites/demo-site")
  #expect(deployment.id == "deploy-1")
  #expect(deployment.siteID == "site-1")
  #expect(deployment.rawState == "ready")
  #expect(deployment.branch == "main")
  #expect(deployment.shortCommitReference == "abcdef12")
  #expect(snapshot.successfulDeploymentSiteIDs == ["site-1"])
  #expect(snapshot.failures.isEmpty)

  #expect(commands.map(\.arguments) == [
    ["--version"],
    ["sites:list", "--json"],
    ["api", "listSiteDeploys", "--data", deploymentPayload("site-1")]
  ])
  #expect(commands.allSatisfy { $0.currentDirectory == "/tmp/portdeck-netlify-tests" })
  for key in sensitiveNetlifyEnvironment().keys where key != "PATH" && key != "HOME" {
    #expect(commands.allSatisfy { $0.environment[key] == nil || ["CI", "NO_UPDATE_NOTIFIER", "NO_COLOR", "FORCE_COLOR"].contains(key) })
  }
  #expect(commands.allSatisfy { $0.environment["CI"] == "1" })
  #expect(commands.allSatisfy { $0.environment["NO_UPDATE_NOTIFIER"] == "1" })
  #expect(commands.allSatisfy { $0.environment["NO_COLOR"] == "1" })
  #expect(commands.allSatisfy { $0.environment["FORCE_COLOR"] == "0" })
  #expect(commands.allSatisfy { $0.environment["HOME"] == "/Users/tester" })
}

@Test func validatesExactNetlifyIdentityVersionDarwinArchitectureAndNodeOnce() async throws {
  let runner = FixtureNetlifyRunner(fixtures: standardNetlifyFixtures())
  let client = makeNetlifyClient(runner: runner)
  let evidence = try await client.runtimeEvidence()
  _ = try await client.fetchSnapshot()
  _ = try await client.fetchSnapshot()

  #expect(evidence == NetlifyRuntimeEvidence(
    cliVersion: "26.2.0", operatingSystem: "darwin", architecture: "arm64", nodeVersion: "20.12.2"
  ))
  #expect(await runner.receivedCommands.filter { $0.arguments == ["--version"] }.count == 1)

  for output in [
    "netlify/26.2.0 darwin-arm64 node-v20.12.2",
    "netlify-cli/26.1.0 darwin-arm64 node-v20.12.2",
    "netlify-cli/26.2.0 linux-arm64 node-v20.12.2",
    "netlify-cli/26.2.0 darwin-riscv64 node-v20.12.2",
    "netlify-cli/26.2.0 darwin-arm64 node-v20.12.1"
  ] {
    #expect(throws: NetlifyCLIError.self) { try NetlifyCLIClient.parseRuntimeEvidence(output) }
  }
  #expect(try NetlifyCLIClient.parseRuntimeEvidence("netlify-cli/26.2.0 darwin-x64 node-v22.0.0").architecture == "x64")
}

@Test func netlifyAllowlistRejectsEveryMutationAndUnscopedDeploymentShape() throws {
  try NetlifyCommandAllowlist.validate(["--version"])
  try NetlifyCommandAllowlist.validate(["sites:list", "--json"])
  try NetlifyCommandAllowlist.validate(["api", "listSiteDeploys", "--data", deploymentPayload("site-1")])

  for arguments in [
    ["login"], ["logout"], ["link"], ["unlink"], ["switch"], ["deploy"], ["open"],
    ["api", "cancelSiteDeploy", "--data", #"{"deploy_id":"deploy-1"}"#],
    ["api", "listSiteDeploys", "--data", #"{"production":true,"per_page":1}"#],
    ["api", "listSiteDeploys", "--data", #"{"site_id":"site-1","production":false,"per_page":1}"#],
    ["api", "listSiteDeploys", "--data", #"{"site_id":"site-1","production":true,"per_page":2}"#],
    ["api", "listSiteDeploys", "--data", #"{"site_id":"site-1","production":true,"per_page":1,"state":"ready"}"#]
  ] {
    #expect(throws: NetlifyCLIError.unsafeCommand) { try NetlifyCommandAllowlist.validate(arguments) }
  }
}

@Test func decodesUnknownStatesRejectsUnsafeLinksAndIgnoresSensitiveFields() async throws {
  var fixtures = standardNetlifyFixtures()
  fixtures["sites:list --json"] = """
  [{
    "id":"site-1","name":"demo-site","ssl_url":"http://unsafe.example","admin_url":"https://evil.example/sites/demo-site",
    "account_id":"account-1","account_name":"Demo Team","account_slug":"demo-team",
    "notification_email":"private@example.com","user_id":"user-secret","password":"secret",
    "build_settings":{"env":{"SECRET":"ignored"},"cmd":"private build"},"published_deploy":{"skew_protection_token":"ignored"}
  }]
  """
  fixtures[deploymentKey("site-1")] = """
  [{
    "id":"deploy-1","site_id":"site-1","state":"future_state","deploy_ssl_url":"https://preview.example.com",
    "admin_url":"https://evil.example/sites/demo/deploys/deploy-1","created_at":"2026-07-16T12:00:00.123Z",
    "branch":"main","commit_ref":"abcdef1234567890","title":"Future deploy","error_message":"bounded",
    "user_id":"private-user","screenshot_url":"https://private.example/screenshot.png","skew_protection_token":"secret",
    "required":["private-file"],"function_schedules":[{"name":"secret","cron":"* * * * *"}]
  }]
  """

  let snapshot = try await makeNetlifyClient(runner: FixtureNetlifyRunner(fixtures: fixtures)).fetchSnapshot()
  let site = try #require(snapshot.sites.first)
  let deployment = try #require(site.latestDeployment)
  #expect(site.productionURL == nil)
  #expect(site.dashboardURLString == "https://app.netlify.com/sites/demo-site")
  #expect(deployment.state == .unknown)
  #expect(deployment.dashboardURLString == "https://app.netlify.com/sites/demo-site/deploys/deploy-1")
  #expect(deployment.createdAt != nil)
}

@Test func classifiesNetlifyFailuresAndRedactsCredentialShapes() async {
  let authentication = makeNetlifyClient(runner: FixtureNetlifyRunner(fixtures: [
    "--version": netlifyVersion(),
    "sites:list --json": "__ERROR__Authentication required. Run netlify login"
  ]))
  await #expect(throws: NetlifyCLIError.authenticationRequired) { try await authentication.fetchSnapshot() }

  let rateLimited = makeNetlifyClient(runner: FixtureNetlifyRunner(fixtures: [
    "--version": netlifyVersion(), "sites:list --json": "__ERROR__HTTP 429 Too many requests"
  ]))
  await #expect(throws: NetlifyCLIError.rateLimited) { try await rateLimited.fetchSnapshot() }

  let transient = makeNetlifyClient(runner: FixtureNetlifyRunner(fixtures: [
    "--version": netlifyVersion(), "sites:list --json": "__ERROR__503 Service Unavailable"
  ]))
  await #expect(throws: NetlifyCLIError.transientFailure) { try await transient.fetchSnapshot() }

  let secret = makeNetlifyClient(runner: FixtureNetlifyRunner(fixtures: [
    "--version": netlifyVersion(),
    "sites:list --json": "__ERROR__NETLIFY_AUTH_TOKEN=super-secret Authorization: Bearer hidden-token token=credential nfp_abcdefghijklmnopqrstuv"
  ]))
  do {
    _ = try await secret.fetchSnapshot()
    Issue.record("Expected Netlify command failure")
  } catch {
    let message = error.localizedDescription
    #expect(message.contains("<redacted>"))
    for value in ["super-secret", "hidden-token", "credential", "nfp_abcdefghijklmnopqrstuv"] {
      #expect(!message.contains(value))
    }
  }
}

@Test func preservesScopedNetlifyFailuresAndLegitimateEmptyDeployments() async throws {
  var fixtures = standardNetlifyFixtures()
  fixtures["sites:list --json"] = "[\(siteJSON(id: "site-1", name: "one")),\(siteJSON(id: "site-2", name: "two"))]"
  fixtures[deploymentKey("site-1")] = "[]"
  fixtures[deploymentKey("site-2")] = "__ERROR__Temporary deployment failure"
  let snapshot = try await makeNetlifyClient(runner: FixtureNetlifyRunner(fixtures: fixtures)).fetchSnapshot()

  #expect(snapshot.sites.count == 2)
  #expect(snapshot.successfulDeploymentSiteIDs == ["site-1"])
  #expect(snapshot.sites.first { $0.id == "site-1" }?.latestDeployment == nil)
  #expect(snapshot.sites.first { $0.id == "site-1" }?.hasDeploymentFailure == false)
  #expect(snapshot.sites.first { $0.id == "site-2" }?.hasDeploymentFailure == true)
  #expect(snapshot.failures.count == 1)
}

@Test func rejectsCrossSiteDeploymentIdentityAndIncompleteSitePagination() async {
  var crossSite = standardNetlifyFixtures()
  crossSite[deploymentKey("site-1")] = #"[{"id":"deploy-1","site_id":"other-site","state":"ready"}]"#
  let partial = try? await makeNetlifyClient(runner: FixtureNetlifyRunner(fixtures: crossSite)).fetchSnapshot()
  #expect(partial?.failures.count == 1)
  #expect(partial?.sites.first?.latestDeployment == nil)

  var capped = standardNetlifyFixtures()
  capped["sites:list --json"] = "[" + (0..<1000).map { siteJSON(id: "site-\($0)", name: "site-\($0)") }.joined(separator: ",") + "]"
  let client = makeNetlifyClient(runner: FixtureNetlifyRunner(fixtures: capped))
  await #expect(throws: NetlifyCLIError.incompletePagination) { try await client.fetchSnapshot() }
}

@Test func limitsAllNetlifyDeploymentCommandsToFourConcurrentRequests() async throws {
  var fixtures: [String: String] = ["--version": netlifyVersion()]
  let sites = (1...8).map { index -> String in
    fixtures[deploymentKey("site-\(index)")] = "[]"
    return siteJSON(id: "site-\(index)", name: "site-\(index)")
  }
  fixtures["sites:list --json"] = "[\(sites.joined(separator: ","))]"
  let runner = FixtureNetlifyRunner(fixtures: fixtures, scopedDelay: .milliseconds(15))
  _ = try await makeNetlifyClient(runner: runner).fetchSnapshot()
  #expect(await runner.maximumActiveScopedCommands == 4)
}

@Test func systemNetlifyRunnerUsesSecureFilesNeutralDirectoryAndTerminatesOnCancellation() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("portdeck-netlify-runner-tests-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

  let permissionScript = try makeExecutable(at: root.appendingPathComponent("permissions"), source: """
  #!/bin/sh
  printf 'DIR=%s\\n' "$(stat -f %Lp "$PWD")"
  for file in "$PWD"/command-*; do printf 'FILE=%s\\n' "$(stat -f %Lp "$file")"; done
  printf 'discard me' >&2
  """)
  let privateDirectory = root.appendingPathComponent("private")
  let result = try await SystemNetlifyCommandRunner().run(
    executableURL: permissionScript, arguments: ["--version"], environment: [:], currentDirectoryURL: privateDirectory
  )
  let stdout = String(decoding: result.stdout, as: UTF8.self)
  #expect(stdout.contains("DIR=700"))
  #expect(stdout.split(separator: "\n").filter { $0 == "FILE=600" }.count == 2)
  #expect(result.stderr.isEmpty)
  #expect((try FileManager.default.contentsOfDirectory(atPath: privateDirectory.path)).isEmpty)

  let linkedParent = root.appendingPathComponent("linked")
  try FileManager.default.createDirectory(at: linkedParent.appendingPathComponent(".netlify"), withIntermediateDirectories: true)
  FileManager.default.createFile(atPath: linkedParent.appendingPathComponent(".netlify/state.json").path, contents: Data("{}".utf8))
  await #expect(throws: NetlifyCLIError.unsafeWorkingDirectory) {
    try await SystemNetlifyCommandRunner().run(
      executableURL: permissionScript, arguments: ["--version"], environment: [:],
      currentDirectoryURL: linkedParent.appendingPathComponent("child")
    )
  }

  let blockingScript = try makeExecutable(at: root.appendingPathComponent("blocking"), source: """
  #!/bin/sh
  while :; do sleep 0.05; done
  """)
  let task = Task {
    try await SystemNetlifyCommandRunner().run(
      executableURL: blockingScript, arguments: ["--version"], environment: [:],
      currentDirectoryURL: root.appendingPathComponent("cancel-private")
    )
  }
  try await Task.sleep(for: .milliseconds(80))
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
}

private func standardNetlifyFixtures() -> [String: String] {
  [
    "--version": netlifyVersion(),
    "sites:list --json": "[\(siteJSON(id: "site-1", name: "demo-site"))]",
    deploymentKey("site-1"): """
    [{
      "id":"deploy-1","site_id":"site-1","state":"ready","context":"production",
      "created_at":"2026-07-16T12:00:00Z","updated_at":"2026-07-16T12:01:00Z","published_at":"2026-07-16T12:02:00Z",
      "branch":"main","commit_ref":"abcdef1234567890","title":"Ship demo",
      "deploy_ssl_url":"https://deploy-1--demo-site.netlify.app",
      "admin_url":"https://app.netlify.com/sites/demo-site/deploys/deploy-1",
      "user_id":"ignored","required":["ignored"],"skew_protection_token":"ignored"
    }]
    """
  ]
}

private func netlifyVersion() -> String {
  "netlify-cli/26.2.0 darwin-arm64 node-v20.12.2"
}

private func siteJSON(id: String, name: String) -> String {
  """
  {"id":"\(id)","name":"\(name)","ssl_url":"https://\(name).netlify.app","admin_url":"https://app.netlify.com/sites/\(name)","account_id":"account-1","account_name":"Demo Team","account_slug":"demo-team","notification_email":"ignored@example.com","build_settings":{"env":{"SECRET":"ignored"}}}
  """
}

private func deploymentPayload(_ siteID: String) -> String {
  #"{"per_page":1,"production":true,"site_id":"\#(siteID)"}"#
}

private func deploymentKey(_ siteID: String) -> String {
  "api listSiteDeploys --data \(deploymentPayload(siteID))"
}

private func sensitiveNetlifyEnvironment() -> [String: String] {
  var environment = Dictionary(uniqueKeysWithValues: NetlifyCLIClient.removedEnvironmentKeys.map { ($0, "sensitive") })
  environment["PATH"] = "/usr/bin"
  environment["HOME"] = "/Users/tester"
  return environment
}

private func makeNetlifyClient(
  runner: FixtureNetlifyRunner,
  environment: [String: String] = [:]
) -> NetlifyCLIClient {
  NetlifyCLIClient(
    runner: runner,
    runtimeResolver: StaticNetlifyRuntimeResolver(),
    environment: environment,
    currentDirectoryURL: URL(fileURLWithPath: "/tmp/portdeck-netlify-tests")
  )
}

private struct StaticNetlifyRuntimeResolver: NetlifyRuntimeResolving {
  func resolveExecutableURL() throws -> URL { URL(fileURLWithPath: "/portdeck/runtime/netlify") }
}

private actor FixtureNetlifyRunner: NetlifyCommandRunning {
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
  ) async throws -> NetlifyCommandResult {
    receivedCommands.append(.init(
      arguments: arguments, environment: environment, currentDirectory: currentDirectoryURL.path
    ))
    let key = arguments.joined(separator: " ")
    let scoped = arguments.first == "api"
    if scoped {
      activeScopedCommands += 1
      maximumActiveScopedCommands = max(maximumActiveScopedCommands, activeScopedCommands)
      if scopedDelay != .zero { try await Task.sleep(for: scopedDelay) }
      activeScopedCommands -= 1
    }
    guard let fixture = fixtures[key] else {
      return NetlifyCommandResult(stdout: Data(), stderr: Data("Missing fixture for \(key)".utf8), terminationStatus: 1)
    }
    if fixture.hasPrefix("__ERROR__") {
      return NetlifyCommandResult(stdout: Data(), stderr: Data(fixture.dropFirst(9).utf8), terminationStatus: 1)
    }
    return NetlifyCommandResult(stdout: Data(fixture.utf8), terminationStatus: 0)
  }
}

private func makeExecutable(at url: URL, source: String) throws -> URL {
  FileManager.default.createFile(atPath: url.path, contents: Data(source.utf8))
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  return url
}
