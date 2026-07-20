import Foundation
import PortDeckCore
import Testing
@testable import PortDeckMac

@MainActor
@Test func preservesIndependentCloudflareSnapshotsAcrossPartialFailure() async {
  let account = CloudflareAccount(id: "account", name: "Account")
  let firstProject = pagesProject(account: account, deployment: pagesDeployment())
  let degradedProject = pagesProject(account: account, deployment: nil)
  let worker = workerResource(account: account)
  let client = FakeCloudflareClient(
    accountResponses: [.success([account]), .success([account])],
    pagesResponses: [
      .success(.init(projects: [firstProject], successfulAccountIDs: [account.id], failures: [])),
      .success(.init(
        projects: [degradedProject],
        successfulAccountIDs: [account.id],
        failures: [.init(scopeID: firstProject.id, message: "Pages rate limited", isRateLimited: true)]
      ))
    ],
    workerResponses: [
      .success(.init(resources: [worker], currentCandidateIDs: [worker.id], successfulCandidateIDs: [worker.id], failures: [])),
      .failure(.commandFailed("Worker transient failure"))
    ]
  )
  let model = CloudflareStatusModel(client: client, candidateResolver: StaticCloudflareCandidateResolver(candidates: [worker.candidate]))

  await model.refresh(status: nil)
  let firstPagesDate = model.lastSuccessfulPagesRefreshAt
  #expect(model.pagesProjects.first?.deployment?.id == "page-deployment")
  #expect(model.workers.first?.deployment?.id == "worker-deployment")

  await model.refresh(status: nil)
  #expect(model.pagesProjects.first?.deployment?.id == "page-deployment")
  #expect(model.workers.first?.deployment?.id == "worker-deployment")
  #expect(model.pagesErrorMessage == "Pages rate limited")
  #expect(model.workersErrorMessage == "Worker transient failure")
  #expect(model.lastSuccessfulPagesRefreshAt == firstPagesDate)
  #expect(model.connectionState == .connected)
}

@MainActor
@Test func reportsCloudflareSetupStatesAndPreventsOverlappingRefreshes() async {
  let authentication = CloudflareStatusModel(client: FakeCloudflareClient(accountResponses: [.failure(.authenticationRequired)]))
  await authentication.refresh(status: nil)
  #expect(authentication.connectionState == .authenticationRequired)

  let delayed = FakeCloudflareClient(
    accountResponses: [.success([])],
    pagesResponses: [.success(.init(projects: [], successfulAccountIDs: [], failures: []))],
    workerResponses: [.success(.init(resources: [], currentCandidateIDs: [], successfulCandidateIDs: [], failures: []))],
    delay: .milliseconds(30)
  )
  let model = CloudflareStatusModel(client: delayed)
  async let first: Void = model.refresh(status: nil)
  try? await Task.sleep(for: .milliseconds(5))
  async let overlap: Void = model.refresh(status: nil)
  _ = await (first, overlap)
  #expect(await delayed.accountCallCount == 1)
}

@MainActor
@Test func pollsCloudflareImmediatelyAndStopsWhenOwningTaskIsCanceled() async {
  let client = FakeCloudflareClient(
    accountResponses: Array(repeating: .success([]), count: 20),
    pagesResponses: Array(repeating: .success(.init(projects: [], successfulAccountIDs: [], failures: [])), count: 20),
    workerResponses: Array(repeating: .success(.init(resources: [], currentCandidateIDs: [], successfulCandidateIDs: [], failures: [])), count: 20)
  )
  let model = CloudflareStatusModel(client: client, pollInterval: .milliseconds(10))
  let task = Task { await model.runAutoRefresh(status: nil) }
  for _ in 0..<100 where await client.accountCallCount < 2 {
    try? await Task.sleep(for: .milliseconds(2))
  }
  task.cancel()
  _ = await task.result
  let countAfterCancel = await client.accountCallCount
  try? await Task.sleep(for: .milliseconds(25))
  #expect(countAfterCancel >= 2)
  #expect(await client.accountCallCount == countAfterCancel)
}

private actor FakeCloudflareClient: CloudflareCLIClientProtocol {
  enum Response<Value: Sendable>: Sendable {
    case success(Value)
    case failure(CloudflareCLIError)
  }

  private var accountResponses: [Response<[CloudflareAccount]>]
  private var pagesResponses: [Response<CloudflarePagesFetchResult>]
  private var workerResponses: [Response<CloudflareWorkersFetchResult>]
  private let delay: Duration?
  private(set) var accountCallCount = 0

  init(
    accountResponses: [Response<[CloudflareAccount]>],
    pagesResponses: [Response<CloudflarePagesFetchResult>] = [],
    workerResponses: [Response<CloudflareWorkersFetchResult>] = [],
    delay: Duration? = nil
  ) {
    self.accountResponses = accountResponses
    self.pagesResponses = pagesResponses
    self.workerResponses = workerResponses
    self.delay = delay
  }

  func fetchAccounts() async throws -> [CloudflareAccount] {
    accountCallCount += 1
    if let delay { try await Task.sleep(for: delay) }
    return try consume(&accountResponses, fallback: [])
  }

  func fetchPages(accounts: [CloudflareAccount]) async throws -> CloudflarePagesFetchResult {
    try consume(&pagesResponses, fallback: .init(projects: [], successfulAccountIDs: [], failures: []))
  }

  func fetchWorkers(
    candidates: [CloudflareWorkerCandidate],
    accounts: [CloudflareAccount]
  ) async throws -> CloudflareWorkersFetchResult {
    try consume(&workerResponses, fallback: .init(resources: [], currentCandidateIDs: [], successfulCandidateIDs: [], failures: []))
  }

  private func consume<Value: Sendable>(_ responses: inout [Response<Value>], fallback: Value) throws -> Value {
    guard !responses.isEmpty else { return fallback }
    switch responses.removeFirst() {
    case .success(let value): return value
    case .failure(let error): throw error
    }
  }
}

private struct StaticCloudflareCandidateResolver: CloudflareProjectCandidateResolving {
  let candidates: [CloudflareWorkerCandidate]
  func resolve(from status: PortdeckStatus?) -> [CloudflareWorkerCandidate] { candidates }
}

private func pagesProject(account: CloudflareAccount, deployment: CloudflarePagesDeployment?) -> CloudflarePagesProject {
  CloudflarePagesProject(
    account: account, name: "Pages", domains: ["pages.example"], usesGitProvider: true,
    lastModified: "1 minute ago", deployment: deployment
  )
}

private func pagesDeployment() -> CloudflarePagesDeployment {
  CloudflarePagesDeployment(
    id: "page-deployment", environment: "Production", branch: "main", shortCommitSHA: "abcdef0",
    deploymentURLString: "https://pages.example", rawStatus: "1 minute ago",
    dashboardURLString: "https://dash.cloudflare.com/account/pages/view/pages/page-deployment"
  )
}

private func workerResource(account: CloudflareAccount) -> CloudflareWorkerResource {
  let candidate = CloudflareWorkerCandidate(
    name: "worker", accountID: account.id, associatedProjectNames: ["PortDeck"], configurationPath: "/repo/wrangler.json"
  )
  return CloudflareWorkerResource(
    account: account,
    candidate: candidate,
    deployment: CloudflareWorkerDeployment(
      id: "worker-deployment", createdAt: Date(), source: "api", strategy: "percentage",
      versions: [.init(versionID: "version", percentage: 100)], annotations: nil
    )
  )
}
