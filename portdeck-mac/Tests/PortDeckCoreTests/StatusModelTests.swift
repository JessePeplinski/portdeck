import Foundation
import PortDeckCore
import Testing
@testable import PortDeckMac

@MainActor
@Test func localModelRetainsLastGoodSnapshotTimestampAndRecoversAfterTransientFailure() async throws {
  let first = modelTestStatus(generatedAt: "first", services: [modelTestService(id: "api")])
  let recovered = modelTestStatus(generatedAt: "recovered", services: [modelTestService(id: "web")])
  let loader = FakeLocalStatusLoader(loadResponses: [
    .success(LoadedPortdeckStatus(status: first, rawJSON: "first-json")),
    .failure(.temporary("TOKEN=super-secret transient failure")),
    .success(LoadedPortdeckStatus(status: recovered, rawJSON: "recovered-json"))
  ])
  let clock = LocalModelTestClock(Date(timeIntervalSince1970: 100))
  let model = StatusModel(
    userDefaults: isolatedLocalUserDefaults(),
    loader: loader,
    now: clock.now
  )

  await model.refresh()
  #expect(model.status?.generatedAt == "first")
  #expect(model.rawJSON == "first-json")
  #expect(model.lastUpdated == Date(timeIntervalSince1970: 100))
  #expect(model.errorMessage == nil)

  clock.set(Date(timeIntervalSince1970: 200))
  await model.refresh()
  #expect(model.status?.generatedAt == "first")
  #expect(model.rawJSON == "first-json")
  #expect(model.lastUpdated == Date(timeIntervalSince1970: 100))
  #expect(model.errorMessage?.contains("super-secret") == false)
  #expect(model.errorMessage?.contains("<redacted>") == true)

  clock.set(Date(timeIntervalSince1970: 300))
  await model.refresh()
  #expect(model.status?.generatedAt == "recovered")
  #expect(model.rawJSON == "recovered-json")
  #expect(model.lastUpdated == Date(timeIntervalSince1970: 300))
  #expect(model.errorMessage == nil)
}

@MainActor
@Test func localModelShowsUnavailableStateOnlyWhenTheInitialRefreshFails() async {
  let loader = FakeLocalStatusLoader(loadResponses: [.failure(.temporary("Initial failure"))])
  let model = StatusModel(userDefaults: isolatedLocalUserDefaults(), loader: loader)

  await model.refresh()

  #expect(model.status == nil)
  #expect(model.rawJSON.isEmpty)
  #expect(model.lastUpdated == nil)
  #expect(model.errorMessage == "Initial failure")
}

@MainActor
@Test func localModelPollsEveryConfiguredIntervalCancelsAndRejectsOverlap() async {
  #expect(StatusModel.refreshIntervalSeconds == 5)
  let snapshot = LoadedPortdeckStatus(status: modelTestStatus(generatedAt: "poll"), rawJSON: "poll")
  let pollingLoader = FakeLocalStatusLoader(
    loadResponses: Array(repeating: .success(snapshot), count: 10)
  )
  let pollingModel = StatusModel(
    userDefaults: isolatedLocalUserDefaults(),
    loader: pollingLoader,
    pollInterval: .milliseconds(10)
  )

  let pollingTask = Task { await pollingModel.runAutoRefresh() }
  await waitForLocalModel(timeout: .seconds(1)) {
    await pollingLoader.loadCallCount >= 3
  }
  pollingTask.cancel()
  await pollingTask.value
  let countAfterCancellation = await pollingLoader.loadCallCount
  try? await Task.sleep(for: .milliseconds(25))

  #expect(countAfterCancellation >= 3)
  #expect(await pollingLoader.loadCallCount == countAfterCancellation)

  let overlapLoader = FakeLocalStatusLoader(
    loadResponses: [.success(snapshot)],
    loadDelay: .milliseconds(30)
  )
  let overlapModel = StatusModel(userDefaults: isolatedLocalUserDefaults(), loader: overlapLoader)
  async let first: Void = overlapModel.refresh()
  try? await Task.sleep(for: .milliseconds(5))
  async let second: Void = overlapModel.refresh()
  _ = await (first, second)
  #expect(await overlapLoader.loadCallCount == 1)
}

@MainActor
@Test func localStopAndStopAllStillForceSuccessfulRefreshes() async {
  let serviceA = modelTestService(id: "api")
  let serviceB = modelTestService(id: "worker")
  let initial = modelTestStatus(generatedAt: "initial", services: [serviceA, serviceB])
  let afterStop = modelTestStatus(generatedAt: "after-stop", services: [serviceB])
  let afterStopAll = modelTestStatus(generatedAt: "after-stop-all", services: [])
  let loader = FakeLocalStatusLoader(
    loadResponses: [
      .success(LoadedPortdeckStatus(status: initial, rawJSON: "initial")),
      .success(LoadedPortdeckStatus(status: afterStop, rawJSON: "after-stop")),
      .success(LoadedPortdeckStatus(status: afterStopAll, rawJSON: "after-stop-all"))
    ],
    stopResults: [
      PortdeckStopResult(ok: true, serviceId: serviceA.id, action: "stopped", message: "Stopped"),
      PortdeckStopResult(ok: true, serviceId: serviceA.id, action: "stopped", message: "Stopped"),
      PortdeckStopResult(ok: true, serviceId: serviceB.id, action: "stopped", message: "Stopped")
    ]
  )
  let model = StatusModel(userDefaults: isolatedLocalUserDefaults(), loader: loader)

  await model.refresh()
  model.requestStopService(serviceA)
  await waitForLocalModel {
    let stopCount = await loader.stopCallCount
    let loadCount = await loader.loadCallCount
    return stopCount == 1 && loadCount == 2
  }
  #expect(model.status?.generatedAt == "after-stop")
  #expect(model.stopFailureMessage == nil)

  model.requestStopAll(ProjectStopAllTarget(
    projectID: "project",
    projectName: "PortDeck",
    services: [serviceA, serviceB]
  ))
  await waitForLocalModel {
    let stopCount = await loader.stopCallCount
    let loadCount = await loader.loadCallCount
    return stopCount == 3 && loadCount == 3
  }
  #expect(model.status?.generatedAt == "after-stop-all")
  #expect(model.stopFailureMessage == nil)
}

@MainActor
@Test func savedProjectStartSurfacesOccupiedPortSuggestionAndRefreshesStatus() async {
  let saved = SavedProjectStatus(
    id: "saved-portdeck",
    state: "stopped",
    port: 3000,
    supportsPortSwitching: true,
    logPath: nil,
    lastError: nil,
    previousPort: nil
  )
  let snapshot = LoadedPortdeckStatus(
    status: modelTestStatus(generatedAt: "saved-project"),
    rawJSON: "saved-project"
  )
  let result = SavedProjectRunResult(
    ok: false,
    projectId: saved.id,
    action: "port-occupied",
    message: "Port 3000 is already in use.",
    state: "stopped",
    port: 3000,
    previousPort: 3000,
    suggestedPort: 3001,
    logPath: nil
  )
  let loader = FakeSavedProjectStatusLoader(snapshot: snapshot, startResult: result)
  let model = StatusModel(userDefaults: isolatedLocalUserDefaults(), loader: loader)

  await model.refresh()
  model.requestStartProject(saved)
  await waitForLocalModel {
    let startCount = await loader.startCallCount
    let loadCount = await loader.loadCallCount
    return startCount == 1 && loadCount == 2
  }

  #expect(model.projectActionResult == result)
  #expect(model.projectActionResult?.suggestedPort == 3001)
  #expect(model.activeSavedProjectID == nil)
  #expect(model.isManagingSavedProject == false)
}

@Test func localRefreshErrorsAreBoundedAndCredentialRedacted() {
  let raw = "Authorization: Bearer abcdefghijklmnopqrstuvwxyz " + String(repeating: "failure ", count: 100)
  let message = localStatusErrorMessage(raw, limit: 80)

  #expect(message.count == 80)
  #expect(message.contains("abcdefghijklmnopqrstuvwxyz") == false)
  #expect(message.contains("<redacted>") == true)
  #expect(message.hasSuffix("…"))
}

private actor FakeLocalStatusLoader: PortdeckStatusLoading {
  enum LoadResponse: Sendable {
    case success(LoadedPortdeckStatus)
    case failure(LocalModelTestError)
  }

  private var loadResponses: [LoadResponse]
  private var stopResults: [PortdeckStopResult]
  private let loadDelay: Duration?
  private(set) var loadCallCount = 0
  private(set) var stopCallCount = 0

  init(
    loadResponses: [LoadResponse],
    stopResults: [PortdeckStopResult] = [],
    loadDelay: Duration? = nil
  ) {
    self.loadResponses = loadResponses
    self.stopResults = stopResults
    self.loadDelay = loadDelay
  }

  func load() async throws -> LoadedPortdeckStatus {
    loadCallCount += 1
    if let loadDelay { try await Task.sleep(for: loadDelay) }
    guard !loadResponses.isEmpty else { throw LocalModelTestError.temporary("No response") }
    switch loadResponses.removeFirst() {
    case .success(let snapshot):
      return snapshot
    case .failure(let error):
      throw error
    }
  }

  func stopService(id serviceId: String) async throws -> PortdeckStopResult {
    stopCallCount += 1
    guard !stopResults.isEmpty else {
      return PortdeckStopResult(ok: true, serviceId: serviceId, action: "stopped", message: "Stopped")
    }
    return stopResults.removeFirst()
  }
}

private actor FakeSavedProjectStatusLoader: PortdeckStatusLoading {
  private let snapshot: LoadedPortdeckStatus
  private let startResult: SavedProjectRunResult
  private(set) var loadCallCount = 0
  private(set) var startCallCount = 0

  init(snapshot: LoadedPortdeckStatus, startResult: SavedProjectRunResult) {
    self.snapshot = snapshot
    self.startResult = startResult
  }

  func load() async throws -> LoadedPortdeckStatus {
    loadCallCount += 1
    return snapshot
  }

  func stopService(id serviceId: String) async throws -> PortdeckStopResult {
    PortdeckStopResult(ok: true, serviceId: serviceId, action: "stopped", message: "Stopped")
  }

  func startProject(id projectId: String, port: Int?) async throws -> SavedProjectRunResult {
    startCallCount += 1
    return startResult
  }
}

private enum LocalModelTestError: Error, LocalizedError, Sendable {
  case temporary(String)

  var errorDescription: String? {
    switch self {
    case .temporary(let message): return message
    }
  }
}

private final class LocalModelTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) {
    self.date = date
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return date
  }

  func set(_ date: Date) {
    lock.lock()
    self.date = date
    lock.unlock()
  }
}

private func isolatedLocalUserDefaults() -> UserDefaults {
  let suiteName = "StatusModelTests.\(UUID().uuidString)"
  return UserDefaults(suiteName: suiteName) ?? .standard
}

private func waitForLocalModel(
  timeout: Duration = .seconds(1),
  condition: @escaping @Sendable () async -> Bool
) async {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(5))
  }
}

private func modelTestStatus(
  generatedAt: String,
  services: [PortdeckService] = []
) -> PortdeckStatus {
  PortdeckStatus(
    schemaVersion: "1.0",
    generatedAt: generatedAt,
    groups: services.isEmpty ? [] : [
      ProjectGroup(
        projectName: "PortDeck",
        repoRoot: "/repo",
        worktrees: [WorktreeGroup(name: "main", path: "/repo", branch: "main", services: services)]
      )
    ],
    unknown: [],
    warnings: []
  )
}

private func modelTestService(id: String) -> PortdeckService {
  PortdeckService(
    id: id,
    name: id,
    source: "process",
    status: "running",
    port: 3000,
    url: "http://localhost:3000",
    address: "127.0.0.1",
    protocolName: "http",
    pid: 123,
    processName: id,
    command: "npm run dev",
    cwd: "/repo",
    hostIp: nil,
    containerName: nil,
    containerId: nil,
    containerPort: nil,
    image: nil,
    confidence: "high"
  )
}
