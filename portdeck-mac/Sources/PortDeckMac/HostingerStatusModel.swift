import Foundation
import PortDeckCore

@MainActor
final class HostingerStatusModel: ObservableObject {
  nonisolated static let refreshIntervalSeconds = 60
  private static let refreshInterval = Duration.seconds(refreshIntervalSeconds)

  @Published private(set) var connectionState: HostingerConnectionState = .checking
  @Published private(set) var websites: [HostingerWebsite] = []
  @Published private(set) var errorMessage: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastSuccessfulRefreshAt: Date?
  @Published private(set) var isRetainingSnapshot = false

  private let client: any HostingerCLIClientProtocol
  private let pollInterval: Duration
  private let now: @Sendable () -> Date
  private var refreshTask: Task<Void, Never>?
  private var refreshGeneration = 0

  init(
    client: any HostingerCLIClientProtocol = HostingerCLIClient(),
    pollInterval: Duration = HostingerStatusModel.refreshInterval,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.client = client
    self.pollInterval = pollInterval
    self.now = now
  }

  var showsHeaderProgress: Bool {
    isRefreshing
  }

  func runAutoRefresh() async {
    await refresh()
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: pollInterval)
      } catch {
        return
      }
      guard !Task.isCancelled else {
        return
      }
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
      guard let self else {
        return
      }
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

  func filteredWebsites(matching searchText: String) -> [HostingerWebsite] {
    HostingerStatusBuilder.sortedWebsites(
      websites.filter { $0.matchesSearch(searchText) }
    )
  }

  private func performRefresh(generation: Int) async {
    guard generation == refreshGeneration else {
      return
    }
    isRefreshing = true
    defer {
      if generation == refreshGeneration {
        isRefreshing = false
      }
    }

    do {
      let result = try await client.fetchWebsites()
      guard !Task.isCancelled, generation == refreshGeneration else {
        return
      }
      websites = HostingerStatusBuilder.sortedWebsites(result)
      connectionState = .connected
      errorMessage = nil
      isRetainingSnapshot = false
      lastSuccessfulRefreshAt = now()
    } catch let error as HostingerCLIError where error == .cancelled {
      return
    } catch {
      guard !Task.isCancelled, generation == refreshGeneration else {
        return
      }
      errorMessage = error.localizedDescription
      isRetainingSnapshot = !websites.isEmpty
      applyConnectionError(error)
    }
  }

  private func applyConnectionError(_ error: Error) {
    let message = error.localizedDescription
    switch error {
    case HostingerCLIError.missingCLI:
      connectionState = .missingCLI
    case HostingerCLIError.unsupportedCLI(let currentVersion):
      connectionState = .unsupportedCLI(currentVersion: currentVersion)
    case HostingerCLIError.authenticationRequired:
      connectionState = .authenticationRequired
    case HostingerCLIError.rateLimited:
      connectionState = .rateLimited(message: message)
    default:
      connectionState = .failed(message: message)
    }
  }
}
