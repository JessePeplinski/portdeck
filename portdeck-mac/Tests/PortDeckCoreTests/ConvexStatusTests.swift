import Foundation
import Testing
@testable import PortDeckCore

@Test func buildsConvexHealthStatesAndCountsWithoutRejectingFutureInsightKinds() {
  let candidate = ConvexProjectCandidate(projectName: "PortDeck", packageName: nil, packagePath: "/repo")
  #expect(candidate.id == "convex|/repo")
  let warning = insight(kind: "occRetried", severity: "warning")
  let error = insight(kind: "futureLimit", severity: "error")

  let healthy = ConvexProjectStatusBuilder.build(
    candidate: candidate,
    target: target(),
    response: response(insights: []),
    checkedAt: Date(timeIntervalSince1970: 100)
  )
  let warned = ConvexProjectStatusBuilder.build(
    candidate: candidate,
    target: target(),
    response: response(insights: [warning]),
    checkedAt: Date()
  )
  let failed = ConvexProjectStatusBuilder.build(
    candidate: candidate,
    target: target(),
    response: response(insights: [warning, error]),
    checkedAt: Date()
  )
  let unknownSeverity = ConvexProjectStatusBuilder.build(
    candidate: candidate,
    target: target(),
    response: response(insights: [insight(kind: "futureKind", severity: "notice")]),
    checkedAt: Date()
  )

  #expect(healthy.healthState == .healthy)
  #expect(warned.healthState == .warning)
  #expect(warned.warningCount == 1)
  #expect(failed.healthState == .error)
  #expect(failed.errorCount == 1)
  #expect(unknownSeverity.healthState == .unavailable)
  #expect(unknownSeverity.message != nil)
}

@Test func sortsAndSearchesConvexProjectsAcrossProviderMetadata() {
  let healthy = status(name: "Alpha", state: .healthy, insights: [])
  let warned = status(
    name: "Beta",
    state: .warning,
    insights: [insight(kind: "documentsReadThreshold", severity: "warning", function: "messages:list")]
  )
  let failed = status(name: "Gamma", state: .error, insights: [insight(kind: "bytesReadLimit", severity: "error")])
  let unavailable = status(name: "Delta", state: .unavailable, insights: [])

  #expect(ConvexProjectStatusBuilder.sorted([healthy, unavailable, warned, failed]).map(\.displayName) == [
    "Gamma", "Beta", "Alpha", "Delta"
  ])
  #expect(warned.matchesSearch("documentsRead"))
  #expect(warned.matchesSearch("messages:list"))
  #expect(warned.matchesSearch("deployment-beta"))
  #expect(!warned.matchesSearch("vercel"))
}

private func response(insights: [ConvexInsight]) -> ConvexInsightsResponse {
  ConvexInsightsResponse(
    deploymentName: "steady-otter-123",
    dashboardUrl: "https://dashboard.convex.dev/d/steady-otter-123?view=insights",
    insights: insights
  )
}

private func insight(
  kind: String,
  severity: String,
  function: String = "tasks:run"
) -> ConvexInsight {
  ConvexInsight(
    kind: kind,
    severity: severity,
    functionId: function,
    componentPath: nil,
    occCalls: 2,
    count: nil
  )
}

private func status(name: String, state: ConvexHealthState, insights: [ConvexInsight]) -> ConvexProjectStatus {
  ConvexProjectStatus(
    candidate: ConvexProjectCandidate(projectName: name, packageName: nil, packagePath: "/repo/\(name)"),
    deploymentName: "deployment-\(name.lowercased())",
    dashboardURLString: "https://dashboard.convex.dev/d/\(name)",
    insights: insights,
    healthState: state,
    availability: state == .unavailable ? .unavailable : .ready,
    productionLastDeployTime: Date(timeIntervalSince1970: 90),
    lastChecked: Date(),
    message: nil
  )
}

private func target() -> ConvexProductionTarget {
  ConvexProductionTarget(
    teamSlug: "team",
    projectName: "PortDeck",
    projectSlug: "portdeck",
    deploymentName: "steady-otter-123",
    lastDeployTime: Date(timeIntervalSince1970: 90)
  )
}
