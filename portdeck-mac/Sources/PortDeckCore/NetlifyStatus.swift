import Foundation

public struct NetlifyRuntimeEvidence: Equatable, Sendable {
  public let cliVersion: String
  public let operatingSystem: String
  public let architecture: String
  public let nodeVersion: String

  public init(cliVersion: String, operatingSystem: String, architecture: String, nodeVersion: String) {
    self.cliVersion = cliVersion
    self.operatingSystem = operatingSystem
    self.architecture = architecture
    self.nodeVersion = nodeVersion
  }
}

public enum NetlifyDeploymentState: String, CaseIterable, Equatable, Sendable {
  case healthy
  case failed
  case deploying
  case inactive
  case unknown

  public var title: String {
    switch self {
    case .healthy: return "Ready"
    case .failed: return "Failed"
    case .deploying: return "Deploying"
    case .inactive: return "Rejected"
    case .unknown: return "Unknown"
    }
  }

  public static func map(_ rawState: String?) -> NetlifyDeploymentState {
    switch rawState?.lowercased() {
    case "ready": return .healthy
    case "error": return .failed
    case "rejected": return .inactive
    case "new", "pending_review", "accepted", "enqueued", "building", "uploading", "uploaded",
      "preparing", "prepared", "processing", "processed", "retrying":
      return .deploying
    default: return .unknown
    }
  }
}

public struct NetlifyAccount: Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let slug: String?

  public init(id: String, name: String, slug: String? = nil) {
    self.id = id
    self.name = name
    self.slug = slug
  }
}

public struct NetlifyDeployment: Equatable, Identifiable, Sendable {
  public let id: String
  public let siteID: String
  public let rawState: String
  public let context: String?
  public let createdAt: Date?
  public let updatedAt: Date?
  public let publishedAt: Date?
  public let branch: String?
  public let commitReference: String?
  public let title: String?
  public let errorSummary: String?
  public let deployURLString: String?
  public let dashboardURLString: String?

  public init(
    id: String,
    siteID: String,
    rawState: String,
    context: String? = nil,
    createdAt: Date? = nil,
    updatedAt: Date? = nil,
    publishedAt: Date? = nil,
    branch: String? = nil,
    commitReference: String? = nil,
    title: String? = nil,
    errorSummary: String? = nil,
    deployURLString: String? = nil,
    dashboardURLString: String? = nil
  ) {
    self.id = id
    self.siteID = siteID
    self.rawState = rawState
    self.context = Self.bounded(context, limit: 80)
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.publishedAt = publishedAt
    self.branch = Self.bounded(branch, limit: 120)
    self.commitReference = Self.bounded(commitReference, limit: 80)
    self.title = Self.bounded(title, limit: 160)
    self.errorSummary = Self.bounded(errorSummary, limit: 240)
    self.deployURLString = NetlifySafeLink.publicURL(deployURLString)?.absoluteString
    self.dashboardURLString = NetlifySafeLink.dashboardURL(dashboardURLString)?.absoluteString
  }

  public var state: NetlifyDeploymentState { .map(rawState) }
  public var deployURL: URL? { NetlifySafeLink.publicURL(deployURLString) }
  public var dashboardURL: URL? { NetlifySafeLink.dashboardURL(dashboardURLString) }
  public var shortCommitReference: String? {
    guard let commitReference, !commitReference.isEmpty else { return nil }
    return String(commitReference.prefix(8))
  }
  public var bestTimestamp: Date? { publishedAt ?? updatedAt ?? createdAt }

  private static func bounded(_ value: String?, limit: Int) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return String(trimmed.prefix(limit))
  }
}

public struct NetlifySite: Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let account: NetlifyAccount
  public let productionURLString: String?
  public let dashboardURLString: String?
  public let latestDeployment: NetlifyDeployment?
  public let hasDeploymentFailure: Bool
  public let isDeploymentRetained: Bool

  public init(
    id: String,
    name: String,
    account: NetlifyAccount,
    productionURLString: String? = nil,
    dashboardURLString: String? = nil,
    latestDeployment: NetlifyDeployment? = nil,
    hasDeploymentFailure: Bool = false,
    isDeploymentRetained: Bool = false
  ) {
    self.id = id
    self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
    self.account = account
    self.productionURLString = NetlifySafeLink.publicURL(productionURLString)?.absoluteString
    self.dashboardURLString = NetlifySafeLink.dashboardURL(dashboardURLString)?.absoluteString
    self.latestDeployment = latestDeployment?.siteID == id ? latestDeployment : nil
    self.hasDeploymentFailure = hasDeploymentFailure
    self.isDeploymentRetained = isDeploymentRetained
  }

  public var productionURL: URL? { NetlifySafeLink.publicURL(productionURLString) }
  public var dashboardURL: URL? { NetlifySafeLink.dashboardURL(dashboardURLString) }

  public func retainingDeployment(from prior: NetlifySite) -> NetlifySite {
    guard prior.id == id else { return self }
    return NetlifySite(
      id: id,
      name: name,
      account: account,
      productionURLString: productionURLString,
      dashboardURLString: dashboardURLString,
      latestDeployment: prior.latestDeployment,
      hasDeploymentFailure: true,
      isDeploymentRetained: prior.latestDeployment != nil
    )
  }

  public func matchesSearch(_ searchText: String) -> Bool {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return true }
    let deployment = latestDeployment
    let values = [
      account.name, account.id, account.slug, name, id, productionURLString,
      deployment?.rawState, deployment?.state.title, deployment?.id, deployment?.context,
      deployment?.branch, deployment?.shortCommitReference, deployment?.title,
      deployment?.errorSummary, deployment?.deployURLString
    ].compactMap { $0?.lowercased() }
    return values.contains { $0.contains(query) }
  }
}

public struct NetlifyScopedFailure: Equatable, Sendable {
  public let siteID: String
  public let siteName: String
  public let message: String
  public let isRateLimited: Bool

  public init(siteID: String, siteName: String, message: String, isRateLimited: Bool = false) {
    self.siteID = siteID
    self.siteName = siteName
    self.message = String(message.prefix(500))
    self.isRateLimited = isRateLimited
  }
}

public struct NetlifySnapshotResult: Equatable, Sendable {
  public let sites: [NetlifySite]
  public let successfulDeploymentSiteIDs: Set<String>
  public let failures: [NetlifyScopedFailure]

  public init(
    sites: [NetlifySite],
    successfulDeploymentSiteIDs: Set<String> = [],
    failures: [NetlifyScopedFailure] = []
  ) {
    self.sites = sites
    self.successfulDeploymentSiteIDs = successfulDeploymentSiteIDs
    self.failures = failures
  }
}

public enum NetlifyConnectionState: Equatable, Sendable {
  case checking
  case connected
  case missingCLI
  case unsupportedCLI(currentVersion: String)
  case authenticationRequired
  case rateLimited(message: String)
  case failed(message: String)
}

public enum NetlifyStatusBuilder {
  public static func sortedSites(_ sites: [NetlifySite]) -> [NetlifySite] {
    sites.sorted { left, right in
      let leftBucket = evidenceBucket(left)
      let rightBucket = evidenceBucket(right)
      if leftBucket != rightBucket { return leftBucket < rightBucket }
      let accountOrder = left.account.name.localizedCaseInsensitiveCompare(right.account.name)
      if accountOrder != .orderedSame { return accountOrder == .orderedAscending }
      return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }
  }

  private static func evidenceBucket(_ site: NetlifySite) -> Int {
    if site.latestDeployment?.state == .failed { return 0 }
    if site.hasDeploymentFailure { return 1 }
    switch site.latestDeployment?.state {
    case .deploying: return 2
    case .inactive: return 3
    case .healthy: return 4
    case .failed: return 0
    case .unknown, .none: return 5
    }
  }
}

public enum NetlifySafeLink {
  public static func publicURL(_ rawValue: String?) -> URL? {
    guard let rawValue,
      let components = URLComponents(string: rawValue),
      components.scheme?.lowercased() == "https",
      components.user == nil,
      components.password == nil,
      components.port == nil,
      components.query == nil,
      components.fragment == nil,
      let host = components.host?.lowercased(),
      isPublicHost(host)
    else {
      return nil
    }
    return components.url
  }

  public static func dashboardURL(_ rawValue: String?) -> URL? {
    guard let rawValue,
      let components = URLComponents(string: rawValue),
      components.scheme?.lowercased() == "https",
      components.host?.lowercased() == "app.netlify.com",
      components.user == nil,
      components.password == nil,
      components.port == nil,
      components.query == nil,
      components.fragment == nil
    else {
      return nil
    }
    let pattern = #"^/sites/[A-Za-z0-9][A-Za-z0-9._-]*(?:/deploys/[A-Za-z0-9][A-Za-z0-9._-]*)?/?$"#
    guard components.path.range(of: pattern, options: .regularExpression) != nil else { return nil }
    return components.url
  }

  public static func siteDashboardURL(siteName: String) -> URL? {
    dashboardURL("https://app.netlify.com/sites/\(siteName)")
  }

  public static func deploymentDashboardURL(siteName: String, deploymentID: String) -> URL? {
    dashboardURL("https://app.netlify.com/sites/\(siteName)/deploys/\(deploymentID)")
  }

  private static func isPublicHost(_ host: String) -> Bool {
    guard host.contains("."), !host.hasSuffix(".local"), host != "localhost" else { return false }
    if host.range(of: #"^\d{1,3}(?:\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
      let parts = host.split(separator: ".").compactMap { Int($0) }
      guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
      if parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
        || (parts[0] == 172 && (16...31).contains(parts[1]))
      {
        return false
      }
    }
    return !host.contains(" ")
  }
}
