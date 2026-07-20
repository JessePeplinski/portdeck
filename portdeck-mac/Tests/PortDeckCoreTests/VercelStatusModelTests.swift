import Foundation
import PortDeckCore
import Testing
@testable import PortDeckMac

@Test func usesTwoSecondPollingAndPresentsOnlyTheLastCheckedAge() {
  #expect(VercelStatusModel.deploymentRefreshIntervalSeconds == 2)
  #expect(vercelLastCheckedLabel(ageSeconds: 1) == "Checked 1s ago")

  let lastUpdated = Date(timeIntervalSince1970: 100)
  #expect(vercelPollingAgeSeconds(lastUpdated: lastUpdated, relativeTo: lastUpdated) == 0)
  #expect(vercelPollingAgeSeconds(
    lastUpdated: lastUpdated,
    relativeTo: Date(timeIntervalSince1970: 101.9)
  ) == 1)
  #expect(vercelPollingAgeSeconds(
    lastUpdated: lastUpdated,
    relativeTo: Date(timeIntervalSince1970: 99)
  ) == 0)
  #expect(vercelScopeLabel(VercelScope(id: "team", name: "PortDeck Team", slug: "portdeck")) == "PortDeck Team")
  #expect(vercelScopeLabel(nil) == "Active Vercel CLI team")
  #expect(vercelProductionSiteAccessibilityLabel(projectName: "PortDeck") == "Open PortDeck production site")
  #expect(vercelDashboardAccessibilityLabel(
    projectName: "PortDeck",
    opensDeployment: true
  ) == "Open PortDeck Vercel deployment")
  #expect(vercelDashboardAccessibilityLabel(
    projectName: "PortDeck",
    opensDeployment: false
  ) == "Open PortDeck Vercel project")
  #expect(vercelBuildDurationLabel(42) == "42s")
  #expect(vercelBuildDurationLabel(72) == "1m 12s")
}

@MainActor
@Test func preservesLastSuccessfulVercelSnapshotAfterTransientFailure() async {
  let project = VercelProjectStatus(
    id: "project",
    name: "PortDeck",
    productionDeploymentID: "deployment",
    productionURLString: "https://portdeck.app",
    healthState: .ready,
    rawState: "READY",
    deploymentCreatedAt: Date()
  )
  let client = FakeVercelClient(
    connectionStates: [.connected, .connected],
    projectResults: [
      .success(snapshot(projects: [project])),
      .failure(FakeVercelClientError.projectTransient)
    ],
    deploymentResults: [.success([]), .success([])]
  )
  let model = VercelStatusModel(client: client)

  await model.refresh()
  #expect(model.projects == [project])
  #expect(model.scope?.displayName == "PortDeck Team")
  #expect(model.errorMessage == nil)

  await model.refresh()
  #expect(model.projects == [project])
  #expect(model.connectionState == .connected)
  #expect(model.errorMessage == "Temporary Vercel project failure")
}

@MainActor
@Test func refreshesProjectsAndTransitionsDeploymentActivityFromBuildingToReady() async {
  let baseline = readyProject()
  let client = FakeVercelClient(
    connectionStates: [.connected],
    projectResults: [.success(snapshot(projects: [baseline]))],
    deploymentResults: [
      .success([deployment(state: "BUILDING")]),
      .success([deployment(state: "READY")])
    ]
  )
  let model = VercelStatusModel(client: client)

  await model.refresh()
  #expect(model.projects[0].healthState == .inProgress)
  #expect(model.projects[0].rawState == "BUILDING")
  #expect(!model.showsHeaderProgress)

  await model.refreshDeploymentActivity()
  #expect(model.projects[0].healthState == .ready)
  #expect(model.projects[0].rawState == "READY")
  #expect(model.errorMessage == nil)

  let callCounts = await client.callCounts
  #expect(callCounts == FakeVercelClient.CallCounts(
    inspectConnection: 1,
    fetchProjectSnapshot: 1,
    fetchRecentProductionDeployments: 2
  ))
}

@MainActor
@Test func preservesLastGoodMergedUIAfterDeploymentPollingFailure() async {
  let client = FakeVercelClient(
    connectionStates: [.connected],
    projectResults: [.success(snapshot(projects: [readyProject()]))],
    deploymentResults: [
      .success([deployment(state: "BUILDING")]),
      .failure(FakeVercelClientError.deploymentTransient)
    ]
  )
  let model = VercelStatusModel(client: client)

  await model.refresh()
  let lastGoodProjects = model.projects
  #expect(lastGoodProjects[0].healthState == .inProgress)

  await model.refreshDeploymentActivity()
  #expect(model.projects == lastGoodProjects)
  #expect(model.connectionState == .connected)
  #expect(model.errorMessage == "Temporary Vercel deployment failure")
}

private actor FakeVercelClient: VercelCLIClientProtocol {
  struct CallCounts: Equatable, Sendable {
    let inspectConnection: Int
    let fetchProjectSnapshot: Int
    let fetchRecentProductionDeployments: Int
  }

  private var connectionStates: [VercelConnectionState]
  private var projectResults: [Result<VercelProjectSnapshot, Error>]
  private var deploymentResults: [Result<[VercelAPIRecentDeployment], Error>]
  private var inspectConnectionCallCount = 0
  private var fetchProjectSnapshotCallCount = 0
  private var fetchRecentProductionDeploymentsCallCount = 0

  init(
    connectionStates: [VercelConnectionState],
    projectResults: [Result<VercelProjectSnapshot, Error>],
    deploymentResults: [Result<[VercelAPIRecentDeployment], Error>]
  ) {
    self.connectionStates = connectionStates
    self.projectResults = projectResults
    self.deploymentResults = deploymentResults
  }

  func inspectConnection() async -> VercelConnectionState {
    inspectConnectionCallCount += 1
    return connectionStates.isEmpty ? .connected : connectionStates.removeFirst()
  }

  func login() async throws {}

  func fetchProjectSnapshot() async throws -> VercelProjectSnapshot {
    fetchProjectSnapshotCallCount += 1
    guard !projectResults.isEmpty else {
      return VercelProjectSnapshot(scope: nil, projects: [])
    }
    return try projectResults.removeFirst().get()
  }

  func fetchRecentProductionDeployments() async throws -> [VercelAPIRecentDeployment] {
    fetchRecentProductionDeploymentsCallCount += 1
    guard !deploymentResults.isEmpty else {
      return []
    }
    return try deploymentResults.removeFirst().get()
  }

  var callCounts: CallCounts {
    CallCounts(
      inspectConnection: inspectConnectionCallCount,
      fetchProjectSnapshot: fetchProjectSnapshotCallCount,
      fetchRecentProductionDeployments: fetchRecentProductionDeploymentsCallCount
    )
  }
}

private enum FakeVercelClientError: LocalizedError {
  case projectTransient
  case deploymentTransient

  var errorDescription: String? {
    switch self {
    case .projectTransient:
      return "Temporary Vercel project failure"
    case .deploymentTransient:
      return "Temporary Vercel deployment failure"
    }
  }
}

private func readyProject() -> VercelProjectStatus {
  VercelProjectStatus(
    id: "project",
    name: "PortDeck",
    productionDeploymentID: "ready-deployment",
    productionURLString: "https://portdeck.app",
    healthState: .ready,
    rawState: "READY",
    deploymentCreatedAt: Date(timeIntervalSince1970: 1_780_000_000)
  )
}

private func deployment(state: String) -> VercelAPIRecentDeployment {
  VercelAPIRecentDeployment(
    uid: "new-deployment",
    projectId: "project",
    target: "production",
    state: state,
    readyState: nil,
    createdAt: 1_790_000_000_000,
    url: "portdeck-new.vercel.app"
  )
}

private func snapshot(projects: [VercelProjectStatus]) -> VercelProjectSnapshot {
  VercelProjectSnapshot(
    scope: VercelScope(id: "team", name: "PortDeck Team", slug: "portdeck"),
    projects: projects
  )
}
