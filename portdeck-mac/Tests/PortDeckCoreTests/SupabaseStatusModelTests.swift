import Foundation
import PortDeckCore
import Testing
@testable import PortDeckMac

@MainActor
@Test func usesMinuteSupabasePollingAndCancelsWhenOwningTaskEnds() async {
  #expect(SupabaseStatusModel.refreshIntervalSeconds == 60)
  let client = FakeSupabaseClient(responses: Array(repeating: .projects([sampleSupabaseProject()]), count: 10))
  let model = SupabaseStatusModel(client: client, pollInterval: .milliseconds(10))

  let task = Task { await model.runAutoRefresh() }
  for _ in 0..<100 where await client.callCount < 2 {
    try? await Task.sleep(for: .milliseconds(2))
  }
  task.cancel()
  await task.value
  let countAfterCancellation = await client.callCount
  try? await Task.sleep(for: .milliseconds(25))

  #expect(countAfterCancellation >= 2)
  #expect(await client.callCount == countAfterCancellation)
}

@MainActor
@Test func preservesLastSuccessfulSupabaseSnapshotAcrossTransientRateLimitAndMalformedFailures() async {
  let firstDate = Date(timeIntervalSince1970: 1_750_000_000)
  let client = FakeSupabaseClient(responses: [
    .projects([sampleSupabaseProject()]),
    .failure(.commandFailed("Temporary upstream failure")),
    .failure(.rateLimited),
    .failure(.invalidResponse("not JSON")),
    .projects([])
  ])
  let model = SupabaseStatusModel(client: client, now: { firstDate })

  await model.refresh()
  #expect(model.projects.map(\.name) == ["Demo"])
  #expect(model.lastSuccessfulRefreshAt == firstDate)

  for _ in 0..<3 {
    await model.refresh()
    #expect(model.projects.map(\.name) == ["Demo"])
    #expect(model.lastSuccessfulRefreshAt == firstDate)
    #expect(model.errorMessage != nil)
  }

  await model.refresh()
  #expect(model.projects.isEmpty)
  #expect(model.connectionState == .connected)
  #expect(model.errorMessage == nil)
}

@MainActor
@Test func reportsFreshSupabaseRuntimeAuthenticationRateLimitAndFailureStates() async {
  let cases: [(SupabaseCLIError, SupabaseConnectionState)] = [
    (.missingCLI, .missingCLI),
    (.unsupportedCLI(currentVersion: "2.109.0"), .unsupportedCLI(currentVersion: "2.109.0")),
    (.authenticationRequired, .authenticationRequired),
    (.rateLimited, .rateLimited(message: SupabaseCLIError.rateLimited.localizedDescription)),
    (.commandFailed("Unavailable"), .failed(message: "Unavailable")),
    (.invalidResponse("Malformed"), .failed(message: SupabaseCLIError.invalidResponse("Malformed").localizedDescription))
  ]

  for (error, expectedState) in cases {
    let model = SupabaseStatusModel(client: FakeSupabaseClient(responses: [.failure(error)]))
    await model.refresh()
    #expect(model.connectionState == expectedState)
    #expect(model.projects.isEmpty)
  }
}

@MainActor
@Test func manualSupabaseRefreshIsImmediateAndOverlappingRequestsAreIgnored() async {
  let client = FakeSupabaseClient(
    responses: [.projects([sampleSupabaseProject()])],
    delay: .milliseconds(30)
  )
  let model = SupabaseStatusModel(client: client)

  async let first: Void = model.refresh()
  try? await Task.sleep(for: .milliseconds(5))
  async let overlapping: Void = model.refresh()
  _ = await (first, overlapping)

  #expect(await client.callCount == 1)
  #expect(model.projects.map(\.name) == ["Demo"])
}

@MainActor
@Test func filtersSupabaseModelProjectsWithoutMutatingSnapshot() async {
  let projects = [
    sampleSupabaseProject(name: "Demo", organization: "example-org"),
    sampleSupabaseProject(reference: "qrstuvwxyzabcdefghij", name: "PortDeck", organization: "portdeck-org")
  ]
  let model = SupabaseStatusModel(client: FakeSupabaseClient(responses: [.projects(projects)]))
  await model.refresh()

  #expect(model.filteredProjects(matching: "portdeck").map(\.name) == ["PortDeck"])
  #expect(model.projects.count == 2)
}

private actor FakeSupabaseClient: SupabaseCLIClientProtocol {
  enum Response: Sendable {
    case projects([SupabaseProject])
    case failure(SupabaseCLIError)
  }

  private var responses: [Response]
  private let delay: Duration?
  private(set) var callCount = 0

  init(responses: [Response], delay: Duration? = nil) {
    self.responses = responses
    self.delay = delay
  }

  func fetchProjects() async throws -> [SupabaseProject] {
    callCount += 1
    if let delay { try await Task.sleep(for: delay) }
    guard !responses.isEmpty else { return [] }
    switch responses.removeFirst() {
    case .projects(let projects): return projects
    case .failure(let error): throw error
    }
  }
}

private func sampleSupabaseProject(
  reference: String = "abcdefghijklmnopqrst",
  name: String = "Demo",
  organization: String = "demo-org"
) -> SupabaseProject {
  SupabaseProject(
    reference: reference,
    name: name,
    organizationID: "org-id",
    organizationSlug: organization,
    region: "us-east-1",
    rawStatus: "ACTIVE_HEALTHY"
  )
}
