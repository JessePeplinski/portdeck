import Foundation
import Testing
@testable import PortDeckCore

@Test func normalizesOnlyVerifiedCloudflareDeploymentStates() {
  #expect(pagesDeployment(status: "3 minutes ago").state == .successful)
  #expect(pagesDeployment(status: "Active").state == .deploying)
  #expect(pagesDeployment(status: "Failure").state == .failed)
  #expect(pagesDeployment(status: "Canceled").state == .canceled)
  #expect(pagesDeployment(status: "Paused someday").state == .unknown)

  #expect(workerDeployment(percentages: [100]).state == .active)
  #expect(workerDeployment(percentages: [10, 90]).state == .gradualRollout)
  #expect(workerDeployment(percentages: [50]).state == .gradualRollout)
}

@Test func sortsSearchesAndBuildsOnlySafeCloudflareLinks() {
  let account = CloudflareAccount(id: "abc123", name: "Demo Account")
  let healthy = CloudflarePagesProject(
    account: account,
    name: "Healthy Site",
    domains: ["healthy.pages.dev"],
    usesGitProvider: true,
    lastModified: "1 hour ago",
    deployment: pagesDeployment(status: "1 hour ago", branch: "main", sha: "abc1234")
  )
  let failed = CloudflarePagesProject(
    account: account,
    name: "Broken Site",
    domains: [],
    usesGitProvider: false,
    lastModified: "now",
    deployment: pagesDeployment(status: "Failure", branch: "release", sha: "deadbee")
  )

  #expect(CloudflareStatusBuilder.sortedPages([healthy, failed]).map(\.name) == ["Broken Site", "Healthy Site"])
  #expect(failed.matchesSearch("release"))
  #expect(healthy.matchesSearch("pages.dev"))
  #expect(pagesDeployment(status: "Active").dashboardURL?.host == "dash.cloudflare.com")
  #expect(CloudflarePagesDeployment(
    id: "id", environment: "Production", branch: "main", shortCommitSHA: "abc",
    deploymentURLString: "javascript:alert(1)", rawStatus: "Active", dashboardURLString: "https://example.com/not-dashboard"
  ).dashboardURL == nil)

  let worker = CloudflareWorkerResource(
    account: account,
    candidate: CloudflareWorkerCandidate(
      name: "api-worker", accountID: account.id, associatedProjectNames: ["PortDeck"], configurationPath: "/repo/wrangler.json"
    ),
    deployment: workerDeployment(percentages: [25, 75])
  )
  #expect(worker.matchesSearch("gradual"))
  #expect(worker.matchesSearch("portdeck"))
  #expect(worker.dashboardURL?.host == "dash.cloudflare.com")
}

private func pagesDeployment(
  status: String,
  branch: String = "main",
  sha: String = "abcdef0"
) -> CloudflarePagesDeployment {
  CloudflarePagesDeployment(
    id: "deployment-id",
    environment: "Production",
    branch: branch,
    shortCommitSHA: sha,
    deploymentURLString: "https://demo.pages.dev",
    rawStatus: status,
    dashboardURLString: "https://dash.cloudflare.com/account/pages/view/demo/deployment-id"
  )
}

private func workerDeployment(percentages: [Double]) -> CloudflareWorkerDeployment {
  CloudflareWorkerDeployment(
    id: "worker-deployment",
    createdAt: Date(timeIntervalSince1970: 1_750_000_000),
    source: "api",
    strategy: "percentage",
    versions: percentages.enumerated().map { .init(versionID: "version-\($0.offset)", percentage: $0.element) },
    annotations: .init(message: "Deploy update", triggeredBy: "deployment")
  )
}
