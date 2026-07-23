import Foundation
import Testing
@testable import PortDeckCore

@Test func executesOnlyPinnedReadOnlyCloudflareCommandsWithExplicitScopes() async throws {
  let runner = FakeCloudflareCommandRunner(responses: [
    cloudflareResult("4.111.0"),
    cloudflareResult(whoAmIJSON()),
    cloudflareResult(pagesProjectsJSON()),
    cloudflareResult(pagesDeploymentsJSON()),
    cloudflareResult(workerDeploymentsJSON()),
    cloudflareResult(workerDeploymentJSON())
  ])
  let client = CloudflareCLIClient(
    runner: runner,
    runtimeResolver: StaticCloudflareRuntimeResolver(path: "/portdeck/runtime/wrangler"),
    environment: [
      "PATH": "/usr/bin",
      "CLOUDFLARE_ACCOUNT_ID": "inherited-scope-must-not-leak",
      "WRANGLER_LOG": "debug",
      "WRANGLER_LOG_PATH": "/tmp/must-not-write.log"
    ],
    currentDirectoryURL: URL(fileURLWithPath: "/tmp/portdeck-cloudflare-neutral")
  )

  let accounts = try await client.fetchAccounts()
  let pages = try await client.fetchPages(accounts: accounts)
  let workers = try await client.fetchWorkers(
    candidates: [CloudflareWorkerCandidate(
      name: "api-worker", accountID: "account-1", associatedProjectNames: ["PortDeck"], configurationPath: "/repo/wrangler.json"
    )],
    accounts: accounts
  )
  let commands = await runner.receivedCommands

  #expect(pages.projects.map(\.name) == ["demo-pages"])
  #expect(workers.resources.first?.state == .gradualRollout)
  #expect(commands.map(\.arguments) == [
    ["--version"],
    ["whoami", "--json"],
    ["pages", "project", "list", "--json"],
    ["pages", "deployment", "list", "--project-name", "demo-pages", "--environment", "production", "--json"],
    ["deployments", "list", "--name", "api-worker", "--json"],
    ["deployments", "status", "--name", "api-worker", "--json"]
  ])
  #expect(commands.allSatisfy { $0.currentDirectory == "/tmp/portdeck-cloudflare-neutral" })
  #expect(commands.allSatisfy { $0.environment["WRANGLER_SEND_METRICS"] == "false" })
  #expect(commands.allSatisfy { $0.environment["WRANGLER_SEND_ERROR_REPORTS"] == "false" })
  // Wrangler's Pages JSON is emitted through its normal logger, so changing the
  // log level suppresses the structured stdout that PortDeck needs to decode.
  #expect(commands.allSatisfy { $0.environment["WRANGLER_LOG"] == nil })
  #expect(commands.allSatisfy { $0.environment["WRANGLER_LOG_SANITIZE"] == "true" })
  #expect(commands.allSatisfy { $0.environment["WRANGLER_LOG_PATH"] == nil })
  #expect(commands[1].environment["CLOUDFLARE_ACCOUNT_ID"] == nil)
  #expect(commands.dropFirst(2).allSatisfy { $0.environment["CLOUDFLARE_ACCOUNT_ID"] == "account-1" })
}

@Test func validatesWranglerVersionRangeOnceAndRejectsUnsupportedVersions() async throws {
  let runner = FakeCloudflareCommandRunner(responses: [
    cloudflareResult("4.111.0"), cloudflareResult(whoAmIJSON()), cloudflareResult(whoAmIJSON())
  ])
  let client = managedCloudflareClient(runner: runner)
  _ = try await client.fetchAccounts()
  _ = try await client.fetchAccounts()
  #expect(await runner.receivedCommands.map(\.arguments) == [["--version"], ["whoami", "--json"], ["whoami", "--json"]])

  for version in ["4.110.0", "5.0.0", "4.111.0-beta.1"] {
    let client = managedCloudflareClient(runner: FakeCloudflareCommandRunner(responses: [cloudflareResult(version)]))
    await #expect(throws: CloudflareCLIError.unsupportedCLI(currentVersion: version)) {
      try await client.fetchAccounts()
    }
  }
}

@Test func classifiesAuthenticationRateLimitMalformedAndSanitizesCloudflareFailures() async throws {
  let authentication = managedCloudflareClient(runner: FakeCloudflareCommandRunner(responses: [
    cloudflareResult("4.111.0"),
    cloudflareResult("", error: "Not logged in. Your auth token has expired. Run `wrangler login`.", status: 1)
  ]))
  await #expect(throws: CloudflareCLIError.authenticationRequired) { try await authentication.fetchAccounts() }

  let rateLimited = managedCloudflareClient(runner: FakeCloudflareCommandRunner(responses: [
    cloudflareResult("4.111.0"), cloudflareResult("", error: "HTTP 429: Too many requests", status: 1)
  ]))
  await #expect(throws: CloudflareCLIError.rateLimited) { try await rateLimited.fetchAccounts() }

  let malformed = managedCloudflareClient(runner: FakeCloudflareCommandRunner(responses: [
    cloudflareResult("4.111.0"), cloudflareResult("not-json")
  ]))
  await #expect(throws: CloudflareCLIError.self) { try await malformed.fetchAccounts() }

  let secret = "CLOUDFLARE_API_TOKEN=super-secret-token"
  let sanitized = managedCloudflareClient(runner: FakeCloudflareCommandRunner(responses: [
    cloudflareResult("4.111.0"), cloudflareResult("", error: secret, status: 1)
  ]))
  do {
    _ = try await sanitized.fetchAccounts()
    Issue.record("Expected command failure")
  } catch {
    #expect(error.localizedDescription.contains("<redacted>"))
    #expect(!error.localizedDescription.contains("super-secret"))
  }
}

@Test func preservesMultipleAccountAmbiguityWithoutIssuingWorkerCommands() async throws {
  let runner = FakeCloudflareCommandRunner(responses: [cloudflareResult("4.111.0")])
  let client = managedCloudflareClient(runner: runner)
  let candidate = CloudflareWorkerCandidate(
    name: "unscoped-worker", accountID: nil, associatedProjectNames: ["Demo"], configurationPath: "/repo/wrangler.toml"
  )
  let result = try await client.fetchWorkers(
    candidates: [candidate],
    accounts: [CloudflareAccount(id: "one", name: "One"), CloudflareAccount(id: "two", name: "Two")]
  )

  #expect(result.resources.first?.account == nil)
  #expect(result.failures.first?.message.contains("Multiple Cloudflare accounts") == true)
  #expect(await runner.receivedCommands.isEmpty)
}

private actor FakeCloudflareCommandRunner: CloudflareCommandRunning {
  struct ReceivedCommand: Sendable {
    let arguments: [String]
    let environment: [String: String]
    let currentDirectory: String
  }

  private var responses: [CloudflareCommandResult]
  private(set) var receivedCommands: [ReceivedCommand] = []

  init(responses: [CloudflareCommandResult]) { self.responses = responses }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> CloudflareCommandResult {
    receivedCommands.append(.init(arguments: arguments, environment: environment, currentDirectory: currentDirectoryURL.path))
    guard !responses.isEmpty else { throw FakeCloudflareRunnerError.missingResponse }
    return responses.removeFirst()
  }
}

private struct StaticCloudflareRuntimeResolver: CloudflareRuntimeResolving {
  let path: String
  func resolveExecutableURL() throws -> URL { URL(fileURLWithPath: path) }
}

private enum FakeCloudflareRunnerError: Error { case missingResponse }

private func managedCloudflareClient(runner: FakeCloudflareCommandRunner) -> CloudflareCLIClient {
  CloudflareCLIClient(
    runner: runner,
    runtimeResolver: StaticCloudflareRuntimeResolver(path: "/portdeck/runtime/wrangler"),
    environment: [:],
    currentDirectoryURL: URL(fileURLWithPath: "/tmp/portdeck-cloudflare")
  )
}

private func cloudflareResult(_ output: String, error: String = "", status: Int32 = 0) -> CloudflareCommandResult {
  CloudflareCommandResult(stdout: Data(output.utf8), stderr: Data(error.utf8), terminationStatus: status)
}

private func whoAmIJSON() -> String {
  #"{"loggedIn":true,"authType":"OAuth Token","email":"ignored@example.com","accounts":[{"id":"account-1","name":"Demo Account"}],"tokenPermissions":["account:read"]}"#
}

private func pagesProjectsJSON() -> String {
  #"[{"Project Name":"demo-pages","Project Domains":"demo.pages.dev, example.com","Git Provider":"Yes","Last Modified":"2 minutes ago"}]"#
}

private func pagesDeploymentsJSON() -> String {
  #"[{"Id":"page-deployment","Environment":"Production","Branch":"main","Source":"abcdef0","Deployment":"https://demo.pages.dev","Status":"2 minutes ago","Build":"https://dash.cloudflare.com/account-1/pages/view/demo-pages/page-deployment"}]"#
}

private func workerDeploymentsJSON() -> String { "[\(workerDeploymentJSON())]" }

private func workerDeploymentJSON() -> String {
  #"{"id":"worker-deployment","created_on":"2026-07-16T12:00:00.000Z","source":"api","strategy":"percentage","versions":[{"version_id":"v1","percentage":10},{"version_id":"v2","percentage":90}],"annotations":{"workers/message":"Gradual release","workers/triggered_by":"deployment"},"author_email":"ignored@example.com"}"#
}
