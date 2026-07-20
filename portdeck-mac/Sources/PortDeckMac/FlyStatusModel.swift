import Foundation
import PortDeckCore

@MainActor
final class FlyStatusModel: ObservableObject {
  nonisolated static let refreshIntervalSeconds = 60
  private static let refreshInterval = Duration.seconds(refreshIntervalSeconds)

  @Published private(set) var connectionState: FlyConnectionState = .checking
  @Published private(set) var organizations: [FlyOrganization] = []
  @Published private(set) var apps: [FlyApp] = []
  @Published private(set) var errorMessage: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastSuccessfulRefreshAt: Date?
  @Published private(set) var isRetainingSnapshot = false

  private let client: any FlyCLIClientProtocol
  private let pollInterval: Duration
  private let now: @Sendable () -> Date
  private var refreshTask: Task<Void, Never>?
  private var refreshGeneration = 0

  init(
    client: any FlyCLIClientProtocol = FlyCLIClient(),
    pollInterval: Duration = FlyStatusModel.refreshInterval,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.client = client
    self.pollInterval = pollInterval
    self.now = now
  }

  var showsHeaderProgress: Bool { isRefreshing }
  var machineCount: Int { apps.reduce(0) { $0 + $1.machines.count } }
  var hasRetainedData: Bool { !apps.isEmpty && isRetainingSnapshot }

  func runAutoRefresh() async {
    await refresh()
    while !Task.isCancelled {
      do { try await Task.sleep(for: pollInterval) }
      catch { return }
      guard !Task.isCancelled else { return }
      await refresh()
    }
  }

  func refresh() async {
    if let refreshTask {
      await withTaskCancellationHandler {
        await refreshTask.value
      } onCancel: {
        refreshTask.cancel()
      }
      return
    }

    refreshGeneration += 1
    let generation = refreshGeneration
    let task = Task { [weak self] in
      guard let self else { return }
      await self.performRefresh(generation: generation)
    }
    refreshTask = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    if refreshGeneration == generation {
      refreshTask = nil
    }
  }

  func cancelRefresh() {
    refreshGeneration += 1
    let task = refreshTask
    refreshTask = nil
    task?.cancel()
    isRefreshing = false
  }

  private func performRefresh(generation: Int) async {
    guard generation == refreshGeneration else { return }
    isRefreshing = true
    defer {
      if generation == refreshGeneration { isRefreshing = false }
    }

    do {
      let result = try await client.fetchSnapshot()
      guard !Task.isCancelled, generation == refreshGeneration else { return }
      apply(result)
      connectionState = .connected
      errorMessage = combinedMessage(result.failures)
      isRetainingSnapshot = false
      if result.failures.isEmpty { lastSuccessfulRefreshAt = now() }
    } catch let error as FlyCLIError where error == .cancelled {
      return
    } catch {
      guard !Task.isCancelled, generation == refreshGeneration else { return }
      errorMessage = error.localizedDescription
      isRetainingSnapshot = !apps.isEmpty
      applyConnectionError(error)
    }
  }

  func filteredApps(matching searchText: String) -> [FlyApp] {
    FlyStatusBuilder.sortedApps(apps.filter { $0.matchesSearch(searchText) })
  }

  private func apply(_ result: FlySnapshotResult) {
    let previous = Dictionary(uniqueKeysWithValues: apps.map { ($0.identityKey, $0) })
    let merged = result.apps.map { fresh -> FlyApp in
      guard let prior = previous[fresh.identityKey] else { return fresh }
      var app = fresh
      if !result.successfulStatusAppKeys.contains(fresh.identityKey) {
        app = app.retainingStatus(from: prior)
      }
      if !result.successfulReleaseAppKeys.contains(fresh.identityKey) {
        app = app.retainingRelease(from: prior)
      }
      return app
    }
    organizations = result.organizations
    apps = FlyStatusBuilder.sortedApps(merged)
  }

  private func combinedMessage(_ failures: [FlyScopedFailure]) -> String? {
    let messages = Array(Set(failures.map { "\($0.appName): \($0.message)" })).sorted()
    guard !messages.isEmpty else { return nil }
    return messages.joined(separator: "\n")
  }

  private func applyConnectionError(_ error: Error) {
    let message = error.localizedDescription
    switch error {
    case FlyCLIError.missingRuntime:
      connectionState = .missingRuntime
    case FlyCLIError.incompatibleRuntime(let currentVersion):
      connectionState = .incompatibleRuntime(currentVersion: currentVersion)
    case FlyCLIError.authenticationRequired:
      connectionState = .authenticationRequired
    case FlyCLIError.rateLimited:
      connectionState = .rateLimited(message: message)
    default:
      connectionState = .failed(message: message)
    }
  }
}
