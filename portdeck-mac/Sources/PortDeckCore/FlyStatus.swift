import Foundation

public enum FlyAppState: String, Equatable, Sendable {
  case deployed
  case suspended
  case unknown

  public var title: String {
    switch self {
    case .deployed: return "Deployed"
    case .suspended: return "Suspended"
    case .unknown: return "Unknown"
    }
  }

  public static func map(_ rawStatus: String?) -> FlyAppState {
    switch rawStatus?.lowercased() {
    case "deployed": return .deployed
    case "suspended": return .suspended
    default: return .unknown
    }
  }
}

public enum FlyMachineState: String, Equatable, Sendable {
  case running
  case stopped
  case suspended
  case starting
  case removing
  case removed
  case unknown

  public var title: String {
    switch self {
    case .running: return "Running"
    case .stopped: return "Stopped"
    case .suspended: return "Suspended"
    case .starting: return "Starting"
    case .removing: return "Removing"
    case .removed: return "Removed"
    case .unknown: return "Unknown"
    }
  }

  public static func map(_ rawStatus: String?) -> FlyMachineState {
    switch rawStatus?.lowercased() {
    case "started": return .running
    case "stopped": return .stopped
    case "suspended": return .suspended
    case "created": return .starting
    case "destroying": return .removing
    case "destroyed": return .removed
    default: return .unknown
    }
  }
}

public enum FlyHostState: String, Equatable, Sendable {
  case reachable
  case unreachable
  case unknown

  public var title: String {
    switch self {
    case .reachable: return "Reachable"
    case .unreachable: return "Unreachable"
    case .unknown: return "Unknown host"
    }
  }

  public static func map(_ rawStatus: String?) -> FlyHostState {
    switch rawStatus?.lowercased() {
    case "ok": return .reachable
    case "unreachable": return .unreachable
    default: return .unknown
    }
  }
}

public enum FlyCheckState: String, Equatable, Sendable {
  case passing
  case warning
  case critical
  case unknown

  public var title: String {
    switch self {
    case .passing: return "Passing"
    case .warning: return "Warning"
    case .critical: return "Critical"
    case .unknown: return "Unknown"
    }
  }

  public static func map(_ rawStatus: String?) -> FlyCheckState {
    switch rawStatus?.lowercased() {
    case "passing": return .passing
    case "warning": return .warning
    case "critical": return .critical
    default: return .unknown
    }
  }
}

public enum FlyReleaseState: String, Equatable, Sendable {
  case successful
  case failed
  case inProgress
  case unknown

  public var title: String {
    switch self {
    case .successful: return "Successful"
    case .failed: return "Failed"
    case .inProgress: return "In progress"
    case .unknown: return "Unknown"
    }
  }

  public static func map(_ rawStatus: String?) -> FlyReleaseState {
    switch rawStatus?.lowercased() {
    case "complete": return .successful
    case "failed", "interrupted": return .failed
    case "pending", "running": return .inProgress
    default: return .unknown
    }
  }
}

public enum FlyAppEvidenceState: String, Equatable, Sendable {
  case unhealthy
  case degraded
  case transitioning
  case inactive
  case healthy
  case unknown

  public var title: String {
    switch self {
    case .unhealthy: return "Unhealthy"
    case .degraded: return "Degraded"
    case .transitioning: return "In progress"
    case .inactive: return "Inactive"
    case .healthy: return "Healthy evidence"
    case .unknown: return "Unknown"
    }
  }

  var sortRank: Int {
    switch self {
    case .unhealthy: return 0
    case .degraded: return 1
    case .transitioning: return 2
    case .inactive: return 3
    case .healthy: return 4
    case .unknown: return 5
    }
  }
}

public struct FlyOrganization: Equatable, Hashable, Identifiable, Sendable {
  public var id: String { slug }
  public let slug: String
  public let name: String

  public init(slug: String, name: String) {
    self.slug = slug
    self.name = name
  }
}

public struct FlyMachineCheck: Equatable, Identifiable, Sendable {
  public var id: String { name }
  public let name: String
  public let rawStatus: String?
  public let updatedAt: Date?

  public init(name: String, rawStatus: String?, updatedAt: Date?) {
    self.name = name
    self.rawStatus = rawStatus
    self.updatedAt = updatedAt
  }

  public var state: FlyCheckState { .map(rawStatus) }
}

public struct FlyMachine: Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String?
  public let rawState: String?
  public let region: String?
  public let rawHostStatus: String?
  public let updatedAt: Date?
  public let checks: [FlyMachineCheck]

  public init(
    id: String,
    name: String? = nil,
    rawState: String? = nil,
    region: String? = nil,
    rawHostStatus: String? = nil,
    updatedAt: Date? = nil,
    checks: [FlyMachineCheck] = []
  ) {
    self.id = id
    self.name = name
    self.rawState = rawState
    self.region = region
    self.rawHostStatus = rawHostStatus
    self.updatedAt = updatedAt
    self.checks = checks
  }

  public var state: FlyMachineState { .map(rawState) }
  public var hostState: FlyHostState { .map(rawHostStatus) }
  public var displayName: String { name?.isEmpty == false ? name! : id }

  public func matchesSearch(_ query: String) -> Bool {
    let normalized = FlyStatusBuilder.normalizedSearch(query)
    guard !normalized.isEmpty else { return true }
    let values = [name, id, rawState, state.title, region, rawHostStatus, hostState.title]
      .compactMap { $0 }
      + checks.flatMap { [$0.name, $0.rawStatus, $0.state.title].compactMap { $0 } }
    return values.contains { $0.lowercased().contains(normalized) }
  }
}

public struct FlyRelease: Equatable, Identifiable, Sendable {
  public let id: String
  public let version: Int
  public let rawStatus: String?
  public let description: String?
  public let createdAt: Date?

  public init(id: String, version: Int, rawStatus: String?, description: String?, createdAt: Date?) {
    self.id = id
    self.version = version
    self.rawStatus = rawStatus
    self.description = description
    self.createdAt = createdAt
  }

  public var state: FlyReleaseState { .map(rawStatus) }
}

public struct FlyApp: Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let rawStatus: String?
  public let deployed: Bool
  public let organization: FlyOrganization
  public let hostname: String?
  public let appURLString: String?
  public let currentReleaseVersion: Int?
  public let machines: [FlyMachine]
  public let latestRelease: FlyRelease?
  public let isStatusRetained: Bool
  public let isReleaseRetained: Bool

  public init(
    id: String,
    name: String,
    rawStatus: String? = nil,
    deployed: Bool = false,
    organization: FlyOrganization,
    hostname: String? = nil,
    appURLString: String? = nil,
    currentReleaseVersion: Int? = nil,
    machines: [FlyMachine] = [],
    latestRelease: FlyRelease? = nil,
    isStatusRetained: Bool = false,
    isReleaseRetained: Bool = false
  ) {
    self.id = id
    self.name = name
    self.rawStatus = rawStatus
    self.deployed = deployed
    self.organization = organization
    self.hostname = hostname
    self.appURLString = appURLString
    self.currentReleaseVersion = currentReleaseVersion
    self.machines = machines
    self.latestRelease = latestRelease
    self.isStatusRetained = isStatusRetained
    self.isReleaseRetained = isReleaseRetained
  }

  public var identityKey: String { id.isEmpty ? "name:\(name)" : "id:\(id)" }
  public var state: FlyAppState { .map(rawStatus) }

  public var productionURL: URL? {
    if let appURLString, let safe = FlyStatusBuilder.safeHTTPSURL(appURLString) { return safe }
    guard let hostname, !hostname.isEmpty else { return nil }
    return FlyStatusBuilder.safeHTTPSURL("https://\(hostname)")
  }

  public var dashboardURL: URL? { FlyStatusBuilder.dashboardURL(appName: name) }

  public var evidenceState: FlyAppEvidenceState {
    if latestRelease?.state == .failed
      || machines.contains(where: { $0.hostState == .unreachable })
      || machines.flatMap(\.checks).contains(where: { $0.state == .critical })
    {
      return .unhealthy
    }

    if machines.contains(where: { $0.hostState == .unknown })
      || machines.flatMap(\.checks).contains(where: { $0.state == .warning || $0.state == .unknown })
      || isStatusRetained || isReleaseRetained
    {
      return .degraded
    }

    if latestRelease?.state == .inProgress
      || machines.contains(where: { $0.state == .starting || $0.state == .removing })
    {
      return .transitioning
    }

    if state == .suspended
      || (!machines.isEmpty && machines.allSatisfy { [.stopped, .suspended, .removed].contains($0.state) })
    {
      return .inactive
    }

    let running = machines.filter { $0.state == .running }
    if state == .deployed, !running.isEmpty,
      running.allSatisfy({ machine in
        machine.hostState == .reachable && !machine.checks.isEmpty
          && machine.checks.allSatisfy { $0.state == .passing }
      })
    {
      return .healthy
    }

    return .unknown
  }

  public var regions: [String] {
    Array(Set(machines.compactMap(\.region).filter { !$0.isEmpty })).sorted()
  }

  public func matchesSearch(_ query: String) -> Bool {
    let normalized = FlyStatusBuilder.normalizedSearch(query)
    guard !normalized.isEmpty else { return true }
    let values = [
      name, id, organization.name, organization.slug, hostname, productionURL?.absoluteString,
      rawStatus, state.title, evidenceState.title, latestRelease?.rawStatus,
      latestRelease?.state.title, latestRelease.map { "v\($0.version)" }, latestRelease?.description
    ].compactMap { $0 }
    return values.contains { $0.lowercased().contains(normalized) }
      || machines.contains { $0.matchesSearch(normalized) }
  }

  public func retainingStatus(from previous: FlyApp) -> FlyApp {
    FlyApp(
      id: id, name: name, rawStatus: rawStatus, deployed: deployed, organization: organization,
      hostname: hostname, appURLString: appURLString,
      currentReleaseVersion: currentReleaseVersion ?? previous.currentReleaseVersion,
      machines: previous.machines, latestRelease: latestRelease,
      isStatusRetained: true, isReleaseRetained: isReleaseRetained
    )
  }

  public func retainingRelease(from previous: FlyApp) -> FlyApp {
    let retained = currentReleaseVersion != nil && currentReleaseVersion == previous.latestRelease?.version
      ? previous.latestRelease
      : nil
    return FlyApp(
      id: id, name: name, rawStatus: rawStatus, deployed: deployed, organization: organization,
      hostname: hostname, appURLString: appURLString, currentReleaseVersion: currentReleaseVersion,
      machines: machines, latestRelease: retained,
      isStatusRetained: isStatusRetained, isReleaseRetained: retained != nil
    )
  }
}

public struct FlyScopedFailure: Equatable, Sendable {
  public enum Scope: String, Equatable, Sendable {
    case status
    case release
  }

  public let appKey: String
  public let appName: String
  public let scope: Scope
  public let message: String
  public let isRateLimited: Bool

  public init(appKey: String, appName: String, scope: Scope, message: String, isRateLimited: Bool = false) {
    self.appKey = appKey
    self.appName = appName
    self.scope = scope
    self.message = message
    self.isRateLimited = isRateLimited
  }
}

public struct FlySnapshotResult: Equatable, Sendable {
  public let organizations: [FlyOrganization]
  public let apps: [FlyApp]
  public let successfulStatusAppKeys: Set<String>
  public let successfulReleaseAppKeys: Set<String>
  public let failures: [FlyScopedFailure]

  public init(
    organizations: [FlyOrganization],
    apps: [FlyApp],
    successfulStatusAppKeys: Set<String> = [],
    successfulReleaseAppKeys: Set<String> = [],
    failures: [FlyScopedFailure] = []
  ) {
    self.organizations = organizations
    self.apps = apps
    self.successfulStatusAppKeys = successfulStatusAppKeys
    self.successfulReleaseAppKeys = successfulReleaseAppKeys
    self.failures = failures
  }
}

public enum FlyConnectionState: Equatable, Sendable {
  case checking
  case connected
  case missingRuntime
  case incompatibleRuntime(currentVersion: String)
  case authenticationRequired
  case rateLimited(message: String)
  case failed(message: String)
}

public enum FlyStatusBuilder {
  public static func sortedApps(_ apps: [FlyApp]) -> [FlyApp] {
    apps.sorted { left, right in
      if left.evidenceState.sortRank != right.evidenceState.sortRank {
        return left.evidenceState.sortRank < right.evidenceState.sortRank
      }
      let organizationOrder = left.organization.name.localizedCaseInsensitiveCompare(right.organization.name)
      if organizationOrder != .orderedSame { return organizationOrder == .orderedAscending }
      return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }
  }

  public static func safeHTTPSURL(_ rawValue: String?) -> URL? {
    guard let rawValue, let components = URLComponents(string: rawValue),
      components.scheme?.lowercased() == "https",
      components.user == nil, components.password == nil,
      let host = components.host, !host.isEmpty
    else { return nil }
    return components.url
  }

  public static func dashboardURL(appName: String) -> URL? {
    let pattern = #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#
    guard appName.range(of: pattern, options: .regularExpression) != nil else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "fly.io"
    components.path = "/apps/\(appName)"
    return components.url
  }

  static func normalizedSearch(_ query: String) -> String {
    query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
