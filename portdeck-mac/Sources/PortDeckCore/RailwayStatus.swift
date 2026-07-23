import Foundation

public enum RailwayResourceState: String, Equatable, Sendable {
  case failed
  case crashed
  case deploying
  case queued
  case removing
  case removed
  case unknown
  case successful

  public var title: String {
    switch self {
    case .failed: return "Failed"
    case .crashed: return "Crashed"
    case .deploying: return "Deploying"
    case .queued: return "Queued"
    case .removing: return "Removing"
    case .removed: return "Removed"
    case .unknown: return "Unknown"
    case .successful: return "Successful"
    }
  }

  var sortRank: Int {
    switch self {
    case .failed, .crashed: return 0
    case .deploying: return 1
    case .queued, .removing, .removed, .unknown: return 2
    case .successful: return 3
    }
  }

  public static func map(_ rawStatus: String?) -> RailwayResourceState {
    switch rawStatus?.uppercased() {
    case "SUCCESS": return .successful
    case "FAILED": return .failed
    case "CRASHED": return .crashed
    case "BUILDING", "DEPLOYING", "INITIALIZING": return .deploying
    case "WAITING", "QUEUED": return .queued
    case "REMOVING": return .removing
    case "REMOVED": return .removed
    default: return .unknown
    }
  }
}

public enum RailwayProductionState: Equatable, Sendable {
  case available
  case unavailable
  case failed(message: String)
}

public struct RailwayWorkspace: Decodable, Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct RailwayRegion: Decodable, Equatable, Sendable {
  public let name: String
  public let location: String?
  public let configured: Int

  public init(name: String, location: String? = nil, configured: Int) {
    self.name = name
    self.location = location
    self.configured = configured
  }
}

public struct RailwayReplicas: Decodable, Equatable, Sendable {
  public let configured: Int
  public let running: Int
  public let crashed: Int
  public let exited: Int
  public let total: Int

  public init(configured: Int, running: Int, crashed: Int, exited: Int, total: Int) {
    self.configured = configured
    self.running = running
    self.crashed = crashed
    self.exited = exited
    self.total = total
  }
}

public struct RailwayDeployment: Equatable, Identifiable, Sendable {
  public let id: String
  public let rawStatus: String?
  public let createdAt: Date?
  public let branch: String?
  public let commitSHA: String?
  public let commitMessage: String?

  public init(
    id: String,
    rawStatus: String?,
    createdAt: Date?,
    branch: String? = nil,
    commitSHA: String? = nil,
    commitMessage: String? = nil
  ) {
    self.id = id
    self.rawStatus = rawStatus
    self.createdAt = createdAt
    self.branch = branch
    self.commitSHA = commitSHA
    self.commitMessage = commitMessage
  }

  public var state: RailwayResourceState { .map(rawStatus) }
  public var shortCommitSHA: String? { commitSHA.map { String($0.prefix(7)) } }
}

public struct RailwayService: Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let currentRawStatus: String?
  public let latestDeployment: RailwayDeployment?
  public let productionURLString: String?
  public let regions: [RailwayRegion]
  public let replicas: RailwayReplicas?

  public init(
    id: String,
    name: String,
    currentRawStatus: String? = nil,
    latestDeployment: RailwayDeployment? = nil,
    productionURLString: String? = nil,
    regions: [RailwayRegion] = [],
    replicas: RailwayReplicas? = nil
  ) {
    self.id = id
    self.name = name
    self.currentRawStatus = currentRawStatus
    self.latestDeployment = latestDeployment
    self.productionURLString = productionURLString
    self.regions = regions
    self.replicas = replicas
  }

  public var state: RailwayResourceState {
    latestDeployment?.state ?? .map(currentRawStatus)
  }

  public var productionURL: URL? {
    guard let value = productionURLString,
      let url = URL(string: value),
      url.scheme == "https",
      let host = url.host,
      !host.isEmpty
    else { return nil }
    return url
  }

  public func matchesSearch(_ query: String) -> Bool {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return true }
    let deployment = latestDeployment
    let regionValues = regions.flatMap { [$0.name, $0.location] }.compactMap { $0 }
    let values = [
      name, id, currentRawStatus, state.title, productionURLString,
      deployment?.rawStatus, deployment?.branch, deployment?.commitSHA,
      deployment?.commitMessage
    ].compactMap { $0 } + regionValues
    return values.contains { $0.lowercased().contains(normalized) }
  }

  func mergingDeploymentMetadata(_ deployment: RailwayDeployment?) -> RailwayService {
    guard let deployment else { return self }
    let baseline = latestDeployment
    guard baseline == nil || baseline?.id == deployment.id else { return self }
    return RailwayService(
      id: id,
      name: name,
      currentRawStatus: currentRawStatus,
      latestDeployment: RailwayDeployment(
        id: deployment.id,
        rawStatus: deployment.rawStatus ?? baseline?.rawStatus,
        createdAt: deployment.createdAt ?? baseline?.createdAt,
        branch: deployment.branch,
        commitSHA: deployment.commitSHA,
        commitMessage: deployment.commitMessage
      ),
      productionURLString: productionURLString,
      regions: regions,
      replicas: replicas
    )
  }

  public func retainingMissingDeploymentMetadata(from prior: RailwayService) -> RailwayService {
    guard let currentDeployment = latestDeployment,
      let priorDeployment = prior.latestDeployment,
      currentDeployment.id == priorDeployment.id
    else { return self }
    return RailwayService(
      id: id,
      name: name,
      currentRawStatus: currentRawStatus,
      latestDeployment: RailwayDeployment(
        id: currentDeployment.id,
        rawStatus: currentDeployment.rawStatus,
        createdAt: currentDeployment.createdAt,
        branch: currentDeployment.branch ?? priorDeployment.branch,
        commitSHA: currentDeployment.commitSHA ?? priorDeployment.commitSHA,
        commitMessage: currentDeployment.commitMessage ?? priorDeployment.commitMessage
      ),
      productionURLString: productionURLString,
      regions: regions,
      replicas: replicas
    )
  }
}

public struct RailwayProject: Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let workspace: RailwayWorkspace
  public let productionEnvironmentID: String?
  public let isArchived: Bool
  public let productionState: RailwayProductionState
  public let services: [RailwayService]

  public init(
    id: String,
    name: String,
    workspace: RailwayWorkspace,
    productionEnvironmentID: String?,
    isArchived: Bool = false,
    productionState: RailwayProductionState = .available,
    services: [RailwayService] = []
  ) {
    self.id = id
    self.name = name
    self.workspace = workspace
    self.productionEnvironmentID = productionEnvironmentID
    self.isArchived = isArchived
    self.productionState = productionState
    self.services = services
  }

  public var dashboardURL: URL? {
    guard Self.isSafeIdentifier(id) else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "railway.com"
    components.path = "/project/\(id)"
    if let productionEnvironmentID, Self.isSafeIdentifier(productionEnvironmentID) {
      components.queryItems = [URLQueryItem(name: "environmentId", value: productionEnvironmentID)]
    }
    return components.url
  }

  public func matchesProjectSearch(_ query: String) -> Bool {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return true }
    let productionLabel: String
    switch productionState {
    case .available: productionLabel = "production available"
    case .unavailable: productionLabel = "production unavailable"
    case .failed(let message): productionLabel = "production failed \(message)"
    }
    return [name, id, workspace.name, workspace.id, productionLabel, isArchived ? "archived" : nil]
      .compactMap { $0?.lowercased() }
      .contains { $0.contains(normalized) }
  }

  public func filtered(matching query: String) -> RailwayProject? {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return self }
    if matchesProjectSearch(normalized) { return self }
    let filteredServices = services.filter { $0.matchesSearch(normalized) }
    guard !filteredServices.isEmpty else { return nil }
    return RailwayProject(
      id: id,
      name: name,
      workspace: workspace,
      productionEnvironmentID: productionEnvironmentID,
      isArchived: isArchived,
      productionState: productionState,
      services: filteredServices
    )
  }

  public func retainingServices(_ services: [RailwayService]) -> RailwayProject {
    RailwayProject(
      id: id,
      name: name,
      workspace: workspace,
      productionEnvironmentID: productionEnvironmentID,
      isArchived: isArchived,
      productionState: productionState,
      services: services
    )
  }

  private static func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 128
      && value.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
      }
  }
}

public struct RailwayScopedFailure: Equatable, Sendable {
  public let projectID: String
  public let serviceID: String?
  public let message: String
  public let isRateLimited: Bool

  public init(projectID: String, serviceID: String? = nil, message: String, isRateLimited: Bool = false) {
    self.projectID = projectID
    self.serviceID = serviceID
    self.message = message
    self.isRateLimited = isRateLimited
  }
}

public struct RailwaySnapshotResult: Equatable, Sendable {
  public let projects: [RailwayProject]
  public let successfulProjectIDs: Set<String>
  public let failures: [RailwayScopedFailure]

  public init(
    projects: [RailwayProject],
    successfulProjectIDs: Set<String>,
    failures: [RailwayScopedFailure] = []
  ) {
    self.projects = projects
    self.successfulProjectIDs = successfulProjectIDs
    self.failures = failures
  }
}

public enum RailwayStatusBuilder {
  public static func sortedProjects(_ projects: [RailwayProject]) -> [RailwayProject] {
    projects
      .map { project in
        RailwayProject(
          id: project.id,
          name: project.name,
          workspace: project.workspace,
          productionEnvironmentID: project.productionEnvironmentID,
          isArchived: project.isArchived,
          productionState: project.productionState,
          services: sortedServices(project.services)
        )
      }
      .sorted { left, right in
        let leftRank = left.services.map(\.state.sortRank).min() ?? projectRank(left)
        let rightRank = right.services.map(\.state.sortRank).min() ?? projectRank(right)
        if leftRank != rightRank { return leftRank < rightRank }
        let workspaceComparison = left.workspace.name.localizedCaseInsensitiveCompare(right.workspace.name)
        if workspaceComparison != .orderedSame { return workspaceComparison == .orderedAscending }
        return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
      }
  }

  public static func sortedServices(_ services: [RailwayService]) -> [RailwayService] {
    services.sorted { left, right in
      if left.state.sortRank != right.state.sortRank { return left.state.sortRank < right.state.sortRank }
      return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
    }
  }

  private static func projectRank(_ project: RailwayProject) -> Int {
    switch project.productionState {
    case .failed: return 0
    case .unavailable: return 2
    case .available: return 3
    }
  }
}

public enum RailwayConnectionState: Equatable, Sendable {
  case checking
  case connected
  case missingCLI
  case unsupportedCLI(currentVersion: String)
  case authenticationRequired
  case rateLimited(message: String)
  case failed(message: String)
}
