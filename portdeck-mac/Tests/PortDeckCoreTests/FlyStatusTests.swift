import Foundation
import Testing
@testable import PortDeckCore

@Test func mapsPinnedFlyStatusesAndUnknownValuesConservatively() {
  #expect(FlyAppState.map("deployed") == .deployed)
  #expect(FlyAppState.map("suspended") == .suspended)
  #expect(FlyAppState.map("future") == .unknown)

  let machineCases: [(String, FlyMachineState)] = [
    ("started", .running), ("stopped", .stopped), ("suspended", .suspended),
    ("created", .starting), ("destroying", .removing), ("destroyed", .removed),
    ("future", .unknown)
  ]
  for (raw, expected) in machineCases { #expect(FlyMachineState.map(raw) == expected) }

  #expect(FlyHostState.map("ok") == .reachable)
  #expect(FlyHostState.map("unreachable") == .unreachable)
  #expect(FlyHostState.map("future") == .unknown)
  #expect(FlyCheckState.map("passing") == .passing)
  #expect(FlyCheckState.map("warning") == .warning)
  #expect(FlyCheckState.map("critical") == .critical)
  #expect(FlyCheckState.map("future") == .unknown)

  #expect(FlyReleaseState.map("complete") == .successful)
  #expect(FlyReleaseState.map("failed") == .failed)
  #expect(FlyReleaseState.map("interrupted") == .failed)
  #expect(FlyReleaseState.map("pending") == .inProgress)
  #expect(FlyReleaseState.map("running") == .inProgress)
  #expect(FlyReleaseState.map("future") == .unknown)
}

@Test func flyHealthEvidenceDoesNotCallNoChecksHealthy() {
  let healthyCheck = FlyMachineCheck(name: "http", rawStatus: "passing", updatedAt: nil)
  let noChecks = flyApp(machines: [flyMachine(checks: [])])
  #expect(noChecks.evidenceState == .unknown)

  let healthy = flyApp(machines: [flyMachine(checks: [healthyCheck])])
  #expect(healthy.evidenceState == .healthy)

  let warning = flyApp(machines: [flyMachine(checks: [
    FlyMachineCheck(name: "http", rawStatus: "warning", updatedAt: nil)
  ])])
  #expect(warning.evidenceState == .degraded)

  let critical = flyApp(machines: [flyMachine(checks: [
    FlyMachineCheck(name: "http", rawStatus: "critical", updatedAt: nil)
  ])])
  #expect(critical.evidenceState == .unhealthy)

  let unreachable = flyApp(machines: [flyMachine(host: "unreachable", checks: [healthyCheck])])
  #expect(unreachable.evidenceState == .unhealthy)
}

@Test func buildsOnlySafeFlyURLsAndSearchesAllRenderedFields() throws {
  let release = FlyRelease(
    id: "release-8", version: 8, rawStatus: "running", description: "Canary rollout",
    createdAt: Date(timeIntervalSince1970: 100)
  )
  let app = FlyApp(
    id: "app-1", name: "demo-api", rawStatus: "deployed", deployed: true,
    organization: FlyOrganization(slug: "demo-team", name: "Demo Team"),
    hostname: "demo-api.fly.dev", appURLString: "https://demo-api.fly.dev",
    currentReleaseVersion: 8,
    machines: [FlyMachine(
      id: "machine-1", name: "blue-sun", rawState: "started", region: "ord",
      rawHostStatus: "ok", checks: [FlyMachineCheck(name: "readiness", rawStatus: "passing", updatedAt: nil)]
    )],
    latestRelease: release
  )

  #expect(app.productionURL?.absoluteString == "https://demo-api.fly.dev")
  #expect(app.dashboardURL?.absoluteString == "https://fly.io/apps/demo-api")
  #expect(FlyStatusBuilder.safeHTTPSURL("http://demo-api.fly.dev") == nil)
  #expect(FlyStatusBuilder.safeHTTPSURL("https://user:pass@demo-api.fly.dev") == nil)
  #expect(FlyStatusBuilder.dashboardURL(appName: "../secret") == nil)

  for query in ["demo team", "fly.dev", "deployed", "blue-sun", "machine-1", "ord", "readiness", "passing", "v8", "canary"] {
    #expect(app.matchesSearch(query))
  }
}

@Test func sortsFlyAppsByEvidenceThenOrganizationAndName() {
  let passing = FlyMachineCheck(name: "http", rawStatus: "passing", updatedAt: nil)
  let healthy = flyApp(id: "healthy", name: "Zulu", organization: "B Team", machines: [flyMachine(checks: [passing])])
  let unhealthy = flyApp(
    id: "unhealthy", name: "Alpha", organization: "A Team",
    machines: [flyMachine(host: "unreachable", checks: [passing])]
  )
  let transitioning = FlyApp(
    id: "transition", name: "Beta", rawStatus: "deployed", deployed: true,
    organization: FlyOrganization(slug: "a-team", name: "A Team"),
    latestRelease: FlyRelease(id: "release", version: 2, rawStatus: "running", description: nil, createdAt: nil)
  )
  #expect(FlyStatusBuilder.sortedApps([healthy, transitioning, unhealthy]).map(\.id) == ["unhealthy", "transition", "healthy"])
}

private func flyMachine(host: String = "ok", checks: [FlyMachineCheck]) -> FlyMachine {
  FlyMachine(id: "machine", name: "machine", rawState: "started", region: "ord", rawHostStatus: host, checks: checks)
}

private func flyApp(
  id: String = "app", name: String = "App", organization: String = "Team", machines: [FlyMachine]
) -> FlyApp {
  FlyApp(
    id: id, name: name, rawStatus: "deployed", deployed: true,
    organization: FlyOrganization(slug: organization.lowercased().replacingOccurrences(of: " ", with: "-"), name: organization),
    machines: machines
  )
}
