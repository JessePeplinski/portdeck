import Foundation

public struct ConvexProductionTarget: Equatable, Sendable {
  public let teamSlug: String
  public let projectName: String
  public let projectSlug: String
  public let deploymentName: String
  public let lastDeployTime: Date?

  public init(
    teamSlug: String,
    projectName: String,
    projectSlug: String,
    deploymentName: String,
    lastDeployTime: Date?
  ) {
    self.teamSlug = teamSlug
    self.projectName = projectName
    self.projectSlug = projectSlug
    self.deploymentName = deploymentName
    self.lastDeployTime = lastDeployTime
  }

  public var deploymentReference: String {
    "\(teamSlug):\(projectSlug):prod"
  }

  public var dashboardURLString: String {
    "https://dashboard.convex.dev/d/\(deploymentName)?view=insights"
  }
}

public protocol ConvexProductionTargetResolving: Sendable {
  func resolveProductionTarget(for candidate: ConvexProjectCandidate) async throws -> ConvexProductionTarget
}

public protocol ConvexHTTPDataLoading: Sendable {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionConvexHTTPDataLoader: ConvexHTTPDataLoading, @unchecked Sendable {
  public init() {}

  public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw ConvexCLIError.invalidResponse("Convex returned a non-HTTP response.")
    }
    return (data, response)
  }
}

public actor ConvexManagementAPIProductionTargetResolver: ConvexProductionTargetResolving {
  private let configURL: URL
  private let loader: any ConvexHTTPDataLoading
  private var cachedTargets: [ConvexProductionTarget]?

  public init(
    configURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".convex/config.json"),
    loader: any ConvexHTTPDataLoading = URLSessionConvexHTTPDataLoader()
  ) {
    self.configURL = configURL
    self.loader = loader
  }

  public func resolveProductionTarget(for candidate: ConvexProjectCandidate) async throws -> ConvexProductionTarget {
    let targets: [ConvexProductionTarget]
    if let cachedTargets {
      targets = cachedTargets
    } else {
      targets = try await fetchProductionTargets()
      cachedTargets = targets
    }

    let matches = targets.filter { target in
      ConvexProductionTargetMatcher.matches(candidate: candidate, target: target)
    }
    guard matches.count == 1, let match = matches.first else {
      if matches.isEmpty {
        throw ConvexCLIError.unconfigured
      }
      throw ConvexCLIError.commandFailed("More than one Convex production project matches \(candidate.displayName).")
    }
    return match
  }

  private func fetchProductionTargets() async throws -> [ConvexProductionTarget] {
    let accessToken: String
    do {
      let config = try JSONDecoder().decode(ConvexUserConfig.self, from: Data(contentsOf: configURL))
      accessToken = config.accessToken
    } catch {
      throw ConvexCLIError.unauthenticated
    }

    let teams: [ConvexAPITeam] = try await get(
      URL(string: "https://api.convex.dev/api/teams")!,
      accessToken: accessToken
    )
    var targets: [ConvexProductionTarget] = []
    for team in teams {
      let projects: [ConvexAPIProject] = try await get(
        URL(string: "https://api.convex.dev/v1/teams/\(team.id)/list_projects")!,
        accessToken: accessToken
      )
      for project in projects {
        var components = URLComponents(
          string: "https://api.convex.dev/v1/projects/\(project.id)/list_deployments"
        )!
        components.queryItems = [
          URLQueryItem(name: "includeLocal", value: "false"),
          URLQueryItem(name: "isDefault", value: "true"),
          URLQueryItem(name: "deploymentType", value: "prod")
        ]
        let deployments: [ConvexAPIDeployment] = try await get(
          components.url!,
          accessToken: accessToken
        )
        for deployment in deployments where deployment.deploymentType == "prod" && deployment.isDefault {
          targets.append(ConvexProductionTarget(
            teamSlug: project.teamSlug,
            projectName: project.name,
            projectSlug: project.slug,
            deploymentName: deployment.name,
            lastDeployTime: deployment.lastDeployTime.map {
              Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
            }
          ))
        }
      }
    }
    return targets
  }

  private func get<Response: Decodable>(_ url: URL, accessToken: String) async throws -> Response {
    var request = URLRequest(url: url)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await loader.data(for: request)
    if response.statusCode == 401 || response.statusCode == 403 {
      throw ConvexCLIError.unauthenticated
    }
    guard (200..<300).contains(response.statusCode) else {
      throw ConvexCLIError.commandFailed("Convex Management API request failed with HTTP \(response.statusCode).")
    }
    do {
      return try JSONDecoder().decode(Response.self, from: data)
    } catch {
      throw ConvexCLIError.invalidResponse(error.localizedDescription)
    }
  }
}

public enum ConvexProductionTargetMatcher {
  public static func matches(candidate: ConvexProjectCandidate, target: ConvexProductionTarget) -> Bool {
    let candidateNames = [candidate.projectName, candidate.packageName, URL(fileURLWithPath: candidate.packagePath).lastPathComponent]
      .compactMap { $0 }
      .flatMap(normalizedVariants)
    let targetNames = Set(normalizedVariants(target.projectName) + normalizedVariants(target.projectSlug))
    return candidateNames.contains { targetNames.contains($0) }
  }

  private static func normalizedVariants(_ value: String) -> [String] {
    let normalized = value.lowercased().filter { $0.isLetter || $0.isNumber }
    let withoutCommonTLD: String
    if value.lowercased().hasSuffix(".com") {
      withoutCommonTLD = String(value.dropLast(4)).lowercased().filter { $0.isLetter || $0.isNumber }
    } else {
      withoutCommonTLD = normalized
    }
    return Array(Set([normalized, withoutCommonTLD])).filter { !$0.isEmpty }
  }
}

private struct ConvexUserConfig: Decodable {
  let accessToken: String
}

private struct ConvexAPITeam: Decodable {
  let id: Int64
}

private struct ConvexAPIProject: Decodable {
  let id: Int64
  let name: String
  let slug: String
  let teamSlug: String
}

private struct ConvexAPIDeployment: Decodable {
  let name: String
  let deploymentType: String
  let isDefault: Bool
  let lastDeployTime: Int64?
}
