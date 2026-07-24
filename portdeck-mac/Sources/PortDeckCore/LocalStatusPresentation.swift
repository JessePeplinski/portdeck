import Foundation

public enum LocalStatusTone: Int, Comparable, Sendable {
  case critical
  case warning
  case positive
  case neutral

  public static func < (lhs: LocalStatusTone, rhs: LocalStatusTone) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public struct LocalServicePresentation: Equatable, Sendable {
  public let label: String
  public let detail: String?
  public let tone: LocalStatusTone

  public init(label: String, detail: String?, tone: LocalStatusTone) {
    self.label = label
    self.detail = detail
    self.tone = tone
  }

  public var needsAttention: Bool {
    tone == .critical || tone == .warning
  }
}

public struct LocalStatusOverview: Equatable, Sendable {
  public let projectCount: Int
  public let serviceCount: Int
  public let problemCount: Int
  public let hiddenSystemServiceCount: Int

  public init(projectCount: Int, serviceCount: Int, problemCount: Int, hiddenSystemServiceCount: Int) {
    self.projectCount = projectCount
    self.serviceCount = serviceCount
    self.problemCount = problemCount
    self.hiddenSystemServiceCount = hiddenSystemServiceCount
  }
}

public struct LocalProjectSummary: Equatable, Sendable {
  public let serviceCount: Int
  public let problemServiceCount: Int

  public init(serviceCount: Int, problemServiceCount: Int) {
    self.serviceCount = serviceCount
    self.problemServiceCount = problemServiceCount
  }

  public var problemLabel: String? {
    guard problemServiceCount > 0 else { return nil }
    return "\(problemServiceCount) need attention"
  }
}

public struct LocalMetadataItem: Equatable, Sendable {
  public let text: String
  public let systemImage: String

  public init(text: String, systemImage: String) {
    self.text = text
    self.systemImage = systemImage
  }
}

public struct LocalProblem: Identifiable, Equatable, Sendable {
  public let id: String
  public let tone: LocalStatusTone
  public let stateLabel: String
  public let title: String
  public let message: String
  public let details: [String]

  public init(
    id: String,
    tone: LocalStatusTone,
    stateLabel: String,
    title: String,
    message: String,
    details: [String] = []
  ) {
    self.id = id
    self.tone = tone
    self.stateLabel = stateLabel
    self.title = title
    self.message = message
    self.details = details
  }
}

public enum LocalStatusPresentation {
  public static func service(_ service: PortdeckService) -> LocalServicePresentation {
    let healthDetail = service.endpointHealthSummary
    let collisionDetail = service.localhostCollisionSummary
    let details = [healthDetail, collisionDetail].compactMap { $0 }
    let detail = details.isEmpty ? nil : details.joined(separator: " · ")

    switch service.endpointHealthSeverity {
    case .error:
      return LocalServicePresentation(label: "Endpoint error", detail: detail, tone: .critical)
    case .warning:
      return LocalServicePresentation(label: "Health warning", detail: detail, tone: .warning)
    case .ok where service.localhostCollision != nil:
      return LocalServicePresentation(label: "Port conflict", detail: detail, tone: .warning)
    case .ok:
      return LocalServicePresentation(label: "Healthy", detail: nil, tone: .positive)
    case .unknown where service.localhostCollision != nil:
      return LocalServicePresentation(label: "Port conflict", detail: collisionDetail, tone: .warning)
    case .unknown:
      let normalizedStatus = service.status.trimmingCharacters(in: .whitespacesAndNewlines)
      let label = normalizedStatus.isEmpty ? "Status unknown" : normalizedStatus.capitalized
      return LocalServicePresentation(label: label, detail: nil, tone: .neutral)
    }
  }

  public static func visibleServiceStateLabel(
    _ presentation: LocalServicePresentation,
    isStopping: Bool
  ) -> String? {
    if isStopping {
      return "Stopping…"
    }

    switch presentation.label.lowercased() {
    case "running", "healthy":
      return nil
    default:
      return presentation.label
    }
  }

  public static func overview(
    for status: PortdeckStatus,
    showLikelySystemListeners: Bool
  ) -> LocalStatusOverview {
    let groupedServices = status.groups.flatMap(\.worktrees).flatMap(\.services)
    let hiddenSystemServices = showLikelySystemListeners
      ? []
      : status.unknown.filter { $0.unknownServiceCategory == .likelySystem }
    let shownUnknownServices = status.unknown.count - hiddenSystemServices.count
    let conflictServiceIDs = Set(
      (status.portConflicts ?? []).flatMap(\.endpoints).compactMap(\.serviceId)
    )
    let unrepresentedServiceProblems = (groupedServices + status.unknown).filter { service in
      LocalStatusPresentation.service(service).needsAttention
        && !conflictServiceIDs.contains(service.id)
    }.count

    return LocalStatusOverview(
      projectCount: status.groups.filter { !$0.worktrees.flatMap(\.services).isEmpty }.count,
      serviceCount: groupedServices.count + shownUnknownServices,
      problemCount: problems(in: status, matching: "").count + unrepresentedServiceProblems,
      hiddenSystemServiceCount: hiddenSystemServices.count
    )
  }

  public static func projectSummary(_ project: ProjectGroup) -> LocalProjectSummary {
    let services = project.worktrees.flatMap(\.services)
    return LocalProjectSummary(
      serviceCount: services.count,
      problemServiceCount: services.filter { service($0).needsAttention }.count
    )
  }

  public static func worktreeMetadata(
    _ worktree: WorktreeGroup,
    projectName: String,
    repoRoot: String?,
    projectWorktreeCount: Int
  ) -> [LocalMetadataItem] {
    var items: [LocalMetadataItem] = []
    let normalizedProjectName = normalized(projectName)

    if let branch = nonEmpty(worktree.branch), normalized(branch) != normalizedProjectName {
      items.append(LocalMetadataItem(text: branch, systemImage: "arrow.triangle.branch"))
    }

    let isPrimaryPath = samePath(worktree.path, repoRoot)
    if projectWorktreeCount > 1 || !isPrimaryPath {
      let pathName = worktree.path.map { URL(fileURLWithPath: $0).lastPathComponent }
      let candidate = [worktree.name, pathName]
        .compactMap(nonEmpty)
        .first { normalized($0) != normalizedProjectName && normalized($0) != normalized(worktree.branch ?? "") }
      if let candidate {
        items.append(LocalMetadataItem(text: candidate, systemImage: "point.3.connected.trianglepath.dotted"))
      }
    }

    let contexts = worktree.services.compactMap(\.subcontext).filter {
      $0.relativePath.trimmingCharacters(in: .whitespacesAndNewlines) != "."
    }
    let uniquePaths = Set(contexts.map(\.path))
    if uniquePaths.count > 1 {
      items.append(LocalMetadataItem(text: "\(uniquePaths.count) packages", systemImage: "shippingbox"))
    } else if let context = contexts.first {
      let excluded = Set([
        normalizedProjectName,
        normalized(worktree.name),
        normalized(worktree.branch ?? "")
      ])
      if let package = [context.displayName, context.name, context.relativePath]
        .compactMap(nonEmpty)
        .first(where: { !excluded.contains(normalized($0)) })
      {
        items.append(LocalMetadataItem(text: package, systemImage: "shippingbox"))
      }
    }

    return uniqueMetadata(items)
  }

  public static func problems(in status: PortdeckStatus, matching query: String) -> [LocalProblem] {
    var ordered: [(offset: Int, problem: LocalProblem)] = []
    var offset = 0

    for conflict in status.portConflicts ?? [] where conflict.matchesSearch(query) {
      ordered.append((offset, LocalProblem(
        id: "port-conflict-\(conflict.port)-\(conflict.title)",
        tone: conflict.severity == "error" ? .critical : .warning,
        stateLabel: conflict.severity == "error" ? "Conflict" : "Warning",
        title: conflict.title,
        message: conflict.displayMessage,
        details: conflict.summaryLines
      )))
      offset += 1
    }

    for exposure in status.danglingExposures where exposure.matchesSearch(query) {
      ordered.append((offset, LocalProblem(
        id: "exposure-\(exposure.id)",
        tone: .warning,
        stateLabel: "Target down",
        title: exposure.danglingDisplayText,
        message: exposure.publicUrl,
        details: [exposure.targetUrl]
      )))
      offset += 1
    }

    for warning in filteredWarnings(in: status, matching: query) {
      ordered.append((offset, LocalProblem(
        id: "warning-\(warning)",
        tone: .warning,
        stateLabel: "Warning",
        title: "Local runtime warning",
        message: warning
      )))
      offset += 1
    }

    return ordered.sorted {
      if $0.problem.tone != $1.problem.tone { return $0.problem.tone < $1.problem.tone }
      return $0.offset < $1.offset
    }.map(\.problem)
  }

  public static func stabilized(
    _ incoming: PortdeckStatus,
    preserving previous: PortdeckStatus?
  ) -> PortdeckStatus {
    guard let previous else { return incoming }

    let groups = stableOrder(incoming.groups, previous: previous.groups, id: \.id).map { group in
      let previousGroup = previous.groups.first { $0.id == group.id }
      let worktrees = stableOrder(
        group.worktrees,
        previous: previousGroup?.worktrees ?? [],
        id: \.id
      ).map { worktree in
        let previousWorktree = previousGroup?.worktrees.first { $0.id == worktree.id }
        let services = stableOrder(
          worktree.services,
          previous: previousWorktree?.services ?? [],
          id: \.id
        )
        return WorktreeGroup(
          name: worktree.name,
          path: worktree.path,
          branch: worktree.branch,
          remoteUrl: worktree.remoteUrl,
          repositoryUrl: worktree.repositoryUrl,
          services: services
        )
      }
      return ProjectGroup(
        projectName: group.projectName,
        repoRoot: group.repoRoot,
        remoteUrl: group.remoteUrl,
        repositoryUrl: group.repositoryUrl,
        worktrees: worktrees
      )
    }

    return PortdeckStatus(
      schemaVersion: incoming.schemaVersion,
      generatedAt: incoming.generatedAt,
      groups: groups,
      unknown: stableOrder(incoming.unknown, previous: previous.unknown, id: \.id),
      warnings: incoming.warnings,
      portConflicts: incoming.portConflicts,
      exposures: incoming.exposures
    )
  }

  private static func filteredWarnings(in status: PortdeckStatus, matching query: String) -> [String] {
    let conflictPorts = Set((status.portConflicts ?? []).map(\.port))
    let warnings = status.warnings.filter { warning in
      !conflictPorts.contains { port in
        warning.contains("Port \(port) conflict") || warning.contains("localhost:\(port) is ambiguous")
      }
    }
    let normalizedQuery = normalized(query)
    guard !normalizedQuery.isEmpty else { return warnings }
    return warnings.filter { normalized($0).contains(normalizedQuery) }
  }
}

public extension PortConflict {
  func matchesSearch(_ query: String) -> Bool {
    let normalizedQuery = normalized(query)
    guard !normalizedQuery.isEmpty else { return true }

    let endpointTokens: [String?] = endpoints.flatMap { endpoint in
      [
        endpoint.url,
        endpoint.serviceId,
        endpoint.name,
        endpoint.projectName,
        endpoint.worktreeName,
        endpoint.address,
        endpoint.endpointDisplayLabel,
        endpoint.summaryLine,
        endpoint.health?.url,
        endpoint.health?.status,
        endpoint.health?.statusCode.map(String.init),
        endpoint.health?.remoteAddress,
        endpoint.health?.latencyMs.map(String.init),
        endpoint.health?.error
      ]
    }
    let tokens: [String?] = [
      String(port),
      severity,
      title,
      message,
      displayMessage
    ] + endpointTokens

    return tokens.compactMap { $0 }.contains { normalized($0).contains(normalizedQuery) }
  }
}

public func localPollingAgeSeconds(lastUpdated: Date, relativeTo now: Date) -> Int {
  max(0, Int(now.timeIntervalSince(lastUpdated)))
}

public func localLastCheckedLabel(ageSeconds: Int) -> String {
  "Checked \(max(0, ageSeconds))s ago"
}

public func localSectionIsExpanded(searchText: String, isCollapsed: Bool) -> Bool {
  !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isCollapsed
}

public func localOpenServiceAccessibilityLabel(serviceName: String, destination: String) -> String {
  "Open \(serviceName) at \(destination)"
}

public func localStopServiceAccessibilityLabel(serviceName: String) -> String {
  "Stop \(serviceName)"
}

public func localServiceRowAccessibilityLabel(
  serviceName: String,
  source: String,
  state: String
) -> String {
  "\(serviceName), \(source) service, \(state)"
}

public func localProjectDisclosureAccessibilityLabel(projectName: String, isExpanded: Bool) -> String {
  "\(isExpanded ? "Collapse" : "Expand") \(projectName) project"
}

public func localProjectActionsAccessibilityLabel(projectName: String) -> String {
  "Open \(projectName) project actions"
}

public func localWorktreeActionsAccessibilityLabel(worktreeName: String) -> String {
  "Open \(worktreeName) worktree actions"
}

private func stableOrder<Element, ID: Hashable>(
  _ incoming: [Element],
  previous: [Element],
  id: KeyPath<Element, ID>
) -> [Element] {
  let incomingByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0[keyPath: id], $0) })
  let previousIDs = previous.map { $0[keyPath: id] }
  let previousIDSet = Set(previousIDs)
  let retained = previousIDs.compactMap { incomingByID[$0] }
  let appended = incoming.filter { !previousIDSet.contains($0[keyPath: id]) }
  return retained + appended
}

private func uniqueMetadata(_ items: [LocalMetadataItem]) -> [LocalMetadataItem] {
  var seen = Set<String>()
  return items.filter { seen.insert(normalized($0.text)).inserted }
}

private func nonEmpty(_ value: String?) -> String? {
  guard let value else { return nil }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

private func normalized(_ value: String) -> String {
  value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func samePath(_ lhs: String?, _ rhs: String?) -> Bool {
  guard let lhs, let rhs else { return false }
  return URL(fileURLWithPath: lhs).standardizedFileURL.path
    == URL(fileURLWithPath: rhs).standardizedFileURL.path
}
