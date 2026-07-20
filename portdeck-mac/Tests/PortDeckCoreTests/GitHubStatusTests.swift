import Foundation
import Testing
@testable import PortDeckCore

@Test func mapsEverySupportedGitHubWorkflowStateAndUnknownValues() {
  for status in ["queued", "in_progress", "requested", "waiting", "pending"] {
    #expect(GitHubWorkflowHealthState.map(status: status, conclusion: nil) == .running)
  }
  for conclusion in ["failure", "timed_out", "action_required", "startup_failure"] {
    #expect(GitHubWorkflowHealthState.map(status: "completed", conclusion: conclusion) == .failed)
  }
  for conclusion in ["cancelled", "neutral", "stale"] {
    #expect(GitHubWorkflowHealthState.map(status: "completed", conclusion: conclusion) == .warning)
  }
  for conclusion in ["success", "skipped"] {
    #expect(GitHubWorkflowHealthState.map(status: "completed", conclusion: conclusion) == .passing)
  }
  #expect(GitHubWorkflowHealthState.map(status: nil, conclusion: nil) == .unknown)
  #expect(GitHubWorkflowHealthState.map(status: "future", conclusion: "future") == .unknown)
  #expect(GitHubWorkflowHealthState.map(status: "completed", conclusion: "future") == .unknown)
}

@Test func groupsLatestRunPerWorkflowAndSortsActiveThenUnhealthyThenUnknownThenHealthy() {
  let base = Date(timeIntervalSince1970: 1_700_000_000)
  let runs = [
    workflowRun(id: 1, workflowID: 10, status: "completed", conclusion: "failure", date: base),
    workflowRun(id: 2, workflowID: 10, status: "completed", conclusion: "success", date: base.addingTimeInterval(10)),
    workflowRun(id: 3, workflowID: 20, status: "completed", conclusion: "cancelled", date: base.addingTimeInterval(30)),
    workflowRun(id: 4, workflowID: 30, status: "queued", conclusion: nil, date: base.addingTimeInterval(5)),
    workflowRun(id: 5, workflowID: 40, status: "completed", conclusion: "future", date: base.addingTimeInterval(40)),
    workflowRun(id: 6, workflowID: 50, status: "completed", conclusion: "failure", date: base.addingTimeInterval(20))
  ]

  let grouped = GitHubWorkflowStatusBuilder.latestRunsByWorkflow(runs)
  #expect(grouped.map(\.id) == [4, 6, 3, 5, 2])
  #expect(grouped.first { $0.workflowID == 10 }?.id == 2)
}

@Test func aggregatesRepositoryHealthConservativelyAndDistinguishesNoRuns() {
  let passing = workflowRun(id: 1, workflowID: 1, status: "completed", conclusion: "success")
  let unknown = workflowRun(id: 2, workflowID: 2, status: "completed", conclusion: "future")
  let warning = workflowRun(id: 3, workflowID: 3, status: "completed", conclusion: "neutral")
  let running = workflowRun(id: 4, workflowID: 4, status: "waiting", conclusion: nil)
  let failed = workflowRun(id: 5, workflowID: 5, status: "completed", conclusion: "failure")

  #expect(GitHubWorkflowStatusBuilder.aggregateHealth(workflows: [], hasWorkflowSnapshot: false) == .unknown)
  #expect(GitHubWorkflowStatusBuilder.aggregateHealth(workflows: [], hasWorkflowSnapshot: true) == .noRuns)
  #expect(GitHubWorkflowStatusBuilder.aggregateHealth(workflows: [passing], hasWorkflowSnapshot: true) == .passing)
  #expect(GitHubWorkflowStatusBuilder.aggregateHealth(workflows: [passing, unknown], hasWorkflowSnapshot: true) == .unknown)
  #expect(GitHubWorkflowStatusBuilder.aggregateHealth(workflows: [passing, warning], hasWorkflowSnapshot: true) == .warning)
  #expect(GitHubWorkflowStatusBuilder.aggregateHealth(workflows: [warning, running], hasWorkflowSnapshot: true) == .running)
  #expect(GitHubWorkflowStatusBuilder.aggregateHealth(workflows: [running, failed], hasWorkflowSnapshot: true) == .failed)
}

@Test func limitsDisplayRowsToFiveAndSearchesAllProviderMetadata() {
  let candidate = GitHubRepositoryCandidate(
    owner: "acme-inc",
    repository: "portdeck",
    projectNames: ["PortDeck"]
  )
  let workflows = (1...8).map { index in
    workflowRun(
      id: Int64(index),
      workflowID: Int64(index),
      name: index == 8 ? "Hidden Audit" : "Verify \(index)",
      status: "completed",
      conclusion: "success"
    )
  }
  let status = GitHubRepositoryStatus(
    candidate: candidate,
    defaultBranch: "main",
    workflows: workflows,
    hasWorkflowSnapshot: true,
    lastSuccessfulRefreshAt: Date(),
    message: nil
  )

  #expect(status.displayWorkflows.count == 5)
  for query in ["portdeck", "acme-inc", "main", "Hidden Audit", "push", "completed", "Passing"] {
    #expect(status.matchesSearch(query))
  }
  #expect(!status.matchesSearch("Vercel"))
}

func workflowRun(
  id: Int64,
  workflowID: Int64,
  name: String = "Verify",
  status: String?,
  conclusion: String?,
  date: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> GitHubWorkflowRun {
  GitHubWorkflowRun(
    id: id,
    workflowID: workflowID,
    name: name,
    displayTitle: "Update README",
    event: "push",
    status: status,
    conclusion: conclusion,
    headBranch: "main",
    runNumber: Int(id),
    runAttempt: 1,
    createdAt: date,
    updatedAt: date,
    htmlURLString: "https://github.com/acme-inc/portdeck/actions/runs/\(id)"
  )
}
