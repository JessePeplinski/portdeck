import Foundation

public enum ConvexHealthState: String, Equatable, Sendable {
  case healthy
  case warning
  case error
  case unavailable

  public var title: String {
    switch self {
    case .healthy:
      return "Healthy"
    case .warning:
      return "Warnings"
    case .error:
      return "Errors"
    case .unavailable:
      return "Health unavailable"
    }
  }
}

public enum ConvexProjectAvailability: Equatable, Sendable {
  case ready
  case missingCLI
  case unsupportedCLI
  case unauthenticated
  case unconfigured
  case unavailable
}

public struct ConvexProjectCandidate: Identifiable, Equatable, Sendable {
  public let id: String
  public let projectName: String
  public let packageName: String?
  public let packagePath: String

  public init(projectName: String, packageName: String?, packagePath: String) {
    id = "convex|\(packagePath)"
    self.projectName = projectName
    self.packageName = packageName
    self.packagePath = packagePath
  }

  public var displayName: String {
    guard let packageName, packageName != projectName else {
      return projectName
    }
    return "\(projectName) / \(packageName)"
  }
}

public struct ConvexInsight: Decodable, Equatable, Sendable {
  public let kind: String
  public let severity: String
  public let functionId: String
  public let componentPath: String?
  public let occCalls: Int?
  public let count: Int?

  public init(
    kind: String,
    severity: String,
    functionId: String,
    componentPath: String?,
    occCalls: Int?,
    count: Int?
  ) {
    self.kind = kind
    self.severity = severity
    self.functionId = functionId
    self.componentPath = componentPath
    self.occCalls = occCalls
    self.count = count
  }

  public var qualifiedFunctionName: String {
    guard let componentPath, !componentPath.isEmpty else {
      return functionId
    }
    return "\(componentPath):\(functionId)"
  }
}

public struct ConvexInsightsResponse: Decodable, Equatable, Sendable {
  public let deploymentName: String
  public let dashboardUrl: String
  public let insights: [ConvexInsight]

  public init(deploymentName: String, dashboardUrl: String, insights: [ConvexInsight]) {
    self.deploymentName = deploymentName
    self.dashboardUrl = dashboardUrl
    self.insights = insights
  }
}

public struct ConvexProjectStatus: Identifiable, Equatable, Sendable {
  public let candidate: ConvexProjectCandidate
  public let deploymentName: String?
  public let dashboardURLString: String?
  public let insights: [ConvexInsight]
  public let healthState: ConvexHealthState
  public let availability: ConvexProjectAvailability
  public let productionLastDeployTime: Date?
  public let lastChecked: Date?
  public let message: String?

  public var id: String { candidate.id }
  public var projectName: String { candidate.projectName }
  public var packagePath: String { candidate.packagePath }
  public var displayName: String { candidate.displayName }
  public var dashboardURL: URL? { dashboardURLString.flatMap(URL.init(string:)) }

  public var errorCount: Int {
    insights.count { $0.severity.lowercased() == "error" }
  }

  public var warningCount: Int {
    insights.count { $0.severity.lowercased() == "warning" }
  }

  public init(
    candidate: ConvexProjectCandidate,
    deploymentName: String?,
    dashboardURLString: String?,
    insights: [ConvexInsight],
    healthState: ConvexHealthState,
    availability: ConvexProjectAvailability,
    productionLastDeployTime: Date?,
    lastChecked: Date?,
    message: String?
  ) {
    self.candidate = candidate
    self.deploymentName = deploymentName
    self.dashboardURLString = dashboardURLString
    self.insights = insights
    self.healthState = healthState
    self.availability = availability
    self.productionLastDeployTime = productionLastDeployTime
    self.lastChecked = lastChecked
    self.message = message
  }

  public func matchesSearch(_ query: String) -> Bool {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else {
      return true
    }

    let insightTokens = insights.flatMap { insight in
      [insight.kind, insight.severity, insight.qualifiedFunctionName]
    }
    return ([displayName, packagePath, deploymentName, healthState.title, message]
      .compactMap { $0 } + insightTokens)
      .contains { $0.lowercased().contains(normalized) }
  }

  public func preservingHealth(with target: ConvexProductionTarget, message: String) -> ConvexProjectStatus {
    ConvexProjectStatus(
      candidate: candidate,
      deploymentName: target.deploymentName,
      dashboardURLString: target.dashboardURLString,
      insights: insights,
      healthState: healthState,
      availability: availability,
      productionLastDeployTime: target.lastDeployTime,
      lastChecked: lastChecked,
      message: message
    )
  }

  public func preservingMetadata(with message: String) -> ConvexProjectStatus {
    ConvexProjectStatus(
      candidate: candidate,
      deploymentName: deploymentName,
      dashboardURLString: dashboardURLString,
      insights: insights,
      healthState: healthState,
      availability: availability,
      productionLastDeployTime: productionLastDeployTime,
      lastChecked: lastChecked,
      message: message
    )
  }
}

public enum ConvexProjectStatusBuilder {
  public static func build(
    candidate: ConvexProjectCandidate,
    target: ConvexProductionTarget,
    response: ConvexInsightsResponse,
    checkedAt: Date
  ) -> ConvexProjectStatus {
    let errorCount = response.insights.count { $0.severity.lowercased() == "error" }
    let warningCount = response.insights.count { $0.severity.lowercased() == "warning" }
    let hasUnknownSeverity = response.insights.contains {
      !["error", "warning"].contains($0.severity.lowercased())
    }
    let healthState: ConvexHealthState
    if errorCount > 0 {
      healthState = .error
    } else if warningCount > 0 {
      healthState = .warning
    } else if hasUnknownSeverity {
      healthState = .unavailable
    } else {
      healthState = .healthy
    }

    return ConvexProjectStatus(
      candidate: candidate,
      deploymentName: target.deploymentName,
      dashboardURLString: normalizedHTTPSURLString(response.dashboardUrl) ?? target.dashboardURLString,
      insights: response.insights,
      healthState: healthState,
      availability: .ready,
      productionLastDeployTime: target.lastDeployTime,
      lastChecked: checkedAt,
      message: hasUnknownSeverity ? "Convex returned an insight severity this PortDeck version does not recognize." : nil
    )
  }

  public static func unavailable(
    candidate: ConvexProjectCandidate,
    availability: ConvexProjectAvailability,
    message: String
  ) -> ConvexProjectStatus {
    ConvexProjectStatus(
      candidate: candidate,
      deploymentName: nil,
      dashboardURLString: nil,
      insights: [],
      healthState: .unavailable,
      availability: availability,
      productionLastDeployTime: nil,
      lastChecked: nil,
      message: message
    )
  }

  public static func healthUnavailable(
    candidate: ConvexProjectCandidate,
    target: ConvexProductionTarget,
    availability: ConvexProjectAvailability = .unavailable,
    message: String
  ) -> ConvexProjectStatus {
    ConvexProjectStatus(
      candidate: candidate,
      deploymentName: target.deploymentName,
      dashboardURLString: target.dashboardURLString,
      insights: [],
      healthState: .unavailable,
      availability: availability,
      productionLastDeployTime: target.lastDeployTime,
      lastChecked: nil,
      message: message
    )
  }

  public static func sorted(_ projects: [ConvexProjectStatus]) -> [ConvexProjectStatus] {
    projects.sorted { left, right in
      let leftRank = healthRank(left.healthState)
      let rightRank = healthRank(right.healthState)
      if leftRank != rightRank {
        return leftRank < rightRank
      }
      return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
    }
  }

  private static func healthRank(_ state: ConvexHealthState) -> Int {
    switch state {
    case .error: return 0
    case .warning: return 1
    case .healthy: return 2
    case .unavailable: return 3
    }
  }

  private static func normalizedHTTPSURLString(_ rawValue: String) -> String? {
    guard let components = URLComponents(string: rawValue),
      components.scheme == "https",
      components.host?.isEmpty == false
    else {
      return nil
    }
    return components.url?.absoluteString
  }
}
