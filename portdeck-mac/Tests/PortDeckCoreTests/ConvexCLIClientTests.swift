import Foundation
import Testing
@testable import PortDeckCore

@Test func fetchesStructuredConvexProductionHealthThroughTheManagedRuntime() async throws {
  let runner = FakeConvexCommandRunner(responses: [
    commandResult("1.42.1"),
    commandResult(#"{"deploymentName":"steady-otter-123","dashboardUrl":"https://dashboard.convex.dev/d/steady-otter-123?view=insights","insights":[{"kind":"occRetried","severity":"warning","functionId":"tasks:run","componentPath":null,"occCalls":2}]}"#)
  ])
  let client = ConvexCLIClient(
    runner: runner,
    runtimeResolver: StaticConvexRuntimeResolver(path: "/portdeck/runtime/convex")
  )
  let candidate = ConvexProjectCandidate(projectName: "Demo", packageName: nil, packagePath: "/repo/demo")

  let response = try await client.fetchProductionHealth(for: candidate, target: productionTarget())
  let commands = await runner.receivedCommands

  #expect(response.deploymentName == "steady-otter-123")
  #expect(response.insights.map(\.kind) == ["occRetried"])
  #expect(commands == [
    .init(executablePath: "/portdeck/runtime/convex", arguments: ["--version"], currentDirectory: "/repo/demo"),
    .init(
      executablePath: "/portdeck/runtime/convex",
      arguments: ["insights", "--json", "--deployment", "team:demo:prod"],
      currentDirectory: "/repo/demo"
    )
  ])
}

@Test func validatesThePinnedRuntimeOnceAndNeverSearchesProjectDependencies() async throws {
  let oldProject = ConvexProjectCandidate(projectName: "Old", packageName: nil, packagePath: "/repo/old")
  let otherProject = ConvexProjectCandidate(projectName: "Other", packageName: nil, packagePath: "/repo/other")
  let responseJSON = #"{"deploymentName":"steady-otter-123","dashboardUrl":"https://dashboard.convex.dev/d/steady-otter-123?view=insights","insights":[]}"#
  let runner = FakeConvexCommandRunner(responses: [
    commandResult("1.42.1"),
    commandResult(responseJSON),
    commandResult(responseJSON)
  ])
  let client = ConvexCLIClient(
    runner: runner,
    runtimeResolver: StaticConvexRuntimeResolver(path: "/portdeck/runtime/convex")
  )

  _ = try await client.fetchProductionHealth(for: oldProject, target: productionTarget())
  _ = try await client.fetchProductionHealth(for: otherProject, target: productionTarget())

  let commands = await runner.receivedCommands
  #expect(commands.map(\.arguments) == [
    ["--version"],
    ["insights", "--json", "--deployment", "team:demo:prod"],
    ["insights", "--json", "--deployment", "team:demo:prod"]
  ])
  #expect(commands.map(\.executablePath) == Array(repeating: "/portdeck/runtime/convex", count: 3))
  #expect(commands.map(\.currentDirectory) == ["/repo/old", "/repo/old", "/repo/other"])
}

@Test func rejectsMissingAndNonPinnedManagedRuntimes() async {
  let candidate = ConvexProjectCandidate(projectName: "Demo", packageName: nil, packagePath: "/repo/demo")
  let missing = ConvexCLIClient(
    runner: FakeConvexCommandRunner(responses: []),
    runtimeResolver: FailingConvexRuntimeResolver()
  )
  await #expect(throws: ConvexCLIError.missingRuntime) {
    try await missing.fetchProductionHealth(for: candidate, target: productionTarget())
  }

  for version in ["1.40.0", "1.43.0"] {
    let incompatible = ConvexCLIClient(
      runner: FakeConvexCommandRunner(responses: [commandResult(version)]),
      runtimeResolver: StaticConvexRuntimeResolver(path: "/portdeck/runtime/convex")
    )
    await #expect(throws: ConvexCLIError.incompatibleRuntime(currentVersion: version)) {
      try await incompatible.fetchProductionHealth(for: candidate, target: productionTarget())
    }
  }
}

@Test func classifiesAuthenticationConfigurationAndMalformedManagedRuntimeResponses() async {
  let candidate = ConvexProjectCandidate(projectName: "Demo", packageName: nil, packagePath: "/repo/demo")
  for (message, expected) in [
    ("Insights require to be logged in as a user.", ConvexCLIError.unauthenticated),
    ("No CONVEX_DEPLOYMENT is set. Run `npx convex dev`.", ConvexCLIError.unconfigured)
  ] {
    let client = managedClient(responses: [
      commandResult("1.42.1"),
      commandResult("", error: message, status: 1)
    ])
    await #expect(throws: expected) {
      try await client.fetchProductionHealth(for: candidate, target: productionTarget())
    }
  }

  let malformed = managedClient(responses: [commandResult("1.42.1"), commandResult("not-json")])
  await #expect(throws: ConvexCLIError.self) {
    try await malformed.fetchProductionHealth(for: candidate, target: productionTarget())
  }
}

@Test func logsInThroughTheManagedRuntimeAndRedactsCredentialLikeFailures() async throws {
  let candidate = ConvexProjectCandidate(projectName: "Demo", packageName: nil, packagePath: "/repo/demo")
  let loginRunner = FakeConvexCommandRunner(responses: [commandResult("1.42.1"), commandResult("")])
  let loginClient = ConvexCLIClient(
    runner: loginRunner,
    runtimeResolver: StaticConvexRuntimeResolver(path: "/portdeck/runtime/convex")
  )
  try await loginClient.login(using: candidate)
  #expect(await loginRunner.receivedCommands.last?.arguments == [
    "login", "--device-name", "PortDeck", "--login-flow", "poll"
  ])

  let credentialMessages = [
    "Request failed for preview:team:project|abcdefghijklmnopqrstuvwxyz123456",
    "Authorization: Bearer super-secret-access-token",
    "accessToken=another-super-secret-token",
    "CONVEX_DEPLOY_KEY=production-secret-value",
    "eyJabcdefghijk.eyJabcdefghijk.signaturevalue"
  ]
  for credentialMessage in credentialMessages {
    let failed = managedClient(responses: [
      commandResult("1.42.1"),
      commandResult("", error: credentialMessage, status: 1)
    ])
    do {
      _ = try await failed.fetchProductionHealth(for: candidate, target: productionTarget())
      Issue.record("Expected the Convex command to fail")
    } catch {
      #expect(error.localizedDescription.contains("<redacted>"))
      #expect(!error.localizedDescription.contains("super-secret"))
      #expect(!error.localizedDescription.contains("abcdefghijklmnopqrstuvwxyz"))
      #expect(!error.localizedDescription.contains("eyJabcdefghijk"))
    }
  }
}

private actor FakeConvexCommandRunner: ConvexCommandRunning {
  struct ReceivedCommand: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let currentDirectory: String
  }

  private var responses: [ConvexCommandResult]
  private(set) var receivedCommands: [ReceivedCommand] = []

  init(responses: [ConvexCommandResult]) {
    self.responses = responses
  }

  func run(executableURL: URL, arguments: [String], currentDirectoryURL: URL) async throws -> ConvexCommandResult {
    receivedCommands.append(.init(
      executablePath: executableURL.path,
      arguments: arguments,
      currentDirectory: currentDirectoryURL.path
    ))
    guard !responses.isEmpty else { throw FakeConvexRunnerError.missingResponse }
    return responses.removeFirst()
  }
}

private struct StaticConvexRuntimeResolver: ConvexRuntimeResolving {
  let path: String
  func resolveExecutableURL() throws -> URL { URL(fileURLWithPath: path) }
}

private struct FailingConvexRuntimeResolver: ConvexRuntimeResolving {
  func resolveExecutableURL() throws -> URL { throw ConvexCLIError.missingRuntime }
}

private enum FakeConvexRunnerError: Error { case missingResponse }

private func managedClient(responses: [ConvexCommandResult]) -> ConvexCLIClient {
  ConvexCLIClient(
    runner: FakeConvexCommandRunner(responses: responses),
    runtimeResolver: StaticConvexRuntimeResolver(path: "/portdeck/runtime/convex")
  )
}

private func productionTarget() -> ConvexProductionTarget {
  ConvexProductionTarget(
    teamSlug: "team",
    projectName: "Demo",
    projectSlug: "demo",
    deploymentName: "steady-otter-123",
    lastDeployTime: Date(timeIntervalSince1970: 1_750_000_000)
  )
}

private func commandResult(_ output: String, error: String = "", status: Int32 = 0) -> ConvexCommandResult {
  ConvexCommandResult(stdout: Data(output.utf8), stderr: Data(error.utf8), terminationStatus: status)
}
