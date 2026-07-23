import Foundation
import PortDeckCore

@MainActor
final class NetlifyStatusModel: ObservableObject {
  nonisolated static let refreshIntervalSeconds = 60
  private static let refreshInterval = Duration.seconds(refreshIntervalSeconds)

  @Published private(set) var connectionState: NetlifyConnectionState = .checking
  @Published private(set) var sites: [NetlifySite] = []
  @Published private(set) var errorMessage: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastSuccessfulRefreshAt: Date?
  @Published private(set) var isRetainingSnapshot = false

  private let client: any NetlifyCLIClientProtocol
  private let pollInterval: Duration
  private let now: @Sendable () -> Date
  private var refreshTask: Task<Void, Never>?
  private var refreshGeneration = 0

  init(
    client: any NetlifyCLIClientProtocol = NetlifyCLIClient(),
    pollInterval: Duration = NetlifyStatusModel.refreshInterval,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.client = client
    self.pollInterval = pollInterval
    self.now = now
  }

  var showsHeaderProgress: Bool { isRefreshing }
  var hasRetainedData: Bool { !sites.isEmpty && isRetainingSnapshot }

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
    if refreshGeneration == generation { refreshTask = nil }
  }

  func cancelRefresh() {
    refreshGeneration += 1
    let task = refreshTask
    refreshTask = nil
    task?.cancel()
    isRefreshing = false
  }

  func filteredSites(matching searchText: String) -> [NetlifySite] {
    NetlifyStatusBuilder.sortedSites(sites.filter { $0.matchesSearch(searchText) })
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
    } catch let error as NetlifyCLIError where error == .cancelled {
      return
    } catch {
      guard !Task.isCancelled, generation == refreshGeneration else { return }
      errorMessage = error.localizedDescription
      isRetainingSnapshot = !sites.isEmpty
      applyConnectionError(error)
    }
  }

  private func apply(_ result: NetlifySnapshotResult) {
    let previous = Dictionary(uniqueKeysWithValues: sites.map { ($0.id, $0) })
    let merged = result.sites.map { fresh -> NetlifySite in
      guard !result.successfulDeploymentSiteIDs.contains(fresh.id), let prior = previous[fresh.id] else {
        return fresh
      }
      return fresh.retainingDeployment(from: prior)
    }
    sites = NetlifyStatusBuilder.sortedSites(merged)
  }

  private func combinedMessage(_ failures: [NetlifyScopedFailure]) -> String? {
    let messages = Array(Set(failures.map { "\($0.siteName): \($0.message)" })).sorted()
    guard !messages.isEmpty else { return nil }
    return messages.joined(separator: "\n")
  }

  private func applyConnectionError(_ error: Error) {
    let message = error.localizedDescription
    switch error {
    case NetlifyCLIError.missingCLI:
      connectionState = .missingCLI
    case NetlifyCLIError.unsupportedCLI(let currentVersion):
      connectionState = .unsupportedCLI(currentVersion: currentVersion)
    case NetlifyCLIError.authenticationRequired:
      connectionState = .authenticationRequired
    case NetlifyCLIError.rateLimited:
      connectionState = .rateLimited(message: message)
    default:
      connectionState = .failed(message: message)
    }
  }
}
