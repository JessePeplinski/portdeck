import Foundation

public struct GitHubRepositoryCandidate: Identifiable, Equatable, Sendable {
  public let owner: String
  public let repository: String
  public let projectNames: [String]

  public init(owner: String, repository: String, projectNames: [String]) {
    self.owner = owner
    self.repository = repository
    self.projectNames = Array(Set(projectNames.filter { !$0.isEmpty })).sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
  }

  public var id: String {
    "\(owner)/\(repository)".lowercased()
  }

  public var fullName: String {
    "\(owner)/\(repository)"
  }

  public var displayProjectName: String {
    projectNames.joined(separator: ", ")
  }
}

public struct GitHubRepositoryMetadata: Equatable, Sendable {
  public let defaultBranch: String
  public let fetchedAt: Date

  public init(defaultBranch: String, fetchedAt: Date) {
    self.defaultBranch = defaultBranch
    self.fetchedAt = fetchedAt
  }
}

public struct GitHubWorkflowRunsPage: Decodable, Equatable, Sendable {
  public let workflowRuns: [GitHubWorkflowRun]

  enum CodingKeys: String, CodingKey {
    case workflowRuns = "workflow_runs"
  }

  public init(workflowRuns: [GitHubWorkflowRun]) {
    self.workflowRuns = workflowRuns
  }
}

public struct GitHubWorkflowRun: Decodable, Identifiable, Equatable, Sendable {
  public let id: Int64
  public let workflowID: Int64
  public let name: String?
  public let displayTitle: String?
  public let event: String?
  public let status: String?
  public let conclusion: String?
  public let headBranch: String?
  public let runNumber: Int?
  public let runAttempt: Int?
  public let createdAt: Date?
  public let updatedAt: Date?
  public let htmlURLString: String?

  enum CodingKeys: String, CodingKey {
    case id
    case workflowID = "workflow_id"
    case name
    case displayTitle = "display_title"
    case event
    case status
    case conclusion
    case headBranch = "head_branch"
    case runNumber = "run_number"
    case runAttempt = "run_attempt"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case htmlURLString = "html_url"
  }

  public init(
    id: Int64,
    workflowID: Int64,
    name: String?,
    displayTitle: String?,
    event: String?,
    status: String?,
    conclusion: String?,
    headBranch: String?,
    runNumber: Int?,
    runAttempt: Int?,
    createdAt: Date?,
    updatedAt: Date?,
    htmlURLString: String?
  ) {
    self.id = id
    self.workflowID = workflowID
    self.name = name
    self.displayTitle = displayTitle
    self.event = event
    self.status = status
    self.conclusion = conclusion
    self.headBranch = headBranch
    self.runNumber = runNumber
    self.runAttempt = runAttempt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.htmlURLString = htmlURLString
  }

  public var htmlURL: URL? {
    guard let htmlURLString,
      let url = URL(string: htmlURLString),
      url.scheme == "https",
      url.host?.lowercased() == "github.com"
    else {
      return nil
    }
    return url
  }

  public var displayName: String {
    let normalized = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return normalized.isEmpty ? "Unknown workflow" : normalized
  }

  public var activityDate: Date? {
    updatedAt ?? createdAt
  }

  public var healthState: GitHubWorkflowHealthState {
    GitHubWorkflowHealthState.map(status: status, conclusion: conclusion)
  }

  public func matchesSearch(_ query: String) -> Bool {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return true }
    return [name, displayTitle, event, status, conclusion, headBranch, healthState.title]
      .compactMap { $0?.lowercased() }
      .contains { $0.contains(normalized) }
  }
}

public enum GitHubWorkflowHealthState: String, Equatable, Sendable {
  case running
  case failed
  case warning
  case passing
  case unknown

  public var title: String {
    switch self {
    case .running: return "Running"
    case .failed: return "Failed"
    case .warning: return "Warning"
    case .passing: return "Passing"
    case .unknown: return "Unknown"
    }
  }

  public static func map(status: String?, conclusion: String?) -> GitHubWorkflowHealthState {
    switch status?.lowercased() {
    case "queued", "in_progress", "requested", "waiting", "pending":
      return .running
    case "completed":
      switch conclusion?.lowercased() {
      case "failure", "timed_out", "action_required", "startup_failure":
        return .failed
      case "cancelled", "neutral", "stale":
        return .warning
      case "success", "skipped":
        return .passing
      default:
        return .unknown
      }
    default:
      return .unknown
    }
  }
}

public enum GitHubRepositoryHealthState: String, Equatable, Sendable {
  case failed
  case running
  case warning
  case unknown
  case passing
  case noRuns

  public var title: String {
    switch self {
    case .failed: return "Failed"
    case .running: return "Running"
    case .warning: return "Warning"
    case .unknown: return "Unknown"
    case .passing: return "Passing"
    case .noRuns: return "No runs"
    }
  }
}

public struct GitHubRepositoryStatus: Identifiable, Equatable, Sendable {
  public let candidate: GitHubRepositoryCandidate
  public let defaultBranch: String?
  public let workflows: [GitHubWorkflowRun]
  public let hasWorkflowSnapshot: Bool
  public let lastSuccessfulRefreshAt: Date?
  public let message: String?

  public init(
    candidate: GitHubRepositoryCandidate,
    defaultBranch: String?,
    workflows: [GitHubWorkflowRun],
    hasWorkflowSnapshot: Bool,
    lastSuccessfulRefreshAt: Date?,
    message: String?
  ) {
    self.candidate = candidate
    self.defaultBranch = defaultBranch
    self.workflows = workflows
    self.hasWorkflowSnapshot = hasWorkflowSnapshot
    self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
    self.message = message
  }

  public var id: String { candidate.id }
  public var displayWorkflows: [GitHubWorkflowRun] { Array(workflows.prefix(5)) }

  public var healthState: GitHubRepositoryHealthState {
    GitHubWorkflowStatusBuilder.aggregateHealth(
      workflows: workflows,
      hasWorkflowSnapshot: hasWorkflowSnapshot
    )
  }

  public func matchesSearch(_ query: String) -> Bool {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return true }

    let repositoryFields = candidate.projectNames + [candidate.fullName, defaultBranch, healthState.title]
      .compactMap { $0 }
    return repositoryFields.contains { $0.lowercased().contains(normalized) }
      || workflows.contains { $0.matchesSearch(normalized) }
  }
}

public enum GitHubWorkflowStatusBuilder {
  public static func latestRunsByWorkflow(_ runs: [GitHubWorkflowRun]) -> [GitHubWorkflowRun] {
    let latestByWorkflow = runs.reduce(into: [Int64: GitHubWorkflowRun]()) { result, run in
      guard let existing = result[run.workflowID] else {
        result[run.workflowID] = run
        return
      }
      if isNewer(run, than: existing) {
        result[run.workflowID] = run
      }
    }
    return latestByWorkflow.values.sorted(by: sortsBefore)
  }

  public static func aggregateHealth(
    workflows: [GitHubWorkflowRun],
    hasWorkflowSnapshot: Bool
  ) -> GitHubRepositoryHealthState {
    guard hasWorkflowSnapshot else { return .unknown }
    guard !workflows.isEmpty else { return .noRuns }

    let states = Set(workflows.map(\.healthState))
    if states.contains(.failed) { return .failed }
    if states.contains(.running) { return .running }
    if states.contains(.warning) { return .warning }
    if states.contains(.unknown) { return .unknown }
    return .passing
  }

  public static func sortsBefore(_ left: GitHubWorkflowRun, _ right: GitHubWorkflowRun) -> Bool {
    let leftRank = sortRank(left.healthState)
    let rightRank = sortRank(right.healthState)
    if leftRank != rightRank { return leftRank < rightRank }

    switch (left.activityDate, right.activityDate) {
    case let (leftDate?, rightDate?) where leftDate != rightDate:
      return leftDate > rightDate
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    default:
      return left.id > right.id
    }
  }

  private static func isNewer(_ left: GitHubWorkflowRun, than right: GitHubWorkflowRun) -> Bool {
    switch (left.createdAt, right.createdAt) {
    case let (leftDate?, rightDate?) where leftDate != rightDate:
      return leftDate > rightDate
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    default:
      return left.id > right.id
    }
  }

  private static func sortRank(_ state: GitHubWorkflowHealthState) -> Int {
    switch state {
    case .running: return 0
    case .failed: return 1
    case .warning: return 2
    case .unknown: return 3
    case .passing: return 4
    }
  }
}

public enum GitHubConnectionState: Equatable, Sendable {
  case checking
  case missingCLI
  case unauthenticated
  case rateLimited(until: Date, message: String)
  case connected
  case failed(message: String)
}
