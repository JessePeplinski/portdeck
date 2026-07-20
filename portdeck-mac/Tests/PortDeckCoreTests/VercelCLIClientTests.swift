import Foundation
import Testing
@testable import PortDeckCore

@Test func exposesTheCopyableVercelCLIInstallCommand() {
  #expect(VercelCLIClient.installCommand == "npm install -g vercel@latest")
}

@Test func reportsMissingOutdatedUnauthenticatedAndConnectedVercelCLIStates() async {
  let missingClient = VercelCLIClient(
    runner: FakeVercelCommandRunner(responses: []),
    environment: ["SHELL": "/missing-shell"],
    executableSearchPaths: []
  )
  #expect(await missingClient.inspectConnection() == .missingCLI)

  let outdatedClient = VercelCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/vercel"),
    runner: FakeVercelCommandRunner(responses: [commandResult("Vercel CLI 49.9.0")])
  )
  #expect(await outdatedClient.inspectConnection() == .outdatedCLI(currentVersion: "49.9.0"))

  let unauthenticatedClient = VercelCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/vercel"),
    runner: FakeVercelCommandRunner(responses: [
      commandResult("Vercel CLI 50.38.1\n50.38.1"),
      commandResult("", status: 1)
    ])
  )
  #expect(await unauthenticatedClient.inspectConnection() == .unauthenticated)

  let connectedClient = VercelCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/vercel"),
    runner: FakeVercelCommandRunner(responses: [
      commandResult("Vercel CLI 50.38.1\n50.38.1"),
      commandResult("developer")
    ])
  )
  #expect(await connectedClient.inspectConnection() == .connected)
}

@Test func authoritativeVercelOverrideDoesNotFallThrough() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("portdeck-vercel-runtime-tests-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let fallback = root.appendingPathComponent("vercel")
  FileManager.default.createFile(atPath: fallback.path, contents: Data("#!/bin/sh\n".utf8))
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fallback.path)

  let runner = FakeVercelCommandRunner(responses: [commandResult("Vercel CLI 50.38.1\n50.38.1")])
  let client = VercelCLIClient(
    runner: runner,
    environment: [
      "PORTDECK_VERCEL_BIN": root.appendingPathComponent("missing").path,
      "SHELL": "/missing-shell"
    ],
    executableSearchPaths: [fallback.path]
  )

  #expect(await client.inspectConnection() == .missingCLI)
  #expect(await runner.receivedArguments.isEmpty)
}

@Test func fetchesEveryVercelProjectPageWithoutPerProjectRequests() async throws {
  let runner = FakeVercelCommandRunner(responses: [
    commandResult(
      #"{"projects":[{"id":"one","accountId":"team-portdeck","name":"One","framework":"nextjs","link":{"productionBranch":"main"},"latestDeployments":[]}],"pagination":{"next":12345}}"#
    ),
    commandResult(
      #"{"projects":[{"id":"two","accountId":"team-portdeck","name":"Two","latestDeployments":[]}],"pagination":{"next":null}}"#
    ),
    commandResult(#"{"id":"team-portdeck","name":"PortDeck Team","slug":"portdeck"}"#),
    commandResult(
      #"{"deployments":[{"uid":"deployment","projectId":"one","target":"production","state":"BUILDING","readyState":"QUEUED","createdAt":1790000000000,"buildingAt":1790000001000,"ready":1790000043000,"url":"one.vercel.app","source":"git","inspectorUrl":"https://vercel.com/portdeck/one/deployment","meta":{"githubCommitRef":"main","githubCommitSha":"abcdef123456","githubCommitMessage":"Deploy One"}}],"pagination":{"next":null}}"#
    )
  ])
  let client = VercelCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/vercel"),
    runner: runner
  )

  let snapshot = try await client.fetchProjectSnapshot()
  let deployments = try await client.fetchRecentProductionDeployments()
  let arguments = await runner.receivedArguments

  #expect(snapshot.scope == VercelScope(id: "team-portdeck", name: "PortDeck Team", slug: "portdeck"))
  #expect(snapshot.projects.map(\.name) == ["One", "Two"])
  #expect(snapshot.projects.first { $0.id == "one" }?.framework == "nextjs")
  #expect(snapshot.projects.first { $0.id == "one" }?.productionBranch == "main")
  #expect(deployments.map(\.uid) == ["deployment"])
  #expect(deployments[0].state == "BUILDING")
  #expect(deployments[0].readyState == "QUEUED")
  #expect(deployments[0].meta?.branch == "main")
  #expect(deployments[0].meta?.commitSHA == "abcdef123456")
  #expect(deployments[0].inspectorUrl == "https://vercel.com/portdeck/one/deployment")
  #expect(arguments == [
    ["api", "/v10/projects?limit=100"],
    ["api", "/v10/projects?limit=100&until=12345"],
    ["api", "/v2/teams/team-portdeck"],
    ["api", "/v7/deployments?limit=100&target=production"]
  ])
}

@Test func keepsProjectsWhenVercelTeamLookupFails() async throws {
  let runner = FakeVercelCommandRunner(responses: [
    commandResult(
      #"{"projects":[{"id":"one","accountId":"team-portdeck","name":"One","latestDeployments":[]}],"pagination":{"next":null}}"#
    ),
    commandResult("", error: "Team lookup unavailable", status: 1)
  ])
  let client = VercelCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/vercel"),
    runner: runner
  )

  let snapshot = try await client.fetchProjectSnapshot()

  #expect(snapshot.projects.map(\.name) == ["One"])
  #expect(snapshot.scope == VercelScope(id: "team-portdeck", name: nil, slug: nil))
  #expect(await runner.receivedArguments == [
    ["api", "/v10/projects?limit=100"],
    ["api", "/v2/teams/team-portdeck"]
  ])
}

@Test func surfacesVercelRateLimitMalformedJSONAndLoginFailures() async throws {
  let rateLimited = VercelCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/vercel"),
    runner: FakeVercelCommandRunner(responses: [
      commandResult("", error: "Error: rate_limited", status: 1)
    ])
  )
  await #expect(throws: VercelCLIError.commandFailed("Error: rate_limited")) {
    try await rateLimited.fetchProjectSnapshot()
  }

  let malformed = VercelCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/vercel"),
    runner: FakeVercelCommandRunner(responses: [commandResult("not-json")])
  )
  await #expect(throws: VercelCLIError.self) {
    try await malformed.fetchProjectSnapshot()
  }

  let malformedDeployments = VercelCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/vercel"),
    runner: FakeVercelCommandRunner(responses: [commandResult("not-json")])
  )
  await #expect(throws: VercelCLIError.self) {
    try await malformedDeployments.fetchRecentProductionDeployments()
  }

  let loginFailure = VercelCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/vercel"),
    runner: FakeVercelCommandRunner(responses: [
      commandResult("", error: "Device login canceled", status: 1)
    ])
  )
  await #expect(throws: VercelCLIError.commandFailed("Device login canceled")) {
    try await loginFailure.login()
  }

  let credentialFailure = VercelCLIClient(
    executableURL: URL(fileURLWithPath: "/fake/vercel"),
    runner: FakeVercelCommandRunner(responses: [
      commandResult("", error: "Request failed with VERCEL_TOKEN=secret-value", status: 1)
    ])
  )
  await #expect(throws: VercelCLIError.commandFailed(
    "Request failed with VERCEL_TOKEN=<redacted>"
  )) {
    try await credentialFailure.fetchProjectSnapshot()
  }
}

private actor FakeVercelCommandRunner: VercelCommandRunning {
  private var responses: [VercelCommandResult]
  private(set) var receivedArguments: [[String]] = []

  init(responses: [VercelCommandResult]) {
    self.responses = responses
  }

  func run(executableURL: URL, arguments: [String]) async throws -> VercelCommandResult {
    receivedArguments.append(arguments)
    guard !responses.isEmpty else {
      throw FakeVercelRunnerError.missingResponse
    }
    return responses.removeFirst()
  }
}

private enum FakeVercelRunnerError: Error {
  case missingResponse
}

private func commandResult(_ output: String, error: String = "", status: Int32 = 0) -> VercelCommandResult {
  VercelCommandResult(
    stdout: Data(output.utf8),
    stderr: Data(error.utf8),
    terminationStatus: status
  )
}
