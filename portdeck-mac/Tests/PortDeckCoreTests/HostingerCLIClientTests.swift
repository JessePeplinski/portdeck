import Foundation
import Testing
@testable import PortDeckCore

@Test func fetchesPaginatedHostingerWebsitesWithExactReadOnlyCommandsAndNarrowFields() async throws {
  let runner = FixtureHostingerRunner(fixtures: [
    versionKey: "3.7.0 (Build: d1bc4d9)",
    pageKey(1): websitesEnvelope(
      rows: [
        websiteJSON(domain: "disabled.example", isEnabled: false, orderID: 20),
        websiteJSON(domain: "app.example", isEnabled: true, orderID: 10)
      ],
      page: 1,
      total: 3
    ),
    pageKey(2): websitesEnvelope(
      rows: [websiteJSON(domain: "unknown.example", isEnabled: nil, orderID: 30)],
      page: 2,
      total: 3
    )
  ])
  let client = makeHostingerClient(runner: runner, environment: sensitiveHostingerEnvironment())

  let websites = try await client.fetchWebsites()
  let commands = await runner.receivedCommands

  #expect(websites.map(\.domain) == ["disabled.example", "unknown.example", "app.example"])
  #expect(websites.first?.orderID == 20)
  #expect(websites.first?.parentDomain == "example")
  #expect(websites.first?.vhostType == "main")
  #expect(websites.first?.createdAt != nil)
  #expect(commands.map(\.arguments) == [
    ["version", "--config", "/Users/tester/.hostinger.yaml"],
    listArguments(page: 1),
    listArguments(page: 2)
  ])
  #expect(commands.allSatisfy { $0.currentDirectory == "/tmp/portdeck-hostinger-tests" })
  for key in HostingerCLIClient.removedEnvironmentKeys {
    #expect(commands.allSatisfy { $0.environment[key] == nil || key == "HOSTINGER_OAUTH_ISSUER" })
  }
  #expect(commands.allSatisfy { $0.environment["HOSTINGER_OAUTH_ISSUER"] == "http://127.0.0.1:0" })
  #expect(commands.allSatisfy { $0.environment["NO_COLOR"] == "1" })
  #expect(commands.allSatisfy { $0.environment["HOME"] == "/Users/tester" })
}

@Test func validatesHostingerVersionOnceAndRejectsUnsupportedMajor() async throws {
  let runner = FixtureHostingerRunner(fixtures: [
    versionKey: "3.7.0 (Build: current)",
    pageKey(1): websitesEnvelope(rows: [], page: 1, total: 0)
  ])
  let client = makeHostingerClient(runner: runner)

  _ = try await client.fetchWebsites()
  _ = try await client.fetchWebsites()
  #expect(await runner.receivedCommands.filter { $0.arguments.first == "version" }.count == 1)

  let unsupported = makeHostingerClient(runner: FixtureHostingerRunner(fixtures: [
    versionKey: "4.0.0 (Build: future)"
  ]))
  await #expect(throws: HostingerCLIError.unsupportedCLI(currentVersion: "4.0.0 (Build: future)")) {
    try await unsupported.fetchWebsites()
  }
}

@Test func hostingerAllowlistRejectsMutationInteractiveAuthAndUnsafePagination() throws {
  try HostingerCommandAllowlist.validate([
    "version", "--config", "/Users/tester/.hostinger.yaml"
  ])
  try HostingerCommandAllowlist.validate(listArguments(page: 1))

  for arguments in [
    ["login"],
    ["logout"],
    ["vps", "vm", "start", "123"],
    ["hosting", "websites", "delete", "example.com"],
    ["hosting", "websites", "list", "--format", "json"],
    listArguments(page: 0),
    listArguments(page: HostingerCLIClient.maximumPageCount + 1),
    ["version", "--config", "/Users/tester/other.yaml"],
    ["version", "--config", "relative/.hostinger.yaml"]
  ] {
    #expect(throws: HostingerCLIError.unsafeCommand) {
      try HostingerCommandAllowlist.validate(arguments)
    }
  }
}

@Test func classifiesHostingerFailuresAndRedactsCredentialShapes() async {
  let authentication = makeHostingerClient(runner: FixtureHostingerRunner(fixtures: [
    versionKey: "3.7.0 (Build: current)",
    pageKey(1): #"__ERROR__{"error":{"message":"Unauthenticated"},"status":401}"#
  ]))
  await #expect(throws: HostingerCLIError.authenticationRequired) {
    try await authentication.fetchWebsites()
  }

  let blockedInteractiveLogin = makeHostingerClient(runner: FixtureHostingerRunner(fixtures: [
    versionKey: "3.7.0 (Build: current)",
    pageKey(1): "__ERROR__Post http://127.0.0.1:0/api/external/v1/oauth-server/register: connection refused"
  ]))
  await #expect(throws: HostingerCLIError.authenticationRequired) {
    try await blockedInteractiveLogin.fetchWebsites()
  }

  let rateLimited = makeHostingerClient(runner: FixtureHostingerRunner(fixtures: [
    versionKey: "3.7.0 (Build: current)",
    pageKey(1): "__ERROR__HTTP 429 Too Many Requests"
  ]))
  await #expect(throws: HostingerCLIError.rateLimited) {
    try await rateLimited.fetchWebsites()
  }

  let secret = makeHostingerClient(runner: FixtureHostingerRunner(fixtures: [
    versionKey: "3.7.0 (Build: current)",
    pageKey(1): "__ERROR__HOSTINGER_API_TOKEN=super-secret Authorization: Bearer hidden-token token=credential"
  ]))
  do {
    _ = try await secret.fetchWebsites()
    Issue.record("Expected Hostinger command failure")
  } catch {
    let message = error.localizedDescription
    #expect(message.contains("<redacted>"))
    for value in ["super-secret", "hidden-token", "credential"] {
      #expect(!message.contains(value))
    }
  }
}

@Test func rejectsIncompleteChangedAndDuplicateHostingerPagination() async {
  let missingPage = makeHostingerClient(runner: FixtureHostingerRunner(fixtures: [
    versionKey: "3.7.0 (Build: current)",
    pageKey(1): websitesEnvelope(
      rows: [websiteJSON(domain: "one.example", isEnabled: true, orderID: 1)],
      page: 1,
      total: 2
    ),
    pageKey(2): websitesEnvelope(rows: [], page: 2, total: 2)
  ]))
  await #expect(throws: HostingerCLIError.incompletePagination) {
    try await missingPage.fetchWebsites()
  }

  let changedTotal = makeHostingerClient(runner: FixtureHostingerRunner(fixtures: [
    versionKey: "3.7.0 (Build: current)",
    pageKey(1): websitesEnvelope(
      rows: [websiteJSON(domain: "one.example", isEnabled: true, orderID: 1)],
      page: 1,
      total: 2
    ),
    pageKey(2): websitesEnvelope(
      rows: [websiteJSON(domain: "two.example", isEnabled: true, orderID: 2)],
      page: 2,
      total: 3
    )
  ]))
  await #expect(throws: HostingerCLIError.incompletePagination) {
    try await changedTotal.fetchWebsites()
  }

  let duplicate = makeHostingerClient(runner: FixtureHostingerRunner(fixtures: [
    versionKey: "3.7.0 (Build: current)",
    pageKey(1): websitesEnvelope(
      rows: [websiteJSON(domain: "same.example", isEnabled: true, orderID: 1)],
      page: 1,
      total: 2
    ),
    pageKey(2): websitesEnvelope(
      rows: [websiteJSON(domain: "same.example", isEnabled: true, orderID: 1)],
      page: 2,
      total: 2
    )
  ]))
  await #expect(throws: HostingerCLIError.incompletePagination) {
    try await duplicate.fetchWebsites()
  }
}

private let versionKey = "version --config /Users/tester/.hostinger.yaml"

private func pageKey(_ page: Int) -> String {
  listArguments(page: page).joined(separator: " ")
}

private func listArguments(page: Int) -> [String] {
  [
    "hosting", "websites", "list",
    "--page", String(page),
    "--per-page", String(HostingerCLIClient.pageSize),
    "--format", "json",
    "--config", "/Users/tester/.hostinger.yaml"
  ]
}

private func websitesEnvelope(rows: [String], page: Int, total: Int) -> String {
  """
  {"data":[\(rows.joined(separator: ","))],"meta":{"current_page":\(page),"per_page":\(HostingerCLIClient.pageSize),"total":\(total)}}
  """
}

private func websiteJSON(domain: String, isEnabled: Bool?, orderID: Int) -> String {
  let enabled = isEnabled.map(String.init) ?? "null"
  return """
  {"domain":"\(domain)","is_enabled":\(enabled),"order_id":\(orderID),"parent_domain":"example","vhost_type":"main","created_at":"2026-07-22T12:00:00.123Z","client_id":999,"username":"ignored","root_directory":"/private"}
  """
}

private func sensitiveHostingerEnvironment() -> [String: String] {
  [
    "PATH": "/usr/bin",
    "HOME": "/Users/tester",
    "HOSTINGER_API_TOKEN": "secret",
    "HOSTINGER_API_URL": "https://private.example",
    "HOSTINGER_OAUTH_ISSUER": "https://private-auth.example",
    "HAPI_API_TOKEN": "legacy-secret",
    "HAPI_API_URL": "https://legacy-private.example"
  ]
}

private func makeHostingerClient(
  runner: FixtureHostingerRunner,
  environment: [String: String] = ["HOME": "/Users/tester"]
) -> HostingerCLIClient {
  HostingerCLIClient(
    runner: runner,
    runtimeResolver: StaticHostingerRuntimeResolver(path: "/portdeck/runtime/hostinger"),
    environment: environment,
    currentDirectoryURL: URL(fileURLWithPath: "/tmp/portdeck-hostinger-tests"),
    configurationURL: URL(fileURLWithPath: "/Users/tester/.hostinger.yaml")
  )
}

private actor FixtureHostingerRunner: HostingerCommandRunning {
  struct ReceivedCommand: Sendable {
    let arguments: [String]
    let environment: [String: String]
    let currentDirectory: String
  }

  private let fixtures: [String: String]
  private(set) var receivedCommands: [ReceivedCommand] = []

  init(fixtures: [String: String]) {
    self.fixtures = fixtures
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    currentDirectoryURL: URL
  ) async throws -> HostingerCommandResult {
    receivedCommands.append(ReceivedCommand(
      arguments: arguments,
      environment: environment,
      currentDirectory: currentDirectoryURL.path
    ))
    let key = arguments.joined(separator: " ")
    guard let fixture = fixtures[key] else {
      throw FixtureHostingerError.missingFixture(key)
    }
    if fixture.hasPrefix("__ERROR__") {
      return HostingerCommandResult(
        stdout: Data(fixture.dropFirst("__ERROR__".count).utf8),
        terminationStatus: 1
      )
    }
    return HostingerCommandResult(stdout: Data(fixture.utf8), terminationStatus: 0)
  }
}

private struct StaticHostingerRuntimeResolver: HostingerRuntimeResolving {
  let path: String

  func resolveExecutableURL() throws -> URL {
    URL(fileURLWithPath: path)
  }
}

private enum FixtureHostingerError: Error {
  case missingFixture(String)
}
