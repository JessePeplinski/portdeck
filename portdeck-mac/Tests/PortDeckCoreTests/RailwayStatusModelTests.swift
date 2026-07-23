import Foundation
import PortDeckCore
import Testing
@testable import PortDeckMac

@MainActor
@Test func railwayModelPreservesLastGoodServicesAcrossScopedAndGlobalFailures() async throws {
  let initial = railwayProject(services: [railwayModelService()])
  let scopedFailure = RailwayProject(
    id: initial.id,
    name: initial.name,
    workspace: initial.workspace,
    productionEnvironmentID: initial.productionEnvironmentID,
    productionState: .failed(message: "Temporary project failure")
  )
  let client = FakeRailwayClient(results: [
    .success(RailwaySnapshotResult(projects: [initial], successfulProjectIDs: [initial.id])),
    .success(RailwaySnapshotResult(
      projects: [scopedFailure],
      successfulProjectIDs: [],
      failures: [.init(projectID: initial.id, message: "Temporary project failure")]
    )),
    .failure(RailwayCLIError.rateLimited)
  ])
  let model = RailwayStatusModel(client: client, now: { Date(timeIntervalSince1970: 100) })

  await model.refresh()
  #expect(model.projects.first?.services.count == 1)
  #expect(model.lastSuccessfulRefreshAt == Date(timeIntervalSince1970: 100))

  await model.refresh()
  #expect(model.projects.first?.services.count == 1)
  #expect(model.errorMessage == "Temporary project failure")
  #expect(model.connectionState == .connected)

  await model.refresh()
  #expect(model.projects.first?.services.count == 1)
  if case .rateLimited = model.connectionState {} else { Issue.record("Expected rate-limited state") }
}

@MainActor
@Test func railwayModelAcceptsLegitimateEmptySnapshotsAndFiltersResources() async {
  let project = railwayProject(services: [railwayModelService()])
  let client = FakeRailwayClient(results: [
    .success(RailwaySnapshotResult(projects: [project], successfulProjectIDs: [project.id])),
    .success(RailwaySnapshotResult(projects: [], successfulProjectIDs: []))
  ])
  let model = RailwayStatusModel(client: client)
  await model.refresh()
  #expect(model.filteredProjects(matching: "release").first?.services.count == 1)
  #expect(model.filteredProjects(matching: "missing").isEmpty)
  await model.refresh()
  #expect(model.projects.isEmpty)
  #expect(model.connectionState == .connected)
}

@MainActor
@Test func railwayModelRetainsMatchingDeploymentMetadataWhenEnrichmentFails() async {
  let initial = railwayProject(services: [railwayModelService()])
  let refreshedService = RailwayService(
    id: "service-1",
    name: "API",
    currentRawStatus: "FAILED",
    latestDeployment: RailwayDeployment(
      id: "deployment-1", rawStatus: "FAILED", createdAt: Date(timeIntervalSince1970: 101)
    ),
    productionURLString: "https://api.example"
  )
  let refreshed = railwayProject(services: [refreshedService])
  let client = FakeRailwayClient(results: [
    .success(RailwaySnapshotResult(projects: [initial], successfulProjectIDs: [initial.id])),
    .success(RailwaySnapshotResult(
      projects: [refreshed], successfulProjectIDs: [refreshed.id],
      failures: [.init(projectID: refreshed.id, serviceID: refreshedService.id, message: "Deployment metadata unavailable")]
    ))
  ])
  let model = RailwayStatusModel(client: client)
  await model.refresh()
  await model.refresh()
  let deployment = model.projects.first?.services.first?.latestDeployment
  #expect(deployment?.branch == "release")
  #expect(deployment?.commitSHA == "deadbeef")
  #expect(deployment?.createdAt == Date(timeIntervalSince1970: 101))
}

@MainActor
@Test func railwayModelRejectsOverlappingRefreshesAndPollsImmediatelyUntilCancelled() async throws {
  let client = FakeRailwayClient(
    results: Array(repeating: .success(RailwaySnapshotResult(projects: [], successfulProjectIDs: [])), count: 20),
    delay: .milliseconds(20)
  )
  let model = RailwayStatusModel(client: client, pollInterval: .milliseconds(5))

  async let first: Void = model.refresh()
  async let second: Void = model.refresh()
  _ = await (first, second)
  #expect(await client.callCount == 1)

  let pollTask = Task { await model.runAutoRefresh() }
  try await Task.sleep(for: .milliseconds(58))
  pollTask.cancel()
  _ = await pollTask.result
  let countAfterCancel = await client.callCount
  #expect(countAfterCancel >= 3)
  try await Task.sleep(for: .milliseconds(30))
  #expect(await client.callCount == countAfterCancel)
}

@MainActor
@Test func railwayModelMapsSetupFailuresWithoutDiscardingState() async {
  let cases: [(RailwayCLIError, RailwayConnectionState)] = [
    (.missingCLI, .missingCLI),
    (.unsupportedCLI(currentVersion: "railway 5.25.0"), .unsupportedCLI(currentVersion: "railway 5.25.0")),
    (.authenticationRequired, .authenticationRequired),
    (.rateLimited, .rateLimited(message: RailwayCLIError.rateLimited.localizedDescription))
  ]
  for (error, expected) in cases {
    let model = RailwayStatusModel(client: FakeRailwayClient(results: [.failure(error)]))
    await model.refresh()
    #expect(model.connectionState == expected)
  }
}

private actor FakeRailwayClient: RailwayCLIClientProtocol {
  private var results: [Result<RailwaySnapshotResult, RailwayCLIError>]
  private let delay: Duration
  private(set) var callCount = 0

  init(
    results: [Result<RailwaySnapshotResult, RailwayCLIError>],
    delay: Duration = .zero
  ) {
    self.results = results
    self.delay = delay
  }

  func fetchSnapshot() async throws -> RailwaySnapshotResult {
    callCount += 1
    if delay != .zero { try? await Task.sleep(for: delay) }
    guard !results.isEmpty else { return RailwaySnapshotResult(projects: [], successfulProjectIDs: []) }
    return try results.removeFirst().get()
  }
}

private func railwayProject(services: [RailwayService]) -> RailwayProject {
  RailwayProject(
    id: "project-1",
    name: "Demo",
    workspace: RailwayWorkspace(id: "workspace-1", name: "Demo Team"),
    productionEnvironmentID: "environment-1",
    services: services
  )
}

private func railwayModelService() -> RailwayService {
  RailwayService(
    id: "service-1",
    name: "API",
    currentRawStatus: "FAILED",
    latestDeployment: RailwayDeployment(
      id: "deployment-1",
      rawStatus: "FAILED",
      createdAt: Date(timeIntervalSince1970: 100),
      branch: "release",
      commitSHA: "deadbeef",
      commitMessage: "Failed release"
    )
  )
}
