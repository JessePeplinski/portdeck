import Foundation
import Testing
@testable import PortDeckCore

@Test func buildsSortedVercelProjectStatusesFromLatestProductionDeployments() throws {
  let page = try JSONDecoder().decode(VercelProjectsPage.self, from: Data(
    #"""
    {
      "projects": [
        {
          "id": "project-b",
          "name": "Beta",
          "alias": ["beta.example.com"],
          "latestDeployments": []
        },
        {
          "id": "project-a",
          "accountId": "team-portdeck",
          "name": "Alpha",
          "framework": "nextjs",
          "alias": ["alpha.example.com"],
          "link": { "type": "github", "productionBranch": "main" },
          "latestDeployments": [
            {
              "id": "preview",
              "url": "alpha-preview.vercel.app",
              "target": null,
              "readyState": "READY",
              "createdAt": 1780000000000
            },
            {
              "id": "production-old",
              "url": "alpha-old.vercel.app",
              "target": "production",
              "readyState": "READY",
              "createdAt": 1770000000000
            },
            {
              "id": "production-new",
              "url": "alpha-new.vercel.app",
              "alias": ["alpha.com"],
              "target": "production",
              "readyState": "ERROR",
              "createdAt": 1790000000000,
              "buildingAt": 1790000001000,
              "readyAt": 1790000043000,
              "meta": {
                "githubCommitRef": "release/alpha",
                "githubCommitSha": "abcdef1234567890",
                "githubCommitMessage": "Ship production context",
                "githubCommitAuthorEmail": "private@example.com"
              }
            }
          ]
        }
      ],
      "pagination": { "next": null }
    }
    """#.utf8
  ))

  let statuses = VercelProjectStatusBuilder.build(from: page.projects)

  #expect(statuses.map(\.name) == ["Alpha", "Beta"])
  #expect(statuses[0].productionDeploymentID == "production-new")
  #expect(statuses[0].productionURLString == "https://alpha.com")
  #expect(statuses[0].healthState == .failed)
  #expect(statuses[0].framework == "nextjs")
  #expect(statuses[0].productionBranch == "main")
  #expect(statuses[0].deployedBranch == "release/alpha")
  #expect(statuses[0].shortCommitSHA == "abcdef1")
  #expect(statuses[0].commitMessage == "Ship production context")
  #expect(statuses[0].completedBuildDuration == 42)
  #expect(statuses[1].healthState == .noDeployment)
  #expect(statuses[1].productionURLString == nil)
}

@Test func mapsEverySupportedVercelDeploymentStateAndFallsBackQuietly() {
  #expect(VercelProjectStatusBuilder.healthState(for: "READY") == .ready)
  #expect(VercelProjectStatusBuilder.healthState(for: "building") == .inProgress)
  #expect(VercelProjectStatusBuilder.healthState(for: "QUEUED") == .inProgress)
  #expect(VercelProjectStatusBuilder.healthState(for: "INITIALIZING") == .inProgress)
  #expect(VercelProjectStatusBuilder.healthState(for: "ERROR") == .failed)
  #expect(VercelProjectStatusBuilder.healthState(for: "CANCELED") == .failed)
  #expect(VercelProjectStatusBuilder.healthState(for: "BLOCKED") == .blocked)
  #expect(VercelProjectStatusBuilder.healthState(for: "PAUSED") == .unknown)
  #expect(VercelProjectStatusBuilder.healthState(for: nil) == .unknown)
}

@Test func mergesNewerAccountDeploymentActivityOntoProjectSnapshots() {
  let baseline = VercelProjectStatus(
    id: "project",
    name: "PortDeck",
    productionDeploymentID: "ready-deployment",
    productionURLString: "https://portdeck.app",
    healthState: .ready,
    rawState: "READY",
    deploymentCreatedAt: Date(timeIntervalSince1970: 1_780_000_000)
  )
  let activeDeployment = VercelAPIRecentDeployment(
    uid: "building-deployment",
    projectId: "project",
    target: "production",
    state: "BUILDING",
    readyState: "READY",
    createdAt: 1_790_000_000_000,
    url: "portdeck-building.vercel.app"
  )

  let projects = VercelProjectStatusBuilder.merge(
    recentProductionDeployments: [activeDeployment],
    onto: [baseline]
  )

  #expect(projects[0].productionDeploymentID == "building-deployment")
  #expect(projects[0].productionURLString == "https://portdeck.app")
  #expect(projects[0].healthState == .inProgress)
  #expect(projects[0].rawState == "BUILDING")
  #expect(projects[0].deploymentCreatedAt == Date(timeIntervalSince1970: 1_790_000_000))
}

@Test func deploymentActivityPrefersStateAndMapsFailuresAndUnknownValues() {
  let baseline = VercelProjectStatus(
    id: "project",
    name: "PortDeck",
    productionDeploymentID: nil,
    productionURLString: nil,
    healthState: .noDeployment,
    rawState: nil,
    deploymentCreatedAt: nil
  )

  func mergedHealth(state: String?, readyState: String?) -> VercelDeploymentHealthState {
    VercelProjectStatusBuilder.merge(
      recentProductionDeployments: [VercelAPIRecentDeployment(
        uid: "deployment",
        projectId: "project",
        target: "production",
        state: state,
        readyState: readyState,
        createdAt: 1_790_000_000_000,
        url: "portdeck.vercel.app"
      )],
      onto: [baseline]
    )[0].healthState
  }

  #expect(mergedHealth(state: "BUILDING", readyState: "READY") == .inProgress)
  #expect(mergedHealth(state: nil, readyState: "QUEUED") == .inProgress)
  #expect(mergedHealth(state: nil, readyState: "INITIALIZING") == .inProgress)
  #expect(mergedHealth(state: "READY", readyState: nil) == .ready)
  #expect(mergedHealth(state: "ERROR", readyState: nil) == .failed)
  #expect(mergedHealth(state: "CANCELED", readyState: nil) == .failed)
  #expect(mergedHealth(state: "BLOCKED", readyState: nil) == .blocked)
  #expect(mergedHealth(state: "PAUSED", readyState: "READY") == .unknown)
}

@Test func normalizesOnlyUsableHTTPSVercelURLs() {
  #expect(VercelProjectStatusBuilder.normalizedHTTPSURLString("demo.vercel.app") == "https://demo.vercel.app")
  #expect(VercelProjectStatusBuilder.normalizedHTTPSURLString("https://demo.example.com/path") == "https://demo.example.com/path")
  #expect(VercelProjectStatusBuilder.normalizedHTTPSURLString("http://demo.example.com") == nil)
  #expect(VercelProjectStatusBuilder.normalizedHTTPSURLString("not a host") == nil)
  #expect(VercelProjectStatusBuilder.normalizedHTTPSURLString(nil) == nil)
}

@Test func validatesInspectorAndProjectDashboardURLs() {
  let scope = VercelScope(id: "team", name: "PortDeck", slug: "portdeck-team")

  #expect(VercelProjectStatusBuilder.safeInspectorURL("https://vercel.com/portdeck/project/deployment")?.host() == "vercel.com")
  #expect(VercelProjectStatusBuilder.safeInspectorURL("https://example.com/vercel") == nil)
  #expect(VercelProjectStatusBuilder.safeInspectorURL("http://vercel.com/deployment") == nil)
  #expect(VercelProjectStatusBuilder.safeInspectorURL("https://user:password@vercel.com/deployment") == nil)
  #expect(
    VercelProjectStatusBuilder.safeProjectDashboardURL(scope: scope, projectSlug: "portdeck-app")?.absoluteString
      == "https://vercel.com/portdeck-team/portdeck-app"
  )
  #expect(VercelProjectStatusBuilder.safeProjectDashboardURL(scope: scope, projectSlug: "../settings") == nil)
  #expect(VercelProjectStatusBuilder.safeProjectDashboardURL(
    scope: VercelScope(id: "team", name: nil, slug: "unsafe/path"),
    projectSlug: "portdeck"
  ) == nil)
}

@Test func decodesProviderPrefixedGitMetadataAndIgnoresUnrelatedFields() throws {
  let deployment = try JSONDecoder().decode(VercelAPIRecentDeployment.self, from: Data(
    #"{"uid":"deployment","projectId":"project","meta":{"gitlabCommitRef":"main","gitlabCommitSha":"1234567890","gitlabCommitMessage":"Deploy safely","gitlabCommitAuthorEmail":"private@example.com","other":"ignored"}}"#.utf8
  ))

  #expect(deployment.meta == VercelDeploymentGitMetadata(
    branch: "main",
    commitSHA: "1234567890",
    commitMessage: "Deploy safely"
  ))
}

@Test func newerDeploymentOverlayPreservesStableMetadataAndRejectsStaleActivity() {
  let baseline = VercelProjectStatus(
    id: "project",
    name: "portdeck",
    productionDeploymentID: "baseline",
    productionURLString: "https://portdeck.app",
    healthState: .ready,
    rawState: "READY",
    deploymentCreatedAt: Date(timeIntervalSince1970: 1_790_000_000),
    framework: "nextjs",
    productionBranch: "main",
    deployedBranch: "main",
    commitSHA: "baseline123",
    commitMessage: "Stable production"
  )
  let stale = VercelAPIRecentDeployment(
    uid: "stale",
    projectId: "project",
    target: "production",
    state: "ERROR",
    readyState: nil,
    createdAt: 1_780_000_000_000,
    url: "stale.vercel.app",
    errorCode: "STALE"
  )
  let fresh = VercelAPIRecentDeployment(
    uid: "fresh",
    projectId: "project",
    target: "production",
    state: "ERROR",
    readyState: nil,
    createdAt: 1_800_000_000_000,
    url: "fresh.vercel.app",
    buildingAt: 1_800_000_001_000,
    ready: 1_800_000_011_000,
    source: "cli",
    inspectorUrl: "https://vercel.com/portdeck/project/fresh",
    errorCode: "BUILD_FAILED",
    errorMessage: "Command failed with VERCEL_TOKEN=secret-value",
    meta: nil
  )

  let staleResult = VercelProjectStatusBuilder.merge(
    recentProductionDeployments: [stale],
    onto: [baseline]
  )[0]
  #expect(staleResult == baseline)

  let freshResult = VercelProjectStatusBuilder.merge(
    recentProductionDeployments: [fresh],
    onto: [baseline]
  )[0]
  #expect(freshResult.productionURLString == "https://portdeck.app")
  #expect(freshResult.framework == "nextjs")
  #expect(freshResult.productionBranch == "main")
  #expect(freshResult.deployedBranch == nil)
  #expect(freshResult.deploymentSource == "cli")
  #expect(freshResult.completedBuildDuration == 10)
  #expect(freshResult.inspectorURL?.host() == "vercel.com")
  #expect(freshResult.failureCode == "BUILD_FAILED")
  #expect(freshResult.failureMessage == "Command failed with VERCEL_TOKEN=<redacted>")
}

@Test func boundsAndRedactsVercelFailureDetails() {
  let longMessage = "Authorization: Bearer super-secret " + String(repeating: "x", count: 400)
  let sanitized = VercelProjectStatusBuilder.sanitizedFailureValue(longMessage)

  #expect(sanitized?.contains("super-secret") == false)
  #expect(sanitized?.contains("<redacted>") == true)
  #expect(sanitized?.count == 280)
}

@Test func searchesVercelProjectsAcrossProductionMetadata() {
  let project = VercelProjectStatus(
    id: "project",
    name: "Acme Web",
    productionDeploymentID: "deployment",
    productionURLString: "https://acme-web",
    healthState: .ready,
    rawState: "READY",
    deploymentCreatedAt: nil,
    framework: "nextjs",
    productionBranch: "main",
    deployedBranch: "feature/vercel-context",
    commitSHA: "abcdef123456",
    commitMessage: "Add production context",
    deploymentSource: "git",
    failureCode: "BUILD_FAILED",
    failureMessage: "Type check failed"
  )

  #expect(project.matchesSearch("acme"))
  #expect(project.matchesSearch("acme-web"))
  #expect(project.matchesSearch("ready"))
  #expect(project.matchesSearch("feature/vercel"))
  #expect(project.matchesSearch("abcdef1"))
  #expect(project.matchesSearch("production context"))
  #expect(project.matchesSearch("nextjs"))
  #expect(project.matchesSearch("git"))
  #expect(project.matchesSearch("type check"))
  #expect(project.matchesSearch(""))
  #expect(!project.matchesSearch("convex"))
}
