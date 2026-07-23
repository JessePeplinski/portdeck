import Foundation

public struct CloudflareAccount: Decodable, Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public enum CloudflareResourceKind: String, Equatable, Sendable {
  case pages
  case worker

  public var title: String {
    switch self {
    case .pages: return "Pages"
    case .worker: return "Worker"
    }
  }
}

public enum CloudflareResourceState: Equatable, Sendable {
  case successful
  case deploying
  case failed
  case active
  case gradualRollout
  case canceled
  case unknown

  public var title: String {
    switch self {
    case .successful: return "Successful"
    case .deploying: return "Deploying"
    case .failed: return "Failed"
    case .active: return "Active"
    case .gradualRollout: return "Gradual rollout"
    case .canceled: return "Canceled"
    case .unknown: return "Unknown"
    }
  }

  var sortRank: Int {
    switch self {
    case .failed, .deploying, .gradualRollout: return 0
    case .canceled, .unknown: return 1
    case .successful, .active: return 2
    }
  }
}

public struct CloudflarePagesDeployment: Decodable, Equatable, Identifiable, Sendable {
  public let id: String
  public let environment: String
  public let branch: String
  public let shortCommitSHA: String
  public let deploymentURLString: String
  public let rawStatus: String
  public let dashboardURLString: String

  enum CodingKeys: String, CodingKey {
    case id = "Id"
    case environment = "Environment"
    case branch = "Branch"
    case shortCommitSHA = "Source"
    case deploymentURLString = "Deployment"
    case rawStatus = "Status"
    case dashboardURLString = "Build"
  }

  public init(
    id: String,
    environment: String,
    branch: String,
    shortCommitSHA: String,
    deploymentURLString: String,
    rawStatus: String,
    dashboardURLString: String
  ) {
    self.id = id
    self.environment = environment
    self.branch = branch
    self.shortCommitSHA = shortCommitSHA
    self.deploymentURLString = deploymentURLString
    self.rawStatus = rawStatus
    self.dashboardURLString = dashboardURLString
  }

  public var state: CloudflareResourceState {
    let normalized = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if Self.isSuccessfulRelativeTime(normalized) { return .successful }
    switch normalized {
    case "active": return .deploying
    case "failure", "failed": return .failed
    case "canceled", "cancelled": return .canceled
    default: return .unknown
    }
  }

  public var deploymentURL: URL? { Self.safeHTTPSURL(deploymentURLString) }
  public var dashboardURL: URL? {
    guard let url = Self.safeHTTPSURL(dashboardURLString), url.host == "dash.cloudflare.com" else { return nil }
    return url
  }

  private static func isSuccessfulRelativeTime(_ value: String) -> Bool {
    value == "just now" || value == "right now" || value.hasSuffix(" ago")
  }

  private static func safeHTTPSURL(_ value: String) -> URL? {
    guard let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
    return url
  }
}

public struct CloudflarePagesProject: Equatable, Identifiable, Sendable {
  public let account: CloudflareAccount
  public let name: String
  public let domains: [String]
  public let usesGitProvider: Bool
  public let lastModified: String
  public let deployment: CloudflarePagesDeployment?

  public init(
    account: CloudflareAccount,
    name: String,
    domains: [String],
    usesGitProvider: Bool,
    lastModified: String,
    deployment: CloudflarePagesDeployment?
  ) {
    self.account = account
    self.name = name
    self.domains = domains
    self.usesGitProvider = usesGitProvider
    self.lastModified = lastModified
    self.deployment = deployment
  }

  public var id: String { "\(account.id)|pages|\(name)" }
  public var state: CloudflareResourceState { deployment?.state ?? .unknown }

  public func matchesSearch(_ query: String) -> Bool {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return true }
    let deploymentValues = deployment.map {
      [$0.environment, $0.branch, $0.shortCommitSHA, $0.deploymentURLString, $0.rawStatus, $0.state.title]
    } ?? []
    return ([CloudflareResourceKind.pages.title, name, account.name, account.id, lastModified, state.title]
      + domains + deploymentValues)
      .map { $0.lowercased() }
      .contains { $0.contains(normalized) }
  }
}

struct CloudflarePagesProjectRow: Decodable, Equatable, Sendable {
  let name: String
  let domains: [String]
  let usesGitProvider: Bool
  let lastModified: String

  enum CodingKeys: String, CodingKey {
    case name = "Project Name"
    case domainList = "Project Domains"
    case gitProvider = "Git Provider"
    case lastModified = "Last Modified"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    let domainList = try container.decodeIfPresent(String.self, forKey: .domainList) ?? ""
    domains = domainList.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    usesGitProvider = (try container.decodeIfPresent(String.self, forKey: .gitProvider) ?? "No")
      .caseInsensitiveCompare("Yes") == .orderedSame
    lastModified = try container.decodeIfPresent(String.self, forKey: .lastModified) ?? ""
  }
}

public struct CloudflareWorkerCandidate: Equatable, Identifiable, Sendable {
  public let name: String
  public let accountID: String?
  public let associatedProjectNames: [String]
  public let configurationPath: String

  public init(name: String, accountID: String?, associatedProjectNames: [String], configurationPath: String) {
    self.name = name
    self.accountID = accountID
    self.associatedProjectNames = associatedProjectNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    self.configurationPath = configurationPath
  }

  public var id: String { "\(accountID ?? "unscoped")|worker|\(name)" }
  public var isAccountAmbiguous: Bool { accountID == nil }
}

public struct CloudflareWorkerDeployment: Decodable, Equatable, Identifiable, Sendable {
  public struct VersionTraffic: Decodable, Equatable, Sendable {
    public let versionID: String
    public let percentage: Double

    enum CodingKeys: String, CodingKey {
      case versionID = "version_id"
      case percentage
    }

    public init(versionID: String, percentage: Double) {
      self.versionID = versionID
      self.percentage = percentage
    }
  }

  public struct Annotations: Decodable, Equatable, Sendable {
    public let message: String?
    public let triggeredBy: String?

    enum CodingKeys: String, CodingKey {
      case message = "workers/message"
      case triggeredBy = "workers/triggered_by"
    }

    public init(message: String?, triggeredBy: String?) {
      self.message = message
      self.triggeredBy = triggeredBy
    }
  }

  public let id: String
  public let createdAt: Date
  public let source: String
  public let strategy: String
  public let versions: [VersionTraffic]
  public let annotations: Annotations?

  enum CodingKeys: String, CodingKey {
    case id
    case createdAt = "created_on"
    case source
    case strategy
    case versions
    case annotations
  }

  public init(
    id: String,
    createdAt: Date,
    source: String,
    strategy: String,
    versions: [VersionTraffic],
    annotations: Annotations?
  ) {
    self.id = id
    self.createdAt = createdAt
    self.source = source
    self.strategy = strategy
    self.versions = versions
    self.annotations = annotations
  }

  public var state: CloudflareResourceState {
    guard strategy == "percentage", !versions.isEmpty else { return .unknown }
    if versions.count > 1 || versions.contains(where: { abs($0.percentage - 100) > 0.0001 }) {
      return .gradualRollout
    }
    return .active
  }
}

public struct CloudflareWorkerResource: Equatable, Identifiable, Sendable {
  public let account: CloudflareAccount?
  public let candidate: CloudflareWorkerCandidate
  public let deployment: CloudflareWorkerDeployment?

  public init(account: CloudflareAccount?, candidate: CloudflareWorkerCandidate, deployment: CloudflareWorkerDeployment?) {
    self.account = account
    self.candidate = candidate
    self.deployment = deployment
  }

  public var id: String { candidate.id }
  public var state: CloudflareResourceState { deployment?.state ?? .unknown }
  public var dashboardURL: URL? {
    guard let account, Self.isSafeIdentifier(account.id) else { return nil }
    return URL(string: "https://dash.cloudflare.com/\(account.id)/workers/overview")
  }

  public func matchesSearch(_ query: String) -> Bool {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return true }
    let deploymentValues = deployment.map {
      [$0.id, $0.source, $0.strategy, $0.annotations?.message, $0.annotations?.triggeredBy, $0.state.title]
        .compactMap { $0 }
    } ?? []
    return ([CloudflareResourceKind.worker.title, candidate.name, account?.name, account?.id, state.title]
      .compactMap { $0 } + candidate.associatedProjectNames + deploymentValues)
      .map { $0.lowercased() }
      .contains { $0.contains(normalized) }
  }

  private static func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0)
    }
  }
}

public enum CloudflareStatusBuilder {
  public static func sortedPages(_ projects: [CloudflarePagesProject]) -> [CloudflarePagesProject] {
    projects.sorted { left, right in
      if left.state.sortRank != right.state.sortRank { return left.state.sortRank < right.state.sortRank }
      let nameComparison = left.name.localizedCaseInsensitiveCompare(right.name)
      if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
      return left.account.name.localizedCaseInsensitiveCompare(right.account.name) == .orderedAscending
    }
  }

  public static func sortedWorkers(_ workers: [CloudflareWorkerResource]) -> [CloudflareWorkerResource] {
    workers.sorted { left, right in
      if left.state.sortRank != right.state.sortRank { return left.state.sortRank < right.state.sortRank }
      return left.candidate.name.localizedCaseInsensitiveCompare(right.candidate.name) == .orderedAscending
    }
  }
}

public enum CloudflareConnectionState: Equatable, Sendable {
  case checking
  case connected
  case missingCLI
  case unsupportedCLI(currentVersion: String)
  case authenticationRequired
  case rateLimited(message: String)
  case failed(message: String)
}

public struct CloudflareScopedFailure: Equatable, Sendable {
  public let scopeID: String
  public let message: String
  public let isRateLimited: Bool

  public init(scopeID: String, message: String, isRateLimited: Bool) {
    self.scopeID = scopeID
    self.message = message
    self.isRateLimited = isRateLimited
  }
}

public struct CloudflarePagesFetchResult: Equatable, Sendable {
  public let projects: [CloudflarePagesProject]
  public let successfulAccountIDs: Set<String>
  public let failures: [CloudflareScopedFailure]

  public init(projects: [CloudflarePagesProject], successfulAccountIDs: Set<String>, failures: [CloudflareScopedFailure]) {
    self.projects = projects
    self.successfulAccountIDs = successfulAccountIDs
    self.failures = failures
  }
}

public struct CloudflareWorkersFetchResult: Equatable, Sendable {
  public let resources: [CloudflareWorkerResource]
  public let currentCandidateIDs: Set<String>
  public let successfulCandidateIDs: Set<String>
  public let failures: [CloudflareScopedFailure]

  public init(
    resources: [CloudflareWorkerResource],
    currentCandidateIDs: Set<String>,
    successfulCandidateIDs: Set<String>,
    failures: [CloudflareScopedFailure]
  ) {
    self.resources = resources
    self.currentCandidateIDs = currentCandidateIDs
    self.successfulCandidateIDs = successfulCandidateIDs
    self.failures = failures
  }
}
