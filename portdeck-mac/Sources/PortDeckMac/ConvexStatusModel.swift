import Foundation
import PortDeckCore

@MainActor
final class ConvexStatusModel: ObservableObject {
  nonisolated static let refreshIntervalSeconds = 60
  private static let refreshInterval = Duration.seconds(refreshIntervalSeconds)

  @Published private(set) var projects: [ConvexProjectStatus] = []
  @Published private(set) var candidates: [ConvexProjectCandidate] = []
  @Published private(set) var isRefreshing = false
  @Published private(set) var isConnecting = false
  @Published private(set) var lastUpdated: Date?

  private let client: any ConvexCLIClientProtocol
  private let resolver: any ConvexProjectCandidateResolving
  private let productionTargetResolver: any ConvexProductionTargetResolving

  init(
    client: any ConvexCLIClientProtocol = ConvexCLIClient(),
    resolver: any ConvexProjectCandidateResolving = ConvexProjectCandidateResolver(),
    productionTargetResolver: any ConvexProductionTargetResolving = ConvexManagementAPIProductionTargetResolver()
  ) {
    self.client = client
    self.resolver = resolver
    self.productionTargetResolver = productionTargetResolver
  }

  var showsHeaderProgress: Bool {
    isRefreshing || isConnecting
  }

  var needsAuthentication: Bool {
    projects.contains { $0.availability == .unauthenticated }
  }

  func runAutoRefresh(status: PortdeckStatus?) async {
    candidates = resolver.resolve(from: status)
    await refreshCurrentCandidates()

    while !Task.isCancelled {
      do {
        try await Task.sleep(for: Self.refreshInterval)
      } catch {
        return
      }
      await refreshCurrentCandidates()
    }
  }

  func updateCandidates(from status: PortdeckStatus?) async {
    let resolved = resolver.resolve(from: status)
    guard resolved != candidates else {
      return
    }
    candidates = resolved
    await refreshCurrentCandidates()
  }

  func refresh(status: PortdeckStatus?) async {
    candidates = resolver.resolve(from: status)
    await refreshCurrentCandidates()
  }

  func refresh() async {
    await refreshCurrentCandidates()
  }

  func connect(using candidate: ConvexProjectCandidate) async {
    guard !isConnecting else {
      return
    }
    isConnecting = true
    defer { isConnecting = false }

    do {
      try await client.login(using: candidate)
      await refreshCurrentCandidates()
    } catch {
      let previous = projects.first { $0.id == candidate.id }
      let failed = Self.statusAfterFailure(error, candidate: candidate, previous: previous)
      replaceProject(failed)
    }
  }

  func filteredProjects(matching searchText: String) -> [ConvexProjectStatus] {
    projects.filter { $0.matchesSearch(searchText) }
  }

  private func refreshCurrentCandidates() async {
    guard !isRefreshing else {
      return
    }

    let activeCandidates = candidates
    let activeIDs = Set(activeCandidates.map(\.id))
    projects = projects.filter { activeIDs.contains($0.id) }
    guard !activeCandidates.isEmpty else {
      projects = []
      lastUpdated = nil
      return
    }

    isRefreshing = true
    defer { isRefreshing = false }

    let previousByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    let client = client
    let productionTargetResolver = productionTargetResolver
    let refreshed = await withTaskGroup(of: ConvexProjectStatus.self, returning: [ConvexProjectStatus].self) { group in
      for candidate in activeCandidates {
        let previous = previousByID[candidate.id]
        group.addTask {
          await Self.loadStatus(
            client: client,
            productionTargetResolver: productionTargetResolver,
            candidate: candidate,
            previous: previous
          )
        }
      }

      var results: [ConvexProjectStatus] = []
      for await result in group {
        results.append(result)
      }
      return results
    }

    projects = ConvexProjectStatusBuilder.sorted(refreshed)
    lastUpdated = projects.compactMap(\.lastChecked).max()
  }

  private nonisolated static func loadStatus(
    client: any ConvexCLIClientProtocol,
    productionTargetResolver: any ConvexProductionTargetResolving,
    candidate: ConvexProjectCandidate,
    previous: ConvexProjectStatus?
  ) async -> ConvexProjectStatus {
    do {
      let target = try await productionTargetResolver.resolveProductionTarget(for: candidate)
      do {
        let response = try await client.fetchProductionHealth(for: candidate, target: target)
        return ConvexProjectStatusBuilder.build(
          candidate: candidate,
          target: target,
          response: response,
          checkedAt: Date()
        )
      } catch {
        return statusAfterHealthFailure(error, candidate: candidate, target: target, previous: previous)
      }
    } catch {
      return statusAfterFailure(error, candidate: candidate, previous: previous)
    }
  }

  private nonisolated static func statusAfterHealthFailure(
    _ error: Error,
    candidate: ConvexProjectCandidate,
    target: ConvexProductionTarget,
    previous: ConvexProjectStatus?
  ) -> ConvexProjectStatus {
    let message = error.localizedDescription
    if let convexError = error as? ConvexCLIError, convexError == .unauthenticated {
      return ConvexProjectStatusBuilder.healthUnavailable(
        candidate: candidate,
        target: target,
        availability: .unauthenticated,
        message: message
      )
    }
    if let previous, previous.availability == .ready {
      return previous.preservingHealth(with: target, message: message)
    }
    return ConvexProjectStatusBuilder.healthUnavailable(
      candidate: candidate,
      target: target,
      message: message
    )
  }

  private nonisolated static func statusAfterFailure(
    _ error: Error,
    candidate: ConvexProjectCandidate,
    previous: ConvexProjectStatus?
  ) -> ConvexProjectStatus {
    let message = error.localizedDescription
    if let convexError = error as? ConvexCLIError {
      switch convexError {
      case .unauthenticated:
        return ConvexProjectStatusBuilder.unavailable(
          candidate: candidate,
          availability: .unauthenticated,
          message: message
        )
      case .unconfigured:
        return ConvexProjectStatusBuilder.unavailable(
          candidate: candidate,
          availability: .unconfigured,
          message: message
        )
      case .missingCLI:
        return ConvexProjectStatusBuilder.unavailable(
          candidate: candidate,
          availability: .missingCLI,
          message: message
        )
      case .unsupportedCLI:
        return ConvexProjectStatusBuilder.unavailable(
          candidate: candidate,
          availability: .unsupportedCLI,
          message: message
        )
      case .commandFailed, .invalidResponse:
        break
      }
    }

    if let previous {
      return previous.preservingMetadata(with: message)
    }
    return ConvexProjectStatusBuilder.unavailable(
      candidate: candidate,
      availability: .unavailable,
      message: message
    )
  }

  private func replaceProject(_ project: ConvexProjectStatus) {
    var nextProjects = projects.filter { $0.id != project.id }
    nextProjects.append(project)
    projects = ConvexProjectStatusBuilder.sorted(nextProjects)
    lastUpdated = projects.compactMap(\.lastChecked).max()
  }
}
