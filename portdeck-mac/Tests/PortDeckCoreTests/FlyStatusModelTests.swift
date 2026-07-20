import Foundation
import PortDeckCore
import Testing
@testable import PortDeckMac

@MainActor
@Test func flyModelPreservesScopedAndGlobalLastGoodSnapshots() async throws {
  let initial = flyModelApp(version: 8)
  let freshWithoutEnrichment = FlyApp(
    id: initial.id, name: initial.name, rawStatus: "deployed", deployed: true,
    organization: initial.organization, hostname: initial.hostname,
    appURLString: initial.appURLString, currentReleaseVersion: 8
  )
  let client = FakeFlyClient(results: [
    .success(FlySnapshotResult(
      organizations: [initial.organization], apps: [initial],
      successfulStatusAppKeys: [initial.identityKey], successfulReleaseAppKeys: [initial.identityKey]
    )),
    .success(FlySnapshotResult(
      organizations: [initial.organization], apps: [freshWithoutEnrichment],
      failures: [
        .init(appKey: initial.identityKey, appName: initial.name, scope: .status, message: "Status unavailable"),
        .init(appKey: initial.identityKey, appName: initial.name, scope: .release, message: "Release unavailable")
      ]
    )),
    .failure(FlyCLIError.rateLimited)
  ])
  let model = FlyStatusModel(client: client, now: { Date(timeIntervalSince1970: 100) })

  await model.refresh()
  #expect(model.apps.first?.machines.count == 1)
  #expect(model.apps.first?.latestRelease?.version == 8)
  #expect(model.lastSuccessfulRefreshAt == Date(timeIntervalSince1970: 100))

  await model.refresh()
  #expect(model.apps.first?.machines.count == 1)
  #expect(model.apps.first?.isStatusRetained == true)
  #expect(model.apps.first?.latestRelease?.version == 8)
  #expect(model.apps.first?.isReleaseRetained == true)
  #expect(model.connectionState == .connected)
  #expect(model.errorMessage?.contains("Status unavailable") == true)

  await model.refresh()
  #expect(model.apps.first?.machines.count == 1)
  #expect(model.isRetainingSnapshot)
  if case .rateLimited = model.connectionState {} else { Issue.record("Expected rate-limited state") }
}

@MainActor
@Test func flyModelReplacesLegitimateEmptiesAndRemovesAbsentApps() async {
  let app = flyModelApp(version: 8)
  let client = FakeFlyClient(results: [
    .success(FlySnapshotResult(
      organizations: [app.organization], apps: [app],
      successfulStatusAppKeys: [app.identityKey], successfulReleaseAppKeys: [app.identityKey]
    )),
    .success(FlySnapshotResult(organizations: [app.organization], apps: []))
  ])
  let model = FlyStatusModel(client: client)
  await model.refresh()
  #expect(model.filteredApps(matching: "ord").count == 1)
  await model.refresh()
  #expect(model.apps.isEmpty)
  #expect(model.organizations == [app.organization])
}

@MainActor
@Test func flyModelDoesNotAttachStaleReleaseToNewCurrentVersion() async {
  let initial = flyModelApp(version: 8)
  let next = FlyApp(
    id: initial.id, name: initial.name, rawStatus: "deployed", deployed: true,
    organization: initial.organization, hostname: initial.hostname,
    appURLString: initial.appURLString, currentReleaseVersion: 9,
    machines: initial.machines
  )
  let client = FakeFlyClient(results: [
    .success(FlySnapshotResult(
      organizations: [initial.organization], apps: [initial],
      successfulStatusAppKeys: [initial.identityKey], successfulReleaseAppKeys: [initial.identityKey]
    )),
    .success(FlySnapshotResult(
      organizations: [initial.organization], apps: [next],
      successfulStatusAppKeys: [next.identityKey],
      failures: [.init(appKey: next.identityKey, appName: next.name, scope: .release, message: "Release unavailable")]
    ))
  ])
  let model = FlyStatusModel(client: client)
  await model.refresh()
  await model.refresh()
  #expect(model.apps.first?.currentReleaseVersion == 9)
  #expect(model.apps.first?.latestRelease == nil)
  #expect(model.apps.first?.isReleaseRetained == false)
}

@MainActor
@Test func flyModelRejectsOverlappingRefreshesAndPollsUntilCancelled() async throws {
  let client = FakeFlyClient(
    results: Array(repeating: .success(FlySnapshotResult(organizations: [], apps: [])), count: 20),
    delay: .milliseconds(20)
  )
  let model = FlyStatusModel(client: client, pollInterval: .milliseconds(5))

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
@Test func flyModelMapsSetupFailuresAndIgnoresCancellation() async {
  let cases: [(FlyCLIError, FlyConnectionState)] = [
    (.missingRuntime, .missingRuntime),
    (.incompatibleRuntime(currentVersion: "flyctl 0.4.70 darwin/arm64"), .incompatibleRuntime(currentVersion: "flyctl 0.4.70 darwin/arm64")),
    (.authenticationRequired, .authenticationRequired),
    (.rateLimited, .rateLimited(message: FlyCLIError.rateLimited.localizedDescription))
  ]
  for (error, expected) in cases {
    let model = FlyStatusModel(client: FakeFlyClient(results: [.failure(error)]))
    await model.refresh()
    #expect(model.connectionState == expected)
  }

  let cancelled = FlyStatusModel(client: FakeFlyClient(results: [.failure(FlyCLIError.cancelled)]))
  await cancelled.refresh()
  #expect(cancelled.connectionState == .checking)
  #expect(cancelled.errorMessage == nil)
}

@MainActor
@Test func flyModelCancelsTheSharedRefreshWhenItsOwnerLeaves() async throws {
  let client = FakeFlyClient(
    results: [.success(FlySnapshotResult(organizations: [], apps: []))],
    delay: .seconds(1)
  )
  let model = FlyStatusModel(client: client)
  let refresh = Task { await model.refresh() }

  while await client.callCount == 0 {
    try await Task.sleep(for: .milliseconds(2))
  }
  model.cancelRefresh()
  await refresh.value

  #expect(await client.cancellationCount == 1)
  #expect(!model.isRefreshing)
  #expect(model.connectionState == .checking)
  #expect(model.apps.isEmpty)
}

private actor FakeFlyClient: FlyCLIClientProtocol {
  private var results: [Result<FlySnapshotResult, FlyCLIError>]
  private let delay: Duration
  private(set) var callCount = 0
  private(set) var cancellationCount = 0

  init(results: [Result<FlySnapshotResult, FlyCLIError>], delay: Duration = .zero) {
    self.results = results
    self.delay = delay
  }

  func fetchSnapshot() async throws -> FlySnapshotResult {
    callCount += 1
    if delay != .zero {
      do { try await Task.sleep(for: delay) }
      catch {
        cancellationCount += 1
        throw FlyCLIError.cancelled
      }
    }
    guard !results.isEmpty else { return FlySnapshotResult(organizations: [], apps: []) }
    return try results.removeFirst().get()
  }
}

private func flyModelApp(version: Int) -> FlyApp {
  let organization = FlyOrganization(slug: "demo-team", name: "Demo Team")
  return FlyApp(
    id: "app-1", name: "demo-api", rawStatus: "deployed", deployed: true,
    organization: organization, hostname: "demo-api.fly.dev",
    appURLString: "https://demo-api.fly.dev", currentReleaseVersion: version,
    machines: [FlyMachine(
      id: "machine-1", name: "blue-sun", rawState: "started", region: "ord",
      rawHostStatus: "ok", checks: [FlyMachineCheck(name: "http", rawStatus: "passing", updatedAt: nil)]
    )],
    latestRelease: FlyRelease(
      id: "release-\(version)", version: version, rawStatus: "complete",
      description: "Release \(version)", createdAt: nil
    )
  )
}
