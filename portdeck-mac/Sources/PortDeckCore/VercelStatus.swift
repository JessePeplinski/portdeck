import Foundation

public enum VercelDeploymentHealthState: String, Equatable, Sendable {
  case ready
  case inProgress
  case failed
  case blocked
  case noDeployment
  case unknown

  public var title: String {
    switch self {
    case .ready:
      return "Ready"
    case .inProgress:
      return "Deploying now"
    case .failed:
      return "Failed"
    case .blocked:
      return "Blocked"
    case .noDeployment:
      return "No production deployment"
    case .unknown:
      return "Unknown"
    }
  }
}

public struct VercelScope: Equatable, Sendable {
  public let id: String
  public let name: String?
  public let slug: String?

  public init(id: String, name: String?, slug: String?) {
    self.id = id
    self.name = name
    self.slug = slug
  }

  public var displayName: String? {
    [name, slug]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
  }
}

public struct VercelProjectSnapshot: Equatable, Sendable {
  public let scope: VercelScope?
  public let projects: [VercelProjectStatus]

  public init(scope: VercelScope?, projects: [VercelProjectStatus]) {
    self.scope = scope
    self.projects = projects
  }
}

public struct VercelProjectStatus: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let productionDeploymentID: String?
  public let productionURLString: String?
  public let healthState: VercelDeploymentHealthState
  public let rawState: String?
  public let deploymentCreatedAt: Date?
  public let framework: String?
  public let productionBranch: String?
  public let deployedBranch: String?
  public let commitSHA: String?
  public let commitMessage: String?
  public let deploymentSource: String?
  public let deploymentBuildingAt: Date?
  public let deploymentReadyAt: Date?
  public let inspectorURLString: String?
  public let failureCode: String?
  public let failureMessage: String?

  public init(
    id: String,
    name: String,
    productionDeploymentID: String?,
    productionURLString: String?,
    healthState: VercelDeploymentHealthState,
    rawState: String?,
    deploymentCreatedAt: Date?,
    framework: String? = nil,
    productionBranch: String? = nil,
    deployedBranch: String? = nil,
    commitSHA: String? = nil,
    commitMessage: String? = nil,
    deploymentSource: String? = nil,
    deploymentBuildingAt: Date? = nil,
    deploymentReadyAt: Date? = nil,
    inspectorURLString: String? = nil,
    failureCode: String? = nil,
    failureMessage: String? = nil
  ) {
    self.id = id
    self.name = name
    self.productionDeploymentID = productionDeploymentID
    self.productionURLString = productionURLString
    self.healthState = healthState
    self.rawState = rawState
    self.deploymentCreatedAt = deploymentCreatedAt
    self.framework = framework
    self.productionBranch = productionBranch
    self.deployedBranch = deployedBranch
    self.commitSHA = commitSHA
    self.commitMessage = commitMessage
    self.deploymentSource = deploymentSource
    self.deploymentBuildingAt = deploymentBuildingAt
    self.deploymentReadyAt = deploymentReadyAt
    self.inspectorURLString = inspectorURLString
    self.failureCode = failureCode
    self.failureMessage = failureMessage
  }

  public var productionURL: URL? {
    guard let productionURLString else {
      return nil
    }
    return URL(string: productionURLString)
  }

  public var productionURLLabel: String? {
    guard let productionURL else {
      return nil
    }
    return productionURL.host(percentEncoded: false) ?? productionURL.absoluteString
  }

  public var inspectorURL: URL? {
    VercelProjectStatusBuilder.safeInspectorURL(inspectorURLString)
  }

  public var shortCommitSHA: String? {
    guard let commitSHA else {
      return nil
    }
    return String(commitSHA.prefix(7))
  }

  public var completedBuildDuration: TimeInterval? {
    guard let deploymentBuildingAt, let deploymentReadyAt else {
      return nil
    }
    let duration = deploymentReadyAt.timeIntervalSince(deploymentBuildingAt)
    return duration >= 0 ? duration : nil
  }

  public var failureDetail: String? {
    [failureCode, failureMessage]
      .compactMap { $0 }
      .joined(separator: ": ")
      .nilIfEmpty
  }

  public func dashboardURL(scope: VercelScope?) -> URL? {
    VercelProjectStatusBuilder.safeProjectDashboardURL(scope: scope, projectSlug: name)
  }

  public func matchesSearch(_ query: String) -> Bool {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else {
      return true
    }

    return [
      name,
      productionURLString,
      healthState.title,
      rawState,
      framework,
      productionBranch,
      deployedBranch,
      commitSHA,
      commitMessage,
      deploymentSource,
      failureCode,
      failureMessage
    ]
    .compactMap { $0?.lowercased() }
    .contains { $0.contains(normalized) }
  }
}

public struct VercelProjectsPage: Decodable, Equatable, Sendable {
  public let projects: [VercelAPIProject]
  public let pagination: VercelPagination
}

public struct VercelPagination: Decodable, Equatable, Sendable {
  public let next: Int64?
}

public struct VercelAPIProject: Decodable, Equatable, Sendable {
  public let id: String
  public let accountId: String?
  public let name: String
  public let framework: String?
  public let alias: [String]?
  public let link: VercelAPIProjectLink?
  public let latestDeployments: [VercelAPIDeployment]?
}

public struct VercelAPIProjectLink: Decodable, Equatable, Sendable {
  public let productionBranch: String?
}

public struct VercelAPIDeployment: Decodable, Equatable, Sendable {
  public let id: String
  public let url: String?
  public let alias: [String]?
  public let target: String?
  public let readyState: String?
  public let createdAt: Int64?
  public let buildingAt: Int64?
  public let readyAt: Int64?
  public let meta: VercelDeploymentGitMetadata?
}

public struct VercelDeploymentsPage: Decodable, Equatable, Sendable {
  public let deployments: [VercelAPIRecentDeployment]
}

public struct VercelAPIRecentDeployment: Decodable, Equatable, Sendable {
  public let uid: String
  public let projectId: String
  public let target: String?
  public let state: String?
  public let readyState: String?
  public let createdAt: Int64?
  public let buildingAt: Int64?
  public let ready: Int64?
  public let url: String?
  public let source: String?
  public let inspectorUrl: String?
  public let errorCode: String?
  public let errorMessage: String?
  public let meta: VercelDeploymentGitMetadata?

  public init(
    uid: String,
    projectId: String,
    target: String?,
    state: String?,
    readyState: String?,
    createdAt: Int64?,
    url: String?,
    buildingAt: Int64? = nil,
    ready: Int64? = nil,
    source: String? = nil,
    inspectorUrl: String? = nil,
    errorCode: String? = nil,
    errorMessage: String? = nil,
    meta: VercelDeploymentGitMetadata? = nil
  ) {
    self.uid = uid
    self.projectId = projectId
    self.target = target
    self.state = state
    self.readyState = readyState
    self.createdAt = createdAt
    self.buildingAt = buildingAt
    self.ready = ready
    self.url = url
    self.source = source
    self.inspectorUrl = inspectorUrl
    self.errorCode = errorCode
    self.errorMessage = errorMessage
    self.meta = meta
  }
}

public struct VercelDeploymentGitMetadata: Decodable, Equatable, Sendable {
  public let branch: String?
  public let commitSHA: String?
  public let commitMessage: String?

  public init(branch: String?, commitSHA: String?, commitMessage: String?) {
    self.branch = branch
    self.commitSHA = commitSHA
    self.commitMessage = commitMessage
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: VercelMetadataCodingKey.self)
    var branch: String?
    var commitSHA: String?
    var commitMessage: String?

    for key in container.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
      let normalizedKey = key.stringValue.lowercased()
      guard let value = try? container.decodeIfPresent(String.self, forKey: key) else {
        continue
      }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        continue
      }

      if normalizedKey.hasSuffix("commitref"), branch == nil {
        branch = trimmed
      } else if normalizedKey.hasSuffix("commitsha"), commitSHA == nil {
        commitSHA = trimmed
      } else if normalizedKey.hasSuffix("commitmessage"), commitMessage == nil {
        commitMessage = trimmed
      }
    }

    self.branch = branch
    self.commitSHA = commitSHA
    self.commitMessage = commitMessage
  }
}

public struct VercelAPITeam: Decodable, Equatable, Sendable {
  public let id: String
  public let name: String?
  public let slug: String?
}

public enum VercelProjectStatusBuilder {
  public static func build(from projects: [VercelAPIProject]) -> [VercelProjectStatus] {
    projects
      .map(buildProjectStatus)
      .sorted(by: sortsBefore)
  }

  public static func merge(
    recentProductionDeployments: [VercelAPIRecentDeployment],
    onto projects: [VercelProjectStatus]
  ) -> [VercelProjectStatus] {
    let latestByProjectID = recentProductionDeployments.reduce(
      into: [String: VercelAPIRecentDeployment]()
    ) { result, deployment in
      guard deployment.target?.lowercased() == "production" else {
        return
      }

      guard let existing = result[deployment.projectId] else {
        result[deployment.projectId] = deployment
        return
      }

      if (deployment.createdAt ?? .min) > (existing.createdAt ?? .min) {
        result[deployment.projectId] = deployment
      }
    }

    return projects.map { project in
      guard let deployment = latestByProjectID[project.id],
        shouldOverlay(deployment, onto: project)
      else {
        return project
      }

      let rawState = deployment.state ?? deployment.readyState
      return VercelProjectStatus(
        id: project.id,
        name: project.name,
        productionDeploymentID: deployment.uid,
        productionURLString: project.productionURLString ?? normalizedHTTPSURLString(deployment.url),
        healthState: healthState(for: rawState),
        rawState: rawState,
        deploymentCreatedAt: deployment.createdAt.map(millisecondsToDate) ?? project.deploymentCreatedAt,
        framework: project.framework,
        productionBranch: project.productionBranch,
        deployedBranch: deployment.meta?.branch,
        commitSHA: deployment.meta?.commitSHA,
        commitMessage: deployment.meta?.commitMessage,
        deploymentSource: normalizedMetadataValue(deployment.source),
        deploymentBuildingAt: deployment.buildingAt.map(millisecondsToDate),
        deploymentReadyAt: deployment.ready.map(millisecondsToDate),
        inspectorURLString: safeInspectorURL(deployment.inspectorUrl)?.absoluteString,
        failureCode: sanitizedFailureValue(deployment.errorCode, limit: 80),
        failureMessage: sanitizedFailureValue(deployment.errorMessage, limit: 280)
      )
    }
    .sorted(by: sortsBefore)
  }

  private static func buildProjectStatus(_ project: VercelAPIProject) -> VercelProjectStatus {
    let deployment = (project.latestDeployments ?? [])
      .filter { $0.target?.lowercased() == "production" }
      .max { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }

    guard let deployment else {
      return VercelProjectStatus(
        id: project.id,
        name: project.name,
        productionDeploymentID: nil,
        productionURLString: nil,
        healthState: .noDeployment,
        rawState: nil,
        deploymentCreatedAt: nil,
        framework: normalizedMetadataValue(project.framework),
        productionBranch: normalizedMetadataValue(project.link?.productionBranch)
      )
    }

    return VercelProjectStatus(
      id: project.id,
      name: project.name,
      productionDeploymentID: deployment.id,
      productionURLString: normalizedHTTPSURLString(
        deployment.alias?.first ?? project.alias?.first ?? deployment.url
      ),
      healthState: healthState(for: deployment.readyState),
      rawState: deployment.readyState,
      deploymentCreatedAt: deployment.createdAt.map(millisecondsToDate),
      framework: normalizedMetadataValue(project.framework),
      productionBranch: normalizedMetadataValue(project.link?.productionBranch),
      deployedBranch: deployment.meta?.branch,
      commitSHA: deployment.meta?.commitSHA,
      commitMessage: deployment.meta?.commitMessage,
      deploymentBuildingAt: deployment.buildingAt.map(millisecondsToDate),
      deploymentReadyAt: deployment.readyAt.map(millisecondsToDate)
    )
  }

  private static func shouldOverlay(
    _ deployment: VercelAPIRecentDeployment,
    onto project: VercelProjectStatus
  ) -> Bool {
    if deployment.uid == project.productionDeploymentID {
      return true
    }

    guard let deploymentCreatedAt = deployment.createdAt else {
      return project.deploymentCreatedAt == nil
    }
    guard let projectCreatedAt = project.deploymentCreatedAt else {
      return true
    }

    return millisecondsToDate(deploymentCreatedAt) >= projectCreatedAt
  }

  private static func millisecondsToDate(_ value: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
  }

  private static func sortsBefore(
    _ left: VercelProjectStatus,
    _ right: VercelProjectStatus
  ) -> Bool {
    switch (left.deploymentCreatedAt, right.deploymentCreatedAt) {
    case let (leftDate?, rightDate?) where leftDate != rightDate:
      return leftDate > rightDate
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    default:
      return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }
  }

  public static func healthState(for rawState: String?) -> VercelDeploymentHealthState {
    guard let state = rawState?.uppercased() else {
      return .unknown
    }

    switch state {
    case "READY":
      return .ready
    case "BUILDING", "QUEUED", "INITIALIZING":
      return .inProgress
    case "ERROR", "CANCELED":
      return .failed
    case "BLOCKED":
      return .blocked
    default:
      return .unknown
    }
  }

  public static func normalizedHTTPSURLString(_ rawValue: String?) -> String? {
    guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }

    if !value.contains("://") {
      value = "https://\(value)"
    }

    guard let components = URLComponents(string: value),
      components.scheme == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil
    else {
      return nil
    }

    return components.url?.absoluteString
  }

  public static func safeInspectorURL(_ rawValue: String?) -> URL? {
    guard let normalized = normalizedHTTPSURLString(rawValue),
      let url = URL(string: normalized),
      url.host(percentEncoded: false)?.lowercased() == "vercel.com",
      url.port == nil
    else {
      return nil
    }
    return url
  }

  public static func safeProjectDashboardURL(scope: VercelScope?, projectSlug: String) -> URL? {
    guard let scopeSlug = scope?.slug,
      isSafeSlug(scopeSlug),
      isSafeSlug(projectSlug)
    else {
      return nil
    }

    var components = URLComponents()
    components.scheme = "https"
    components.host = "vercel.com"
    components.path = "/\(scopeSlug)/\(projectSlug)"
    return components.url
  }

  public static func sanitizedFailureValue(_ rawValue: String?, limit: Int = 280) -> String? {
    guard let rawValue else {
      return nil
    }

    var message = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else {
      return nil
    }

    let replacements = [
      (#"(?i)((?:VERCEL_TOKEN|VERCEL_ACCESS_TOKEN)\s*[=:]\s*)\S+"#, "$1<redacted>"),
      (#"(?i)((?:authorization:\s*bearer|bearer|access[_ -]?token|api[_ -]?key|secret)\s*[=:]?\s*)\S+"#, "$1<redacted>"),
      (#"(?i)([?&](?:access_token|api_token|token|api_key|key)=)[^&\s]+"#, "$1<redacted>"),
      (#"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]{10,})?"#, "<redacted>")
    ]

    for (pattern, replacement) in replacements {
      message = message.replacingOccurrences(
        of: pattern,
        with: replacement,
        options: .regularExpression
      )
    }

    return String(message.prefix(max(1, limit)))
  }

  private static func normalizedMetadataValue(_ rawValue: String?) -> String? {
    rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  private static func isSafeSlug(_ value: String) -> Bool {
    value.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,98}[a-z0-9])?$"#, options: .regularExpression) != nil
  }
}

private struct VercelMetadataCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
