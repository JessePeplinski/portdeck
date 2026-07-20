import Foundation
import PortDeckCore
import Testing
@testable import PortDeckMac

@Test func usesThirtySecondGitHubPollingAndPresentsLastSuccessfulAge() {
  #expect(GitHubStatusModel.refreshIntervalSeconds == 30)
  #expect(githubLastCheckedLabel(ageSeconds: 4) == "Checked 4s ago · every 30s")

  let lastUpdated = Date(timeIntervalSince1970: 100)
  #expect(githubPollingAgeSeconds(lastUpdated: lastUpdated, relativeTo: lastUpdated) == 0)
  #expect(githubPollingAgeSeconds(lastUpdated: lastUpdated, relativeTo: Date(timeIntervalSince1970: 104.9)) == 4)
  #expect(githubPollingAgeSeconds(lastUpdated: lastUpdated, relativeTo: Date(timeIntervalSince1970: 99)) == 0)
}

@MainActor
@Test func preservesLastGoodGitHubHealthAfterTransientFailureAndRefreshesChangedCandidates() async {
  let first = githubCandidate(owner: "OpenAI", repository: "codex", project: "Codex")
  let second = githubCandidate(owner: "acme-inc", repository: "portdeck", project: "PortDeck")
  let resolver = MutableGitHubResolver(candidates: [first])
  let client = FakeGitHubClient(workflowResults: [
    .success([githubRun(id: 1, workflowID: 1, conclusion: "success")]),
    .failure(FakeGitHubError.transient),
    .success([githubRun(id: 2, workflowID: 2, conclusion: "failure")])
  ])
  let model = GitHubStatusModel(client: client, resolver: resolver)

  await model.refresh(status: nil)
  #expect(model.repositories[0].healthState == .passing)
  #expect(await client.metadataForceFlags == [true])
  let firstRefresh = model.repositories[0].lastSuccessfulRefreshAt

  await model.refresh(status: nil)
  #expect(model.repositories[0].healthState == .passing)
  #expect(model.repositories[0].lastSuccessfulRefreshAt == firstRefresh)
  #expect(model.repositories[0].message == "Temporary GitHub failure")
  #expect(model.errorMessage == "Temporary GitHub failure")

  resolver.setCandidates([second])
  await model.updateCandidates(from: nil)
  #expect(model.repositories.map(\.candidate.fullName) == ["acme-inc/portdeck"])
  #expect(model.repositories[0].healthState == .failed)
  #expect(model.errorMessage == nil)
}

@MainActor
@Test func appliesPartialGitHubSuccessWithoutAdvancingTheCompleteCycleTimestamp() async {
  let first = githubCandidate(owner: "A", repository: "one", project: "One")
  let second = githubCandidate(owner: "B", repository: "two", project: "Two")
  let client = FakeGitHubClient(workflowResults: [
    .success([githubRun(id: 1, workflowID: 1, conclusion: "success")]),
    .failure(FakeGitHubError.transient)
  ])
  let model = GitHubStatusModel(
    client: client,
    resolver: FakeGitHubResolver(candidates: [first, second])
  )

  await model.refresh(status: nil)
  #expect(model.repositories.count == 2)
  #expect(model.repositories[0].healthState == .passing)
  #expect(model.repositories[1].healthState == .unknown)
  #expect(model.lastSuccessfulRefreshAt == nil)
  #expect(model.errorMessage == "Temporary GitHub failure")
}

@MainActor
@Test func respectsGitHubRateLimitBackoffAndPreservesTheLastSnapshot() async {
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let candidate = githubCandidate(owner: "OpenAI", repository: "codex", project: "Codex")
  let rateMessage = "GitHub API rate limit reached. PortDeck will retry later."
  let client = FakeGitHubClient(workflowResults: [
    .success([githubRun(id: 1, workflowID: 1, conclusion: "success")]),
    .failure(GitHubCLIError.rateLimited(until: now.addingTimeInterval(120), message: rateMessage))
  ])
  let model = GitHubStatusModel(
    client: client,
    resolver: FakeGitHubResolver(candidates: [candidate]),
    now: { now }
  )

  await model.refresh(status: nil)
  await model.refresh(status: nil)
  let callCountAtLimit = await client.workflowCallCount
  await model.refresh(status: nil)

  #expect(await client.workflowCallCount == callCountAtLimit)
  #expect(model.repositories[0].healthState == .passing)
  #expect(model.rateLimitUntil == now.addingTimeInterval(120))
  #expect(model.errorMessage == rateMessage)
}

@MainActor
@Test func reportsMissingAndUnauthenticatedGitHubStatesWithoutDiscardingCandidates() async {
  let candidate = githubCandidate(owner: "OpenAI", repository: "codex", project: "Codex")
  let missingModel = GitHubStatusModel(
    client: FakeGitHubClient(connectionState: .missingCLI),
    resolver: FakeGitHubResolver(candidates: [candidate])
  )
  await missingModel.refresh(status: nil)
  #expect(missingModel.connectionState == .missingCLI)
  #expect(missingModel.candidates == [candidate])
  #expect(missingModel.repositories.isEmpty)

  let unauthenticatedModel = GitHubStatusModel(
    client: FakeGitHubClient(connectionState: .unauthenticated),
    resolver: FakeGitHubResolver(candidates: [candidate])
  )
  await unauthenticatedModel.refresh(status: nil)
  #expect(unauthenticatedModel.connectionState == .unauthenticated)
  #expect(unauthenticatedModel.errorMessage?.contains(GitHubCLIClient.loginCommand) == true)
}

@MainActor
@Test func cancelsGitHubPollingWhenTheOwningTaskEnds() async {
  let candidate = githubCandidate(owner: "OpenAI", repository: "codex", project: "Codex")
  let client = FakeGitHubClient(
    workflowResults: [],
    fallbackWorkflowResult: .success([githubRun(id: 1, workflowID: 1, conclusion: "success")])
  )
  let model = GitHubStatusModel(
    client: client,
    resolver: FakeGitHubResolver(candidates: [candidate]),
    pollInterval: .milliseconds(10)
  )

  let task = Task { await model.runAutoRefresh(status: nil) }
  for _ in 0..<100 where await client.workflowCallCount < 2 {
    try? await Task.sleep(for: .milliseconds(2))
  }
  task.cancel()
  _ = await task.result
  let countAfterCancellation = await client.workflowCallCount
  try? await Task.sleep(for: .milliseconds(40))

  #expect(countAfterCancellation >= 2)
  #expect(await client.workflowCallCount == countAfterCancellation)
}

private actor FakeGitHubClient: GitHubCLIClientProtocol {
  let connectionState: GitHubConnectionState
  private var workflowResults: [Result<[GitHubWorkflowRun], Error>]
  private let fallbackWorkflowResult: Result<[GitHubWorkflowRun], Error>?
  private(set) var metadataForceFlags: [Bool] = []
  private(set) var workflowCallCount = 0

  init(
    connectionState: GitHubConnectionState = .connected,
    workflowResults: [Result<[GitHubWorkflowRun], Error>] = [],
    fallbackWorkflowResult: Result<[GitHubWorkflowRun], Error>? = nil
  ) {
    self.connectionState = connectionState
    self.workflowResults = workflowResults
    self.fallbackWorkflowResult = fallbackWorkflowResult
  }

  func inspectConnection() async -> GitHubConnectionState { connectionState }

  func fetchRepositoryMetadata(
    for candidate: GitHubRepositoryCandidate,
    forceRefresh: Bool
  ) async throws -> GitHubRepositoryMetadata {
    metadataForceFlags.append(forceRefresh)
    return GitHubRepositoryMetadata(defaultBranch: "main", fetchedAt: Date())
  }

  func fetchWorkflowRuns(
    for candidate: GitHubRepositoryCandidate,
    defaultBranch: String
  ) async throws -> [GitHubWorkflowRun] {
    workflowCallCount += 1
    if !workflowResults.isEmpty {
      return try workflowResults.removeFirst().get()
    }
    guard let fallbackWorkflowResult else { throw FakeGitHubError.missingResult }
    return try fallbackWorkflowResult.get()
  }
}

private struct FakeGitHubResolver: GitHubRepositoryCandidateResolving {
  let candidates: [GitHubRepositoryCandidate]
  func resolve(from status: PortdeckStatus?) -> [GitHubRepositoryCandidate] { candidates }
}

private final class MutableGitHubResolver: GitHubRepositoryCandidateResolving, @unchecked Sendable {
  private var candidates: [GitHubRepositoryCandidate]

  init(candidates: [GitHubRepositoryCandidate]) {
    self.candidates = candidates
  }

  func resolve(from status: PortdeckStatus?) -> [GitHubRepositoryCandidate] { candidates }
  func setCandidates(_ candidates: [GitHubRepositoryCandidate]) { self.candidates = candidates }
}

private enum FakeGitHubError: LocalizedError {
  case transient
  case missingResult

  var errorDescription: String? {
    switch self {
    case .transient: return "Temporary GitHub failure"
    case .missingResult: return "Missing fake GitHub result"
    }
  }
}

private func githubCandidate(owner: String, repository: String, project: String) -> GitHubRepositoryCandidate {
  GitHubRepositoryCandidate(owner: owner, repository: repository, projectNames: [project])
}

private func githubRun(id: Int64, workflowID: Int64, conclusion: String) -> GitHubWorkflowRun {
  GitHubWorkflowRun(
    id: id,
    workflowID: workflowID,
    name: "Verify",
    displayTitle: "Update README",
    event: "push",
    status: "completed",
    conclusion: conclusion,
    headBranch: "main",
    runNumber: Int(id),
    runAttempt: 1,
    createdAt: Date(timeIntervalSince1970: TimeInterval(id)),
    updatedAt: Date(timeIntervalSince1970: TimeInterval(id)),
    htmlURLString: "https://github.com/OpenAI/codex/actions/runs/\(id)"
  )
}
