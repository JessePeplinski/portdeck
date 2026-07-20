import Foundation
import PortDeckCore

@MainActor
final class CloudflareStatusModel: ObservableObject {
  nonisolated static let refreshIntervalSeconds = 60
  private static let refreshInterval = Duration.seconds(refreshIntervalSeconds)

  @Published private(set) var connectionState: CloudflareConnectionState = .checking
  @Published private(set) var accounts: [CloudflareAccount] = []
  @Published private(set) var pagesProjects: [CloudflarePagesProject] = []
  @Published private(set) var workers: [CloudflareWorkerResource] = []
  @Published private(set) var candidates: [CloudflareWorkerCandidate] = []
  @Published private(set) var pagesErrorMessage: String?
  @Published private(set) var workersErrorMessage: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastSuccessfulPagesRefreshAt: Date?
  @Published private(set) var lastSuccessfulWorkersRefreshAt: Date?

  private let client: any CloudflareCLIClientProtocol
  private let candidateResolver: any CloudflareProjectCandidateResolving
  private let pollInterval: Duration
  private let now: @Sendable () -> Date

  init(
    client: any CloudflareCLIClientProtocol = CloudflareCLIClient(),
    candidateResolver: any CloudflareProjectCandidateResolving = CloudflareProjectCandidateResolver(),
    pollInterval: Duration = CloudflareStatusModel.refreshInterval,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.client = client
    self.candidateResolver = candidateResolver
    self.pollInterval = pollInterval
    self.now = now
  }

  var showsHeaderProgress: Bool { isRefreshing }
  var resourceCount: Int { pagesProjects.count + workers.count }
  var hasRetainedData: Bool { !pagesProjects.isEmpty || !workers.isEmpty }

  func runAutoRefresh(status: PortdeckStatus?) async {
    await refresh(status: status)
    while !Task.isCancelled {
      do { try await Task.sleep(for: pollInterval) }
      catch { return }
      guard !Task.isCancelled else { return }
      await refresh(status: status)
    }
  }

  func updateCandidates(from status: PortdeckStatus?) {
    candidates = candidateResolver.resolve(from: status)
  }

  func refresh(status: PortdeckStatus?) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    updateCandidates(from: status)

    do {
      let accounts = try await client.fetchAccounts()
      guard !Task.isCancelled else { return }
      self.accounts = accounts

      async let pagesOutcome = capturePages(accounts: accounts)
      async let workersOutcome = captureWorkers(candidates: candidates, accounts: accounts)
      let (pages, workers) = await (pagesOutcome, workersOutcome)
      guard !Task.isCancelled else { return }

      var successfulSideCount = 0
      switch pages {
      case .success(let result):
        applyPages(result)
        successfulSideCount += 1
      case .failure(let error):
        pagesErrorMessage = error.localizedDescription
      }

      switch workers {
      case .success(let result):
        applyWorkers(result)
        successfulSideCount += 1
      case .failure(let error):
        workersErrorMessage = error.localizedDescription
      }

      if successfulSideCount > 0 {
        connectionState = .connected
      } else {
        applyConnectionError(pages.failure ?? workers.failure ?? CloudflareCLIError.commandFailed("Cloudflare resources unavailable."))
      }
    } catch {
      guard !Task.isCancelled else { return }
      pagesErrorMessage = error.localizedDescription
      workersErrorMessage = error.localizedDescription
      applyConnectionError(error)
    }
  }

  func filteredPages(matching searchText: String) -> [CloudflarePagesProject] {
    pagesProjects.filter { $0.matchesSearch(searchText) }
  }

  func filteredWorkers(matching searchText: String) -> [CloudflareWorkerResource] {
    workers.filter { $0.matchesSearch(searchText) }
  }

  private func capturePages(accounts: [CloudflareAccount]) async -> Result<CloudflarePagesFetchResult, Error> {
    do { return .success(try await client.fetchPages(accounts: accounts)) }
    catch { return .failure(error) }
  }

  private func captureWorkers(
    candidates: [CloudflareWorkerCandidate],
    accounts: [CloudflareAccount]
  ) async -> Result<CloudflareWorkersFetchResult, Error> {
    do { return .success(try await client.fetchWorkers(candidates: candidates, accounts: accounts)) }
    catch { return .failure(error) }
  }

  private func applyPages(_ result: CloudflarePagesFetchResult) {
    let previous = Dictionary(uniqueKeysWithValues: pagesProjects.map { ($0.id, $0) })
    let currentAccountIDs = Set(accounts.map(\.id))
    var merged = previous.filter {
      currentAccountIDs.contains($0.value.account.id)
        && !result.successfulAccountIDs.contains($0.value.account.id)
    }
    let failedProjectIDs = Set(result.failures.map(\.scopeID))

    for project in result.projects {
      if project.deployment == nil,
        failedProjectIDs.contains(project.id),
        let priorDeployment = previous[project.id]?.deployment
      {
        merged[project.id] = CloudflarePagesProject(
          account: project.account,
          name: project.name,
          domains: project.domains,
          usesGitProvider: project.usesGitProvider,
          lastModified: project.lastModified,
          deployment: priorDeployment
        )
      } else {
        merged[project.id] = project
      }
    }

    pagesProjects = CloudflareStatusBuilder.sortedPages(Array(merged.values))
    pagesErrorMessage = combinedMessage(result.failures)
    if result.failures.isEmpty { lastSuccessfulPagesRefreshAt = now() }
  }

  private func applyWorkers(_ result: CloudflareWorkersFetchResult) {
    let previous = Dictionary(uniqueKeysWithValues: workers.map { ($0.id, $0) })
    let returned = Dictionary(uniqueKeysWithValues: result.resources.map { ($0.id, $0) })
    var merged: [String: CloudflareWorkerResource] = [:]

    for candidateID in result.currentCandidateIDs {
      if result.successfulCandidateIDs.contains(candidateID), let resource = returned[candidateID] {
        merged[candidateID] = resource
      } else if let prior = previous[candidateID] {
        merged[candidateID] = prior
      } else if let resource = returned[candidateID] {
        merged[candidateID] = resource
      }
    }

    workers = CloudflareStatusBuilder.sortedWorkers(Array(merged.values))
    workersErrorMessage = combinedMessage(result.failures)
    if result.failures.isEmpty { lastSuccessfulWorkersRefreshAt = now() }
  }

  private func combinedMessage(_ failures: [CloudflareScopedFailure]) -> String? {
    let messages = Array(Set(failures.map(\.message))).sorted()
    guard !messages.isEmpty else { return nil }
    return messages.joined(separator: "\n")
  }

  private func applyConnectionError(_ error: Error) {
    let message = error.localizedDescription
    switch error {
    case CloudflareCLIError.missingRuntime:
      connectionState = .missingRuntime
    case CloudflareCLIError.incompatibleRuntime(let currentVersion):
      connectionState = .incompatibleRuntime(currentVersion: currentVersion)
    case CloudflareCLIError.authenticationRequired:
      connectionState = .authenticationRequired
    case CloudflareCLIError.rateLimited:
      connectionState = .rateLimited(message: message)
    default:
      connectionState = .failed(message: message)
    }
  }
}

private extension Result where Failure == Error {
  var failure: Error? {
    guard case .failure(let error) = self else { return nil }
    return error
  }
}
