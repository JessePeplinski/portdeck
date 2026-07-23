import Foundation
import PortDeckCore
import Testing
@testable import PortDeckMac

@MainActor
@Test func netlifyModelPreservesScopedAndGlobalLastGoodSnapshots() async {
  let initial = netlifyModelSite(state: "ready")
  let fresh = NetlifySite(
    id: initial.id, name: initial.name, account: initial.account,
    productionURLString: initial.productionURLString, dashboardURLString: initial.dashboardURLString,
    hasDeploymentFailure: true
  )
  let client = FakeNetlifyClient(results: [
    .success(NetlifySnapshotResult(
      sites: [initial], successfulDeploymentSiteIDs: [initial.id]
    )),
    .success(NetlifySnapshotResult(
      sites: [fresh],
      failures: [.init(siteID: initial.id, siteName: initial.name, message: "Deployment unavailable")]
    )),
    .failure(NetlifyCLIError.rateLimited)
  ])
  let model = NetlifyStatusModel(client: client, now: { Date(timeIntervalSince1970: 100) })

  await model.refresh()
  #expect(model.sites.first?.latestDeployment?.rawState == "ready")
  #expect(model.lastSuccessfulRefreshAt == Date(timeIntervalSince1970: 100))

  await model.refresh()
  #expect(model.sites.first?.latestDeployment?.rawState == "ready")
  #expect(model.sites.first?.isDeploymentRetained == true)
  #expect(model.sites.first?.hasDeploymentFailure == true)
  #expect(model.connectionState == .connected)
  #expect(model.errorMessage?.contains("Deployment unavailable") == true)

  await model.refresh()
  #expect(model.sites.first?.latestDeployment?.rawState == "ready")
  #expect(model.isRetainingSnapshot)
  if case .rateLimited = model.connectionState {} else { Issue.record("Expected rate-limited state") }
}

@MainActor
@Test func netlifyModelTreatsMembershipAndEmptyDeploymentsAsAuthoritative() async {
  let first = netlifyModelSite(id: "one", state: "ready")
  let removed = netlifyModelSite(id: "two", state: "error")
  let noDeployment = NetlifySite(id: first.id, name: first.name, account: first.account)
  let client = FakeNetlifyClient(results: [
    .success(NetlifySnapshotResult(
      sites: [first, removed], successfulDeploymentSiteIDs: [first.id, removed.id]
    )),
    .success(NetlifySnapshotResult(
      sites: [noDeployment], successfulDeploymentSiteIDs: [first.id]
    )),
    .success(NetlifySnapshotResult(sites: []))
  ])
  let model = NetlifyStatusModel(client: client)

  await model.refresh()
  #expect(model.sites.count == 2)
  await model.refresh()
  #expect(model.sites.map(\.id) == [first.id])
  #expect(model.sites.first?.latestDeployment == nil)
  #expect(!model.sites.first!.isDeploymentRetained)
  await model.refresh()
  #expect(model.sites.isEmpty)
}

@MainActor
@Test func netlifyModelRejectsOverlapPollsAndCancelsOwnerTask() async throws {
  let client = FakeNetlifyClient(
    results: Array(repeating: .success(NetlifySnapshotResult(sites: [])), count: 20),
    delay: .milliseconds(20)
  )
  let model = NetlifyStatusModel(client: client, pollInterval: .milliseconds(5))

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

  let slowClient = FakeNetlifyClient(
    results: [.success(NetlifySnapshotResult(sites: [netlifyModelSite(state: "ready")]))],
    delay: .seconds(1)
  )
  let slowModel = NetlifyStatusModel(client: slowClient)
  let refresh = Task { await slowModel.refresh() }
  while await slowClient.callCount == 0 { try await Task.sleep(for: .milliseconds(2)) }
  slowModel.cancelRefresh()
  await refresh.value
  #expect(await slowClient.cancellationCount == 1)
  #expect(!slowModel.isRefreshing)
  #expect(slowModel.connectionState == .checking)
  #expect(slowModel.sites.isEmpty)
}

@MainActor
@Test func netlifyModelMapsSetupFailuresAndIgnoresCancellation() async {
  let cases: [(NetlifyCLIError, NetlifyConnectionState)] = [
    (.missingCLI, .missingCLI),
    (.unsupportedCLI(currentVersion: "netlify-cli/25.0.0"), .unsupportedCLI(currentVersion: "netlify-cli/25.0.0")),
    (.authenticationRequired, .authenticationRequired),
    (.rateLimited, .rateLimited(message: NetlifyCLIError.rateLimited.localizedDescription))
  ]
  for (error, expected) in cases {
    let model = NetlifyStatusModel(client: FakeNetlifyClient(results: [.failure(error)]))
    await model.refresh()
    #expect(model.connectionState == expected)
  }

  let cancelled = NetlifyStatusModel(client: FakeNetlifyClient(results: [.failure(.cancelled)]))
  await cancelled.refresh()
  #expect(cancelled.connectionState == .checking)
  #expect(cancelled.errorMessage == nil)
}

private actor FakeNetlifyClient: NetlifyCLIClientProtocol {
  private var results: [Result<NetlifySnapshotResult, NetlifyCLIError>]
  private let delay: Duration
  private(set) var callCount = 0
  private(set) var cancellationCount = 0

  init(results: [Result<NetlifySnapshotResult, NetlifyCLIError>], delay: Duration = .zero) {
    self.results = results
    self.delay = delay
  }

  func fetchSnapshot() async throws -> NetlifySnapshotResult {
    callCount += 1
    if delay != .zero {
      do { try await Task.sleep(for: delay) }
      catch {
        cancellationCount += 1
        throw NetlifyCLIError.cancelled
      }
    }
    guard !results.isEmpty else { return NetlifySnapshotResult(sites: []) }
    return try results.removeFirst().get()
  }
}

private func netlifyModelSite(id: String = "site-1", state: String) -> NetlifySite {
  let name = "demo-\(id)"
  let account = NetlifyAccount(id: "account-1", name: "Demo Team", slug: "demo-team")
  return NetlifySite(
    id: id, name: name, account: account,
    productionURLString: "https://\(name).netlify.app",
    dashboardURLString: "https://app.netlify.com/sites/\(name)",
    latestDeployment: NetlifyDeployment(
      id: "deploy-\(id)", siteID: id, rawState: state, context: "production",
      branch: "main", commitReference: "abcdef1234567890"
    )
  )
}
