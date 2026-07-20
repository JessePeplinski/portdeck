import Foundation
import PortDeckCore

@MainActor
final class GitHubStatusModel: ObservableObject {
  nonisolated static let refreshIntervalSeconds = 30
  private static let refreshInterval = Duration.seconds(refreshIntervalSeconds)

  @Published private(set) var connectionState: GitHubConnectionState = .checking
  @Published private(set) var candidates: [GitHubRepositoryCandidate] = []
  @Published private(set) var repositories: [GitHubRepositoryStatus] = []
  @Published private(set) var errorMessage: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastSuccessfulRefreshAt: Date?
  @Published private(set) var rateLimitUntil: Date?

  private let client: any GitHubCLIClientProtocol
  private let resolver: any GitHubRepositoryCandidateResolving
  private let pollInterval: Duration
  private let now: @Sendable () -> Date
  private var rateLimitMessage: String?

  init(
    client: any GitHubCLIClientProtocol = GitHubCLIClient(),
    resolver: any GitHubRepositoryCandidateResolving = GitHubRepositoryCandidateResolver(),
    pollInterval: Duration = GitHubStatusModel.refreshInterval,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.client = client
    self.resolver = resolver
    self.pollInterval = pollInterval
    self.now = now
  }

  var showsHeaderProgress: Bool { isRefreshing }

  func runAutoRefresh(status: PortdeckStatus?) async {
    candidates = resolver.resolve(from: status)
    await refreshCurrentCandidates(forceMetadata: false, recheckConnection: true)

    while !Task.isCancelled {
      do {
        try await Task.sleep(for: pollInterval)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await refreshCurrentCandidates(forceMetadata: false, recheckConnection: false)
    }
  }

  func updateCandidates(from status: PortdeckStatus?) async {
    let resolved = resolver.resolve(from: status)
    guard resolved != candidates else { return }

    let activeIDs = Set(resolved.map(\.id))
    candidates = resolved
    repositories = repositories.filter { activeIDs.contains($0.id) }
    lastSuccessfulRefreshAt = nil
    await refreshCurrentCandidates(forceMetadata: false, recheckConnection: false)
  }

  func refresh(status: PortdeckStatus?) async {
    candidates = resolver.resolve(from: status)
    let activeIDs = Set(candidates.map(\.id))
    repositories = repositories.filter { activeIDs.contains($0.id) }
    await refreshCurrentCandidates(forceMetadata: true, recheckConnection: true)
  }

  func filteredRepositories(matching searchText: String) -> [GitHubRepositoryStatus] {
    repositories.filter { $0.matchesSearch(searchText) }
  }

  private func refreshCurrentCandidates(forceMetadata: Bool, recheckConnection: Bool) async {
    guard !isRefreshing else { return }

    guard !candidates.isEmpty else {
      repositories = []
      errorMessage = nil
      lastSuccessfulRefreshAt = nil
      rateLimitUntil = nil
      rateLimitMessage = nil
      return
    }

    if let rateLimitUntil, rateLimitUntil > now() {
      errorMessage = rateLimitMessage
      return
    }
    rateLimitUntil = nil
    rateLimitMessage = nil

    isRefreshing = true
    defer { isRefreshing = false }

    if recheckConnection || connectionState != .connected {
      let inspectedState = await client.inspectConnection()
      connectionState = inspectedState
      switch inspectedState {
      case .connected:
        break
      case .missingCLI:
        errorMessage = "GitHub CLI required."
        return
      case .unauthenticated:
        errorMessage = "GitHub authentication required. Run `\(GitHubCLIClient.loginCommand)`."
        return
      case .rateLimited(let until, let message):
        rateLimitUntil = until
        rateLimitMessage = message
        errorMessage = message
        return
      case .failed(let message):
        errorMessage = message
        return
      case .checking:
        return
      }
    }

    let activeCandidates = candidates
    let previousByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
    var refreshedByID: [String: GitHubRepositoryStatus] = [:]
    var failures: [String] = []
    var completedIDs = Set<String>()
    var shouldStop = false

    for candidate in activeCandidates {
      guard !Task.isCancelled, !shouldStop else { break }
      let previous = previousByID[candidate.id]
      do {
        let metadata = try await client.fetchRepositoryMetadata(
          for: candidate,
          forceRefresh: forceMetadata
        )
        let workflows = try await client.fetchWorkflowRuns(
          for: candidate,
          defaultBranch: metadata.defaultBranch
        )
        let refreshedAt = now()
        refreshedByID[candidate.id] = GitHubRepositoryStatus(
          candidate: candidate,
          defaultBranch: metadata.defaultBranch,
          workflows: workflows,
          hasWorkflowSnapshot: true,
          lastSuccessfulRefreshAt: refreshedAt,
          message: nil
        )
        completedIDs.insert(candidate.id)
      } catch {
        let message = error.localizedDescription
        failures.append(message)
        refreshedByID[candidate.id] = preservedStatus(
          previous,
          candidate: candidate,
          message: message
        )

        if let githubError = error as? GitHubCLIError {
          switch githubError {
          case .rateLimited(let until, let rateMessage):
            rateLimitUntil = until
            rateLimitMessage = rateMessage
            shouldStop = true
          case .unauthenticated:
            connectionState = .unauthenticated
            shouldStop = true
          case .missingCLI:
            connectionState = .missingCLI
            shouldStop = true
          case .commandFailed, .invalidResponse:
            break
          }
        }
      }
    }

    guard !Task.isCancelled else { return }

    for candidate in activeCandidates where refreshedByID[candidate.id] == nil {
      let message = rateLimitMessage ?? failures.first ?? "GitHub Actions health was not refreshed."
      refreshedByID[candidate.id] = preservedStatus(
        previousByID[candidate.id],
        candidate: candidate,
        message: message
      )
    }

    repositories = activeCandidates.compactMap { refreshedByID[$0.id] }.sorted {
      let projectComparison = $0.candidate.displayProjectName.localizedCaseInsensitiveCompare(
        $1.candidate.displayProjectName
      )
      if projectComparison != .orderedSame { return projectComparison == .orderedAscending }
      return $0.candidate.fullName.localizedCaseInsensitiveCompare($1.candidate.fullName) == .orderedAscending
    }

    if completedIDs.count == activeCandidates.count {
      lastSuccessfulRefreshAt = now()
      errorMessage = nil
    } else {
      errorMessage = rateLimitMessage ?? failures.first
    }
  }

  private func preservedStatus(
    _ previous: GitHubRepositoryStatus?,
    candidate: GitHubRepositoryCandidate,
    message: String
  ) -> GitHubRepositoryStatus {
    GitHubRepositoryStatus(
      candidate: candidate,
      defaultBranch: previous?.defaultBranch,
      workflows: previous?.workflows ?? [],
      hasWorkflowSnapshot: previous?.hasWorkflowSnapshot ?? false,
      lastSuccessfulRefreshAt: previous?.lastSuccessfulRefreshAt,
      message: message
    )
  }
}
