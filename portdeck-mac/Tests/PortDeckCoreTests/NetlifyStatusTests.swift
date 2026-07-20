import Foundation
import Testing
@testable import PortDeckCore

@Test func mapsEveryVerifiedNetlifyDeploymentStateConservatively() {
  #expect(NetlifyDeploymentState.map("ready") == .healthy)
  #expect(NetlifyDeploymentState.map("error") == .failed)
  #expect(NetlifyDeploymentState.map("rejected") == .inactive)
  for state in [
    "new", "pending_review", "accepted", "enqueued", "building", "uploading", "uploaded",
    "preparing", "prepared", "processing", "processed", "retrying"
  ] {
    #expect(NetlifyDeploymentState.map(state) == .deploying)
  }
  #expect(NetlifyDeploymentState.map("future_state") == .unknown)
  #expect(NetlifyDeploymentState.map(nil) == .unknown)
}

@Test func acceptsOnlySafeNetlifyPublicAndDashboardLinks() {
  #expect(NetlifySafeLink.publicURL("https://demo.netlify.app")?.host == "demo.netlify.app")
  #expect(NetlifySafeLink.publicURL("https://www.example.com/path")?.host == "www.example.com")
  #expect(NetlifySafeLink.publicURL("http://demo.netlify.app") == nil)
  #expect(NetlifySafeLink.publicURL("https://user:pass@demo.netlify.app") == nil)
  #expect(NetlifySafeLink.publicURL("https://localhost") == nil)
  #expect(NetlifySafeLink.publicURL("https://127.0.0.1") == nil)
  #expect(NetlifySafeLink.publicURL("https://demo.netlify.app:8443") == nil)
  #expect(NetlifySafeLink.publicURL("https://demo.netlify.app?token=secret") == nil)

  #expect(NetlifySafeLink.dashboardURL("https://app.netlify.com/sites/demo") != nil)
  #expect(NetlifySafeLink.dashboardURL("https://app.netlify.com/sites/demo/deploys/deploy-1") != nil)
  #expect(NetlifySafeLink.dashboardURL("https://app.netlify.com/projects/demo") == nil)
  #expect(NetlifySafeLink.dashboardURL("https://evil.example/sites/demo") == nil)
  #expect(NetlifySafeLink.dashboardURL("https://app.netlify.com/sites/demo/configuration") == nil)
}

@Test func netlifySortingAndSearchUseRenderedEvidenceWithoutMutatingSnapshots() {
  let accountA = NetlifyAccount(id: "a", name: "Alpha")
  let accountB = NetlifyAccount(id: "b", name: "Beta", slug: "beta-team")
  let failed = netlifySite(name: "failed", account: accountB, state: "error")
  let retained = NetlifySite(
    id: "retained", name: "retained", account: accountA,
    latestDeployment: deployment(siteID: "retained", state: "ready"),
    hasDeploymentFailure: true, isDeploymentRetained: true
  )
  let building = netlifySite(name: "building", account: accountA, state: "building")
  let rejected = netlifySite(name: "rejected", account: accountA, state: "rejected")
  let healthy = netlifySite(name: "healthy", account: accountA, state: "ready")
  let unknown = NetlifySite(id: "unknown", name: "unknown", account: accountA)
  let sorted = NetlifyStatusBuilder.sortedSites([unknown, healthy, retained, rejected, failed, building])

  #expect(sorted.map(\.name) == ["failed", "retained", "building", "rejected", "healthy", "unknown"])
  #expect(healthy.matchesSearch("main"))
  #expect(healthy.matchesSearch("abcdef12"))
  #expect(failed.matchesSearch("error"))
  #expect(retained.matchesSearch("alpha"))
  #expect(!unknown.matchesSearch("beta-team"))
  #expect(healthy.latestDeployment?.rawState == "ready")
}

@Test func retainedDeploymentMustStillBelongToTheCurrentSiteIdentity() {
  let account = NetlifyAccount(id: "account", name: "Account")
  let prior = NetlifySite(
    id: "old-site", name: "old", account: account,
    latestDeployment: deployment(siteID: "old-site", state: "ready")
  )
  let replacement = NetlifySite(id: "new-site", name: "new", account: account)
  let retained = replacement.retainingDeployment(from: prior)
  #expect(retained.latestDeployment == nil)
  #expect(!retained.isDeploymentRetained)
}

private func netlifySite(name: String, account: NetlifyAccount, state: String) -> NetlifySite {
  NetlifySite(
    id: name, name: name, account: account,
    productionURLString: "https://\(name).netlify.app",
    dashboardURLString: "https://app.netlify.com/sites/\(name)",
    latestDeployment: deployment(siteID: name, state: state)
  )
}

private func deployment(siteID: String, state: String) -> NetlifyDeployment {
  NetlifyDeployment(
    id: "deploy-\(siteID)", siteID: siteID, rawState: state, context: "production",
    branch: "main", commitReference: "abcdef1234567890", title: "Ship \(siteID)",
    deployURLString: "https://deploy-\(siteID).netlify.app",
    dashboardURLString: "https://app.netlify.com/sites/\(siteID)/deploys/deploy-\(siteID)"
  )
}
