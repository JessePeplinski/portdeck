import Foundation
import PortDeckCore

@MainActor
final class RailwayStatusModel: ObservableObject {
  nonisolated static let refreshIntervalSeconds = 60
  private static let refreshInterval = Duration.seconds(refreshIntervalSeconds)

  @Published private(set) var connectionState: RailwayConnectionState = .checking
  @Published private(set) var projects: [RailwayProject] = []
  @Published private(set) var errorMessage: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastSuccessfulRefreshAt: Date?

  private let client: any RailwayCLIClientProtocol
  private let pollInterval: Duration
  private let now: @Sendable () -> Date

  init(
    client: any RailwayCLIClientProtocol = RailwayCLIClient(),
    pollInterval: Duration = RailwayStatusModel.refreshInterval,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.client = client
    self.pollInterval = pollInterval
    self.now = now
  }

  var showsHeaderProgress: Bool { isRefreshing }
  var serviceCount: Int { projects.reduce(0) { $0 + $1.services.count } }
  var hasRetainedData: Bool { !projects.isEmpty }

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
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      let result = try await client.fetchSnapshot()
      guard !Task.isCancelled else { return }
      apply(result)
      connectionState = .connected
      errorMessage = combinedMessage(result.failures)
      if result.failures.isEmpty { lastSuccessfulRefreshAt = now() }
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
      applyConnectionError(error)
    }
  }

  func filteredProjects(matching searchText: String) -> [RailwayProject] {
    RailwayStatusBuilder.sortedProjects(projects.compactMap { $0.filtered(matching: searchText) })
  }

  private func apply(_ result: RailwaySnapshotResult) {
    let previous = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    var merged: [RailwayProject] = []

    for project in result.projects {
      if result.successfulProjectIDs.contains(project.id) {
        if let prior = previous[project.id] {
          let priorServices = Dictionary(uniqueKeysWithValues: prior.services.map { ($0.id, $0) })
          let services = project.services.map { service in
            guard let priorService = priorServices[service.id] else { return service }
            return service.retainingMissingDeploymentMetadata(from: priorService)
          }
          merged.append(project.retainingServices(services))
        } else {
          merged.append(project)
        }
      } else if let prior = previous[project.id] {
        merged.append(project.retainingServices(prior.services))
      } else {
        merged.append(project)
      }
    }
    projects = RailwayStatusBuilder.sortedProjects(merged)
  }

  private func combinedMessage(_ failures: [RailwayScopedFailure]) -> String? {
    let messages = Array(Set(failures.map(\.message))).sorted()
    guard !messages.isEmpty else { return nil }
    return messages.joined(separator: "\n")
  }

  private func applyConnectionError(_ error: Error) {
    let message = error.localizedDescription
    switch error {
    case RailwayCLIError.missingCLI:
      connectionState = .missingCLI
    case RailwayCLIError.unsupportedCLI(let currentVersion):
      connectionState = .unsupportedCLI(currentVersion: currentVersion)
    case RailwayCLIError.authenticationRequired:
      connectionState = .authenticationRequired
    case RailwayCLIError.rateLimited:
      connectionState = .rateLimited(message: message)
    default:
      connectionState = .failed(message: message)
    }
  }
}
