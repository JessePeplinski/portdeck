import Foundation
import Testing
@testable import PortDeckCore

@Test func mapsVerifiedRailwayStatusesAndFutureValuesDefensively() {
  let expected: [RailwayResourceState: [String]] = [
    .successful: ["SUCCESS"],
    .failed: ["FAILED"],
    .crashed: ["CRASHED"],
    .deploying: ["BUILDING", "DEPLOYING", "INITIALIZING"],
    .queued: ["WAITING", "QUEUED"],
    .removing: ["REMOVING"],
    .removed: ["REMOVED"],
    .unknown: ["SLEEPING", "NEEDS_APPROVAL", "FUTURE_STATUS"]
  ]
  for (state, values) in expected {
    for value in values { #expect(RailwayResourceState.map(value) == state) }
  }
  #expect(RailwayResourceState.map(nil) == .unknown)
}

@Test func sortsSearchesAndBuildsOnlySafeRailwayLinks() throws {
  let workspace = RailwayWorkspace(id: "workspace-1", name: "Demo Team")
  let successful = railwayService(id: "successful", name: "Web", status: "SUCCESS", branch: "main", sha: "abcdef123456")
  let failed = railwayService(id: "failed", name: "API", status: "FAILED", branch: "release", sha: "deadbeef")
  let project = RailwayProject(
    id: "project-1",
    name: "Demo",
    workspace: workspace,
    productionEnvironmentID: "environment-1",
    services: [successful, failed]
  )

  #expect(RailwayStatusBuilder.sortedServices(project.services).map(\.id) == ["failed", "successful"])
  #expect(project.filtered(matching: "release")?.services.map(\.id) == ["failed"])
  #expect(project.filtered(matching: "demo team")?.services.count == 2)
  #expect(successful.matchesSearch("abcdef1"))
  #expect(successful.matchesSearch("us east"))
  #expect(successful.productionURL?.host == "web.example")
  #expect(project.dashboardURL?.host == "railway.com")
  #expect(project.dashboardURL?.query == "environmentId=environment-1")

  let unsafe = RailwayProject(
    id: "../project", name: "Unsafe", workspace: workspace, productionEnvironmentID: nil
  )
  #expect(unsafe.dashboardURL == nil)
  #expect(RailwayService(id: "x", name: "X", productionURLString: "javascript:alert(1)").productionURL == nil)
}

private func railwayService(id: String, name: String, status: String, branch: String, sha: String) -> RailwayService {
  RailwayService(
    id: id,
    name: name,
    currentRawStatus: status,
    latestDeployment: RailwayDeployment(
      id: "deployment-\(id)", rawStatus: status,
      createdAt: Date(timeIntervalSince1970: 1_750_000_000), branch: branch,
      commitSHA: sha, commitMessage: "Ship \(name)"
    ),
    productionURLString: "https://web.example",
    regions: [RailwayRegion(name: "us-east4-eqdc4a", location: "US East", configured: 1)],
    replicas: RailwayReplicas(configured: 1, running: 1, crashed: 0, exited: 0, total: 1)
  )
}
