import Foundation
import PortDeckCore

@MainActor
final class VercelStatusModel: ObservableObject {
  nonisolated static let deploymentRefreshIntervalSeconds = 2

  private static let projectRefreshInterval = Duration.seconds(60)
  private static let deploymentRefreshInterval = Duration.seconds(deploymentRefreshIntervalSeconds)

  @Published private(set) var connectionState: VercelConnectionState = .checking
  @Published private(set) var scope: VercelScope?
  @Published private(set) var projects: [VercelProjectStatus] = []
  @Published private(set) var errorMessage: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastUpdated: Date?

  private let client: any VercelCLIClientProtocol
  private var baselineProjects: [VercelProjectStatus] = []
  private var recentProductionDeployments: [VercelAPIRecentDeployment] = []
  private var connectionErrorMessage: String?
  private var projectErrorMessage: String?
  private var deploymentErrorMessage: String?
  private var isProjectRefreshInFlight = false
  private var isDeploymentRefreshInFlight = false
  private var loginTask: Task<Void, Never>?

  init(client: any VercelCLIClientProtocol = VercelCLIClient()) {
    self.client = client
  }

  var showsHeaderProgress: Bool {
    isRefreshing || connectionState == .connecting
  }

  func runAutoRefresh() async {
    await refresh()

    await withTaskGroup(of: Void.self) { group in
      group.addTask { [weak self] in
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: Self.projectRefreshInterval)
          } catch {
            return
          }
          guard let self, !Task.isCancelled else {
            return
          }
          _ = await self.refreshProjectBaseline()
        }
      }

      group.addTask { [weak self] in
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: Self.deploymentRefreshInterval)
          } catch {
            return
          }
          guard let self, !Task.isCancelled else {
            return
          }
          await self.refreshDeploymentActivity()
        }
      }

      await group.waitForAll()
    }
  }

  func refresh() async {
    guard !isRefreshing, loginTask == nil else {
      return
    }

    isRefreshing = true
    if projects.isEmpty {
      connectionState = .checking
    }
    defer { isRefreshing = false }

    let hasConnectedCLI = await refreshProjectBaseline()
    if hasConnectedCLI {
      await refreshDeploymentActivity(force: true)
    }
  }

  func refreshDeploymentActivity() async {
    await refreshDeploymentActivity(force: false)
  }

  @discardableResult
  private func refreshProjectBaseline() async -> Bool {
    guard !isProjectRefreshInFlight, loginTask == nil else {
      return connectionState == .connected
    }

    isProjectRefreshInFlight = true
    defer { isProjectRefreshInFlight = false }

    let inspectedState = await client.inspectConnection()
    guard inspectedState == .connected else {
      applyDisconnectedState(inspectedState)
      return false
    }

    connectionErrorMessage = nil
    connectionState = .connected

    do {
      let snapshot = try await client.fetchProjectSnapshot()
      scope = snapshot.scope
      baselineProjects = snapshot.projects
      projectErrorMessage = nil
      applyMergedProjects()
      lastUpdated = Date()
    } catch {
      projectErrorMessage = error.localizedDescription
      if baselineProjects.isEmpty {
        connectionState = .failed(message: error.localizedDescription)
      }
    }

    updateErrorMessage()
    return true
  }

  private func refreshDeploymentActivity(force: Bool) async {
    guard (force || connectionState == .connected),
      !isDeploymentRefreshInFlight,
      loginTask == nil
    else {
      return
    }

    isDeploymentRefreshInFlight = true
    defer { isDeploymentRefreshInFlight = false }

    do {
      recentProductionDeployments = try await client.fetchRecentProductionDeployments()
      deploymentErrorMessage = nil
      applyMergedProjects()
      lastUpdated = Date()
    } catch {
      deploymentErrorMessage = error.localizedDescription
    }

    updateErrorMessage()
  }

  func connect() {
    guard loginTask == nil else {
      return
    }

    connectionState = .connecting
    errorMessage = nil
    loginTask = Task { [weak self] in
      guard let self else {
        return
      }

      do {
        try await client.login()
        loginTask = nil
        await refresh()
      } catch {
        loginTask = nil
        connectionState = .failed(message: error.localizedDescription)
        errorMessage = error.localizedDescription
      }
    }
  }

  func filteredProjects(matching searchText: String) -> [VercelProjectStatus] {
    projects.filter { $0.matchesSearch(searchText) }
  }

  private func applyDisconnectedState(_ state: VercelConnectionState) {
    switch state {
    case .missingCLI, .outdatedCLI, .unauthenticated:
      baselineProjects = []
      recentProductionDeployments = []
      scope = nil
      projects = []
      lastUpdated = nil
      connectionErrorMessage = nil
      projectErrorMessage = nil
      deploymentErrorMessage = nil
      connectionState = state
    case .failed(let message):
      connectionErrorMessage = message
      if baselineProjects.isEmpty {
        connectionState = state
      } else {
        connectionState = .connected
      }
    case .checking, .connecting, .connected:
      connectionState = state
    }

    updateErrorMessage()
  }

  private func applyMergedProjects() {
    projects = VercelProjectStatusBuilder.merge(
      recentProductionDeployments: recentProductionDeployments,
      onto: baselineProjects
    )
  }

  private func updateErrorMessage() {
    errorMessage = connectionErrorMessage ?? projectErrorMessage ?? deploymentErrorMessage
  }
}
