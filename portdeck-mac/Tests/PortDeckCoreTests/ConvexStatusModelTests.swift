import Foundation
import PortDeckCore
import Testing
@testable import PortDeckMac

@Test func usesMinuteConvexPollingAndPresentsLastCheckedAge() {
  #expect(ConvexStatusModel.refreshIntervalSeconds == 60)
  #expect(convexLastCheckedLabel(ageSeconds: 4) == "Checked 4s ago")

  let lastUpdated = Date(timeIntervalSince1970: 100)
  #expect(convexPollingAgeSeconds(lastUpdated: lastUpdated, relativeTo: lastUpdated) == 0)
  #expect(convexPollingAgeSeconds(
    lastUpdated: lastUpdated,
    relativeTo: Date(timeIntervalSince1970: 104.9)
  ) == 4)
  #expect(convexPollingAgeSeconds(
    lastUpdated: lastUpdated,
    relativeTo: Date(timeIntervalSince1970: 99)
  ) == 0)
}

@MainActor
@Test func refreshesConvexCandidatesAndPreservesLastSuccessfulHealthAfterTransientFailure() async {
  let candidate = ConvexProjectCandidate(projectName: "PortDeck", packageName: nil, packagePath: "/repo")
  let client = FakeConvexClient(results: [
    .success(response(insights: [])),
    .failure(FakeConvexError.transient)
  ])
  let model = ConvexStatusModel(
    client: client,
    resolver: FakeConvexResolver(candidates: [candidate]),
    productionTargetResolver: FakeProductionTargetResolver()
  )

  await model.refresh(status: nil)
  #expect(model.projects.count == 1)
  #expect(model.projects[0].healthState == .healthy)
  let lastChecked = model.projects[0].lastChecked

  await model.refresh(status: nil)
  #expect(model.projects[0].healthState == .healthy)
  #expect(model.projects[0].lastChecked == lastChecked)
  #expect(model.projects[0].message == "Temporary Convex failure")
}

@MainActor
@Test func degradesManagedRuntimeFailuresWithoutLosingProductionMetadataAndRefreshesChangedCandidates() async {
  let first = ConvexProjectCandidate(projectName: "Old", packageName: nil, packagePath: "/old")
  let second = ConvexProjectCandidate(projectName: "New", packageName: nil, packagePath: "/new")
  let resolver = MutableConvexResolver(candidates: [first])
  let client = FakeConvexClient(results: [
    .failure(ConvexCLIError.missingRuntime),
    .success(response(insights: [insight(severity: "warning")]))
  ])
  let model = ConvexStatusModel(
    client: client,
    resolver: resolver,
    productionTargetResolver: FakeProductionTargetResolver()
  )

  await model.refresh(status: nil)
  #expect(model.projects[0].availability == .unavailable)
  #expect(model.projects[0].healthState == .unavailable)
  #expect(model.projects[0].healthState.title == "Health unavailable")
  #expect(model.projects[0].deploymentName == "steady-otter-123")
  #expect(model.projects[0].dashboardURLString == "https://dashboard.convex.dev/d/steady-otter-123?view=insights")
  #expect(model.projects[0].productionLastDeployTime == Date(timeIntervalSince1970: 1_750_000_000))

  resolver.setCandidates([second])
  await model.updateCandidates(from: nil)
  #expect(model.projects.map(\.projectName) == ["New"])
  #expect(model.projects[0].healthState == .warning)
}

@MainActor
@Test func connectsWithTheManagedRuntimeThenRefreshesAllCandidates() async {
  let candidate = ConvexProjectCandidate(projectName: "PortDeck", packageName: nil, packagePath: "/repo")
  let client = FakeConvexClient(results: [
    .failure(ConvexCLIError.unauthenticated),
    .success(response(insights: []))
  ])
  let model = ConvexStatusModel(
    client: client,
    resolver: FakeConvexResolver(candidates: [candidate]),
    productionTargetResolver: FakeProductionTargetResolver()
  )

  await model.refresh(status: nil)
  #expect(model.needsAuthentication)
  await model.connect(using: candidate)
  #expect(!model.needsAuthentication)
  #expect(model.projects[0].healthState == .healthy)
  #expect(await client.loginCandidates == [candidate])
}

private actor FakeConvexClient: ConvexCLIClientProtocol {
  private var results: [Result<ConvexInsightsResponse, Error>]
  private(set) var loginCandidates: [ConvexProjectCandidate] = []

  init(results: [Result<ConvexInsightsResponse, Error>]) {
    self.results = results
  }

  func fetchProductionHealth(
    for candidate: ConvexProjectCandidate,
    target: ConvexProductionTarget
  ) async throws -> ConvexInsightsResponse {
    guard !results.isEmpty else { throw FakeConvexError.missingResult }
    return try results.removeFirst().get()
  }

  func login(using candidate: ConvexProjectCandidate) async throws {
    loginCandidates.append(candidate)
  }
}

private struct FakeProductionTargetResolver: ConvexProductionTargetResolving {
  func resolveProductionTarget(for candidate: ConvexProjectCandidate) async throws -> ConvexProductionTarget {
    ConvexProductionTarget(
      teamSlug: "team",
      projectName: candidate.projectName,
      projectSlug: "demo",
      deploymentName: "steady-otter-123",
      lastDeployTime: Date(timeIntervalSince1970: 1_750_000_000)
    )
  }
}

private struct FakeConvexResolver: ConvexProjectCandidateResolving {
  let candidates: [ConvexProjectCandidate]
  func resolve(from status: PortdeckStatus?) -> [ConvexProjectCandidate] { candidates }
}

private final class MutableConvexResolver: ConvexProjectCandidateResolving, @unchecked Sendable {
  private var candidates: [ConvexProjectCandidate]

  init(candidates: [ConvexProjectCandidate]) {
    self.candidates = candidates
  }

  func resolve(from status: PortdeckStatus?) -> [ConvexProjectCandidate] { candidates }

  func setCandidates(_ candidates: [ConvexProjectCandidate]) {
    self.candidates = candidates
  }
}

private enum FakeConvexError: LocalizedError {
  case transient
  case missingResult

  var errorDescription: String? {
    switch self {
    case .transient: return "Temporary Convex failure"
    case .missingResult: return "Missing fake Convex result"
    }
  }
}

private func response(insights: [ConvexInsight]) -> ConvexInsightsResponse {
  ConvexInsightsResponse(
    deploymentName: "steady-otter-123",
    dashboardUrl: "https://dashboard.convex.dev/d/steady-otter-123?view=insights",
    insights: insights
  )
}

private func insight(severity: String) -> ConvexInsight {
  ConvexInsight(
    kind: "occRetried",
    severity: severity,
    functionId: "tasks:run",
    componentPath: nil,
    occCalls: 1,
    count: nil
  )
}
