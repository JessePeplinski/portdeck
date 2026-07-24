import Foundation

public struct PortdeckStatus: Decodable, Sendable {
  public let schemaVersion: String
  public let generatedAt: String
  public let groups: [ProjectGroup]
  public let unknown: [PortdeckService]
  public let warnings: [String]
  public let portConflicts: [PortConflict]?
  public let exposures: [PortdeckExposure]?

  public init(
    schemaVersion: String,
    generatedAt: String,
    groups: [ProjectGroup],
    unknown: [PortdeckService],
    warnings: [String],
    portConflicts: [PortConflict]? = nil,
    exposures: [PortdeckExposure]? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.groups = groups
    self.unknown = unknown
    self.warnings = warnings
    self.portConflicts = portConflicts
    self.exposures = exposures
  }
}

public struct ProjectGroup: Decodable, Identifiable, Sendable {
  public var id: String { repoRoot ?? projectName }

  public let projectName: String
  public let repoRoot: String?
  public let remoteUrl: String?
  public let repositoryUrl: String?
  public let worktrees: [WorktreeGroup]

  public init(
    projectName: String,
    repoRoot: String?,
    remoteUrl: String? = nil,
    repositoryUrl: String? = nil,
    worktrees: [WorktreeGroup]
  ) {
    self.projectName = projectName
    self.repoRoot = repoRoot
    self.remoteUrl = remoteUrl
    self.repositoryUrl = repositoryUrl
    self.worktrees = worktrees
  }
}

public struct WorktreeGroup: Decodable, Identifiable, Sendable {
  public var id: String { [path, branch, name].compactMap { $0 }.joined(separator: "|") }

  public let name: String
  public let path: String?
  public let branch: String?
  public let remoteUrl: String?
  public let repositoryUrl: String?
  public let services: [PortdeckService]

  public init(
    name: String,
    path: String?,
    branch: String?,
    remoteUrl: String? = nil,
    repositoryUrl: String? = nil,
    services: [PortdeckService]
  ) {
    self.name = name
    self.path = path
    self.branch = branch
    self.remoteUrl = remoteUrl
    self.repositoryUrl = repositoryUrl
    self.services = services
  }
}

public struct PortdeckService: Decodable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let source: String
  public let status: String
  public let port: Int?
  public let url: String?
  public let address: String?
  public let protocolName: String?
  public let listeners: [ServiceListener]?
  public let localhostCollision: LocalhostCollision?
  public let endpointHealth: EndpointHealth?
  public let exposures: [PortdeckExposure]?
  public let pid: Int?
  public let processName: String?
  public let command: String?
  public let cwd: String?
  public let hostIp: String?
  public let containerName: String?
  public let containerId: String?
  public let containerPort: Int?
  public let image: String?
  public let activity: ServiceActivity?
  public let confidence: String
  public let subcontext: ServiceSubcontext?
  public let groupingReason: String?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case source
    case status
    case port
    case url
    case address
    case protocolName = "protocol"
    case listeners
    case localhostCollision
    case endpointHealth
    case exposures
    case pid
    case processName
    case command
    case cwd
    case hostIp
    case containerName
    case containerId
    case containerPort
    case image
    case activity
    case confidence
    case subcontext
    case groupingReason
  }

  public init(
    id: String,
    name: String,
    source: String,
    status: String,
    port: Int?,
    url: String?,
    address: String?,
    protocolName: String?,
    listeners: [ServiceListener]? = nil,
    localhostCollision: LocalhostCollision? = nil,
    endpointHealth: EndpointHealth? = nil,
    exposures: [PortdeckExposure]? = nil,
    pid: Int?,
    processName: String?,
    command: String?,
    cwd: String?,
    hostIp: String?,
    containerName: String?,
    containerId: String?,
    containerPort: Int?,
    image: String?,
    activity: ServiceActivity? = nil,
    confidence: String,
    subcontext: ServiceSubcontext? = nil,
    groupingReason: String? = nil
  ) {
    self.id = id
    self.name = name
    self.source = source
    self.status = status
    self.port = port
    self.url = url
    self.address = address
    self.protocolName = protocolName
    self.listeners = listeners
    self.localhostCollision = localhostCollision
    self.endpointHealth = endpointHealth
    self.exposures = exposures
    self.pid = pid
    self.processName = processName
    self.command = command
    self.cwd = cwd
    self.hostIp = hostIp
    self.containerName = containerName
    self.containerId = containerId
    self.containerPort = containerPort
    self.image = image
    self.activity = activity
    self.confidence = confidence
    self.subcontext = subcontext
    self.groupingReason = groupingReason
  }
}

public struct ServiceActivity: Decodable, Equatable, Sendable {
  public let cpuPercent: Double?
  public let memoryRssBytes: Int?
  public let memoryUsageBytes: Int?
  public let memoryLimitBytes: Int?

  public init(cpuPercent: Double?, memoryRssBytes: Int?, memoryUsageBytes: Int?, memoryLimitBytes: Int?) {
    self.cpuPercent = cpuPercent
    self.memoryRssBytes = memoryRssBytes
    self.memoryUsageBytes = memoryUsageBytes
    self.memoryLimitBytes = memoryLimitBytes
  }
}

public struct EndpointHealth: Decodable, Equatable, Sendable {
  public let url: String
  public let status: String
  public let statusCode: Int?
  public let remoteAddress: String?
  public let latencyMs: Int?
  public let error: String?

  public init(
    url: String,
    status: String,
    statusCode: Int?,
    remoteAddress: String?,
    latencyMs: Int?,
    error: String?
  ) {
    self.url = url
    self.status = status
    self.statusCode = statusCode
    self.remoteAddress = remoteAddress
    self.latencyMs = latencyMs
    self.error = error
  }
}

public struct PortConflict: Decodable, Equatable, Sendable {
  public let port: Int
  public let severity: String
  public let title: String
  public let message: String
  public let endpoints: [PortConflictEndpoint]

  public init(port: Int, severity: String, title: String, message: String, endpoints: [PortConflictEndpoint]) {
    self.port = port
    self.severity = severity
    self.title = title
    self.message = message
    self.endpoints = endpoints
  }
}

public struct PortConflictEndpoint: Decodable, Equatable, Sendable {
  public let url: String
  public let serviceId: String?
  public let name: String?
  public let projectName: String?
  public let worktreeName: String?
  public let address: String?
  public let health: EndpointHealth?

  public init(
    url: String,
    serviceId: String?,
    name: String?,
    projectName: String?,
    worktreeName: String?,
    address: String?,
    health: EndpointHealth?
  ) {
    self.url = url
    self.serviceId = serviceId
    self.name = name
    self.projectName = projectName
    self.worktreeName = worktreeName
    self.address = address
    self.health = health
  }
}

public struct PortdeckExposure: Decodable, Equatable, Identifiable, Sendable {
  public let id: String
  public let kind: String
  public let publicUrl: String
  public let targetUrl: String
  public let targetHost: String?
  public let targetPort: Int?
  public let agentApiUrl: String
  public let agentPid: Int?
  public let agentCwd: String?
  public let status: String
  public let attachedServiceId: String?

  public init(
    id: String,
    kind: String,
    publicUrl: String,
    targetUrl: String,
    targetHost: String?,
    targetPort: Int?,
    agentApiUrl: String,
    agentPid: Int?,
    agentCwd: String?,
    status: String,
    attachedServiceId: String?
  ) {
    self.id = id
    self.kind = kind
    self.publicUrl = publicUrl
    self.targetUrl = targetUrl
    self.targetHost = targetHost
    self.targetPort = targetPort
    self.agentApiUrl = agentApiUrl
    self.agentPid = agentPid
    self.agentCwd = agentCwd
    self.status = status
    self.attachedServiceId = attachedServiceId
  }
}

public enum EndpointHealthSeverity: Equatable, Sendable {
  case ok
  case warning
  case error
  case unknown
}

public enum PortdeckDashboardSource: String, CaseIterable, Hashable, Identifiable, Sendable {
  case local
  case vercel
  case convex
  case github
  case supabase
  case cloudflare
  case railway
  case fly
  case netlify

  public var id: String { rawValue }
}

public enum PortdeckUnknownServiceCategory: String, CaseIterable, Identifiable, Sendable {
  case unattached
  case needsAttribution
  case likelySystem

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .unattached:
      return "Unattached services"
    case .needsAttribution:
      return "Needs attribution"
    case .likelySystem:
      return "Likely system listeners"
    }
  }

  public var detail: String {
    switch self {
    case .unattached:
      return "Running locally, but not attached to a known project."
    case .needsAttribution:
      return "PortDeck found these, but cannot confidently attach them to one project."
    case .likelySystem:
      return "macOS background listeners hidden from the main view by default."
    }
  }

  public var systemImage: String {
    switch self {
    case .unattached:
      return "link.badge.plus"
    case .needsAttribution:
      return "questionmark.folder"
    case .likelySystem:
      return "desktopcomputer"
    }
  }
}

public struct PortdeckUnknownServiceSection: Identifiable, Sendable {
  public var id: String { category.id }

  public let category: PortdeckUnknownServiceCategory
  public let services: [PortdeckService]

  public init(category: PortdeckUnknownServiceCategory, services: [PortdeckService]) {
    self.category = category
    self.services = services
  }
}

public struct ServiceListener: Decodable, Equatable, Sendable {
  public let address: String
  public let family: String?
  public let port: Int
  public let url: String
  public let isWildcard: Bool
  public let isLoopback: Bool
  public let isPreferred: Bool

  public init(
    address: String,
    family: String?,
    port: Int,
    url: String,
    isWildcard: Bool,
    isLoopback: Bool,
    isPreferred: Bool
  ) {
    self.address = address
    self.family = family
    self.port = port
    self.url = url
    self.isWildcard = isWildcard
    self.isLoopback = isLoopback
    self.isPreferred = isPreferred
  }
}

public struct LocalhostCollision: Decodable, Equatable, Sendable {
  public let port: Int
  public let localhostUrl: String
  public let message: String
  public let conflictsWith: [LocalhostCollisionPeer]

  public init(port: Int, localhostUrl: String, message: String, conflictsWith: [LocalhostCollisionPeer]) {
    self.port = port
    self.localhostUrl = localhostUrl
    self.message = message
    self.conflictsWith = conflictsWith
  }
}

public struct LocalhostCollisionPeer: Decodable, Equatable, Sendable {
  public let serviceId: String
  public let name: String
  public let projectName: String?
  public let worktreeName: String?
  public let url: String?
  public let address: String?

  public init(
    serviceId: String,
    name: String,
    projectName: String?,
    worktreeName: String?,
    url: String?,
    address: String?
  ) {
    self.serviceId = serviceId
    self.name = name
    self.projectName = projectName
    self.worktreeName = worktreeName
    self.url = url
    self.address = address
  }
}

public struct PortdeckStopResult: Decodable, Equatable, Sendable {
  public let ok: Bool
  public let serviceId: String
  public let action: String
  public let message: String

  public init(ok: Bool, serviceId: String, action: String, message: String) {
    self.ok = ok
    self.serviceId = serviceId
    self.action = action
    self.message = message
  }
}

public struct ProjectStopAllTarget: Sendable {
  public let projectID: String
  public let projectName: String
  public let services: [PortdeckService]

  public init(projectID: String, projectName: String, services: [PortdeckService]) {
    self.projectID = projectID
    self.projectName = projectName
    self.services = services
  }

  public var serviceIDs: [String] {
    services.map(\.id)
  }

  public var stoppableCount: Int {
    services.count
  }

  public var confirmationTitle: String {
    "Stop \(stoppableCount) \(stoppableCount == 1 ? "service" : "services") in \(projectName)?"
  }

  public func containsService(_ service: PortdeckService) -> Bool {
    serviceIDs.contains(service.id)
  }
}

public struct PortdeckStopBatchSummary: Sendable {
  public let projectName: String
  public let totalCount: Int
  public let failureMessages: [String]

  public init(projectName: String, totalCount: Int, failureMessages: [String]) {
    self.projectName = projectName
    self.totalCount = totalCount
    self.failureMessages = failureMessages
  }

  public var failureMessage: String? {
    let cleanedMessages = failureMessages
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    guard !cleanedMessages.isEmpty else {
      return nil
    }

    let serviceWord = totalCount == 1 ? "service" : "services"
    return "\(cleanedMessages.count) of \(totalCount) \(serviceWord) failed in \(projectName): \(uniqueMessages(cleanedMessages).joined(separator: "; "))"
  }
}

public struct PortdeckHeaderProgressState: Sendable {
  public let isRefreshing: Bool
  public let isStopping: Bool

  public init(isRefreshing: Bool, isStopping: Bool) {
    self.isRefreshing = isRefreshing
    self.isStopping = isStopping
  }

  public var showsProgress: Bool {
    isStopping
  }
}

public struct PortdeckStopControlPresentation: Equatable, Sendable {
  public let systemImage: String
  public let isDestructive: Bool

  public static let destructive = PortdeckStopControlPresentation(
    systemImage: "xmark.circle.fill",
    isDestructive: true
  )
}

public struct PortdeckOpenControlPresentation: Equatable, Sendable {
  public let systemImage: String
  public let isPrimary: Bool

  public static let primary = PortdeckOpenControlPresentation(
    systemImage: "arrow.up.forward.square.fill",
    isPrimary: true
  )
}

public extension PortdeckStatus {
  var danglingExposures: [PortdeckExposure] {
    (exposures ?? []).filter { $0.status == "dangling" }
  }
}

public extension PortdeckExposure {
  var targetLabel: String {
    if let targetHost, let targetPort {
      return "\(displayHost(targetHost)):\(targetPort)"
    }
    if let targetPort {
      return ":\(targetPort)"
    }
    return endpointLabel(from: targetUrl) ?? targetUrl
  }

  var serviceDisplayText: String {
    "\(kind) \(publicUrl) -> \(targetLabel)"
  }

  var danglingDisplayText: String {
    "\(kind) -> \(targetLabel), target down"
  }

  func matchesSearch(_ query: String) -> Bool {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalizedQuery.isEmpty else {
      return true
    }

    return [
      id,
      kind,
      publicUrl,
      targetUrl,
      targetHost,
      targetPort.map(String.init),
      agentApiUrl,
      agentPid.map(String.init),
      agentCwd,
      status,
      attachedServiceId,
      targetLabel,
      serviceDisplayText,
      danglingDisplayText
    ].compactMap { $0 }.contains { $0.lowercased().contains(normalizedQuery) }
  }
}

public extension ProjectGroup {
  var repoFolderURLString: String? {
    fileURLString(for: repoRoot)
  }

  var repositoryOpenURLString: String? {
    validGitHubRepositoryURLString(repositoryUrl)
  }

  var hasJumpActions: Bool {
    repoFolderURLString != nil || nonEmpty(repoRoot) != nil || repositoryOpenURLString != nil
  }

  var stoppableServices: [PortdeckService] {
    worktrees.flatMap(\.services).filter(\.canStop)
  }

  var stopAllTarget: ProjectStopAllTarget? {
    let services = stoppableServices
    guard !services.isEmpty else {
      return nil
    }

    return ProjectStopAllTarget(projectID: id, projectName: projectName, services: services)
  }
}

public extension WorktreeGroup {
  var folderURLString: String? {
    fileURLString(for: path)
  }

  var repositoryOpenURLString: String? {
    validGitHubRepositoryURLString(repositoryUrl)
  }

  var hasJumpActions: Bool {
    folderURLString != nil || nonEmpty(path) != nil || repositoryOpenURLString != nil
  }

  func mainListContextSummary(
    projectName: String,
    repoRoot: String? = nil,
    showsPrimaryWorktreeLabel: Bool = false
  ) -> String? {
    let worktreeLabel = mainListWorktreeLabel(
      projectName: projectName,
      repoRoot: repoRoot,
      showsPrimaryWorktreeLabel: showsPrimaryWorktreeLabel
    )
    let packageLabel = mainListPackageSummary(projectName: projectName, worktreeLabel: worktreeLabel)
    let parts = [worktreeLabel, packageLabel].compactMap { $0 }

    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func mainListWorktreeLabel(
    projectName: String,
    repoRoot: String?,
    showsPrimaryWorktreeLabel: Bool
  ) -> String? {
    let isPrimaryWorktree = areSamePath(path, repoRoot)
    for candidate in [name, branch].compactMap({ $0 }) {
      let normalized = normalizedContextLabel(candidate)
      if ["main", "master"].contains(normalized) {
        guard showsPrimaryWorktreeLabel else {
          continue
        }
        if !isPrimaryWorktree, let folderLabel = worktreeFolderLabel(excluding: [projectName, candidate]) {
          return "\(candidate) · \(folderLabel)"
        }
        return meaningfulContextLabel(candidate, excluding: [projectName])
      }

      if let label = meaningfulContextLabel(candidate, excluding: [projectName]) {
        return label
      }
    }

    return nil
  }

  private func worktreeFolderLabel(excluding excludedValues: [String]) -> String? {
    guard let path else {
      return nil
    }

    return meaningfulContextLabel(URL(fileURLWithPath: path).lastPathComponent, excluding: excludedValues)
  }

  private func mainListPackageSummary(projectName: String, worktreeLabel: String?) -> String? {
    let contexts = services
      .compactMap(\.subcontext)
      .filter { $0.relativePath.trimmingCharacters(in: .whitespacesAndNewlines) != "." }

    guard !contexts.isEmpty else {
      return nil
    }

    let uniquePaths = Set(contexts.map(\.path))
    if uniquePaths.count > 1 {
      return "\(uniquePaths.count) packages"
    }

    let excludedLabels = [
      projectName,
      name,
      branch,
      worktreeLabel,
      "main"
    ].compactMap { $0 }

    let first = contexts[0]
    for candidate in [first.displayName, first.name, first.relativePath].compactMap({ $0 }) {
      if let label = meaningfulContextLabel(candidate, excluding: excludedLabels) {
        return label
      }
    }

    return nil
  }
}

public extension PortdeckService {
  var canStop: Bool {
    guard status == "running" else {
      return false
    }

    switch source {
    case "process":
      return pid != nil
    case "docker":
      return containerId?.isEmpty == false
    default:
      return false
    }
  }

  var stopConfirmationTitle: String {
    if let port {
      return "Stop \(stopTargetName) on :\(port)?"
    }
    return "Stop \(stopTargetName)?"
  }

  func openURLString(preferNamedURLs: Bool) -> String? {
    guard let rawURL = primaryOpenURLString(preferNamedURLs: preferNamedURLs),
      isValidOpenURLString(rawURL)
    else {
      return nil
    }

    return rawURL
  }

  var unknownServiceCategory: PortdeckUnknownServiceCategory {
    if isLikelyMacOSSystemListener {
      return .likelySystem
    }

    if nonEmpty(groupingReason) != nil || (source == "docker" && confidence == "low") {
      return .needsAttribution
    }

    return .unattached
  }

  func matchesSearch(_ query: String, preferNamedURLs: Bool, context: [String]) -> Bool {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalizedQuery.isEmpty else {
      return true
    }

    return compactSearchTokens(preferNamedURLs: preferNamedURLs, context: context)
      .contains { $0.lowercased().contains(normalizedQuery) }
  }

  func primaryOpenURLString(preferNamedURLs: Bool) -> String? {
    url
  }

  var rawEndpointLabel: String? {
    preferredEndpointLabel
  }

  func primaryEndpointLabel(preferNamedURLs: Bool) -> String? {
    preferredEndpointLabel
  }

  var preferredEndpointLabel: String? {
    if let listener = listeners?.first(where: { $0.isPreferred }) ?? listeners?.first {
      return endpointLabel(from: listener.url)
    }

    if let url {
      return endpointLabel(from: url)
    }

    if let address, let port {
      return "\(displayHost(address)):\(port)"
    }

    if let port {
      return ":\(port)"
    }

    return nil
  }

  var localhostCollisionSummary: String? {
    guard let localhostCollision else {
      return nil
    }

    let peer = localhostCollision.conflictsWith.first { conflict in
      if let url = conflict.url, endpointLabel(from: url)?.hasPrefix("localhost:") == true {
        return true
      }
      if let address = conflict.address, isWildcardAddress(address) {
        return true
      }
      return false
    } ?? localhostCollision.conflictsWith.first

    guard let peer else {
      return localhostCollision.message
    }

    let target = peer.projectName ?? peer.name
    let localhostLabel = endpointLabel(from: localhostCollision.localhostUrl) ?? "localhost:\(localhostCollision.port)"
    return "\(localhostLabel) -> \(target)"
  }

  var endpointHealthSummary: String? {
    guard let endpointHealth else {
      return nil
    }

    let label = endpointLabel(from: endpointHealth.url) ?? preferredEndpointLabel ?? "endpoint"
    return "\(formatHealthResult(endpointHealth)) at \(label)"
  }

  var endpointHealthSeverity: EndpointHealthSeverity {
    guard let endpointHealth else {
      return .unknown
    }

    switch endpointHealth.status {
    case "ok":
      return .ok
    case "http-error", "unreachable", "timeout":
      return .error
    case "unknown":
      return .unknown
    default:
      return .warning
    }
  }

  var activityCPUText: String? {
    guard let cpuPercent = activity?.cpuPercent else {
      return nil
    }

    return formatPercent(cpuPercent)
  }

  var activityMemoryText: String? {
    if let memoryRssBytes = activity?.memoryRssBytes {
      return formatCompactByteCount(memoryRssBytes)
    }

    if let memoryUsageBytes = activity?.memoryUsageBytes {
      return formatCompactByteCount(memoryUsageBytes)
    }

    return nil
  }

  private var stopTargetName: String {
    if source == "docker" {
      return nonEmpty(containerName) ?? name
    }
    return nonEmpty(processName) ?? name
  }

  private func compactSearchTokens(preferNamedURLs: Bool, context: [String]) -> [String] {
    let serviceTokens: [String?] = [
      id,
      name,
      source,
      status,
      port.map(String.init),
      url,
      address,
      protocolName,
      primaryEndpointLabel(preferNamedURLs: preferNamedURLs),
      rawEndpointLabel,
      pid.map(String.init),
      processName,
      command,
      cwd,
      hostIp,
      containerName,
      containerId,
      containerPort.map(String.init),
      image,
      activityCPUText,
      activityMemoryText,
      confidence,
      subcontext?.name,
      subcontext?.displayName,
      subcontext?.relativePath,
      groupingReason
    ]
    let exposureTokens: [String?] = (exposures ?? []).flatMap { exposure in
      [
        exposure.kind,
        exposure.publicUrl,
        exposure.targetUrl,
        exposure.targetHost,
        exposure.targetPort.map(String.init),
        exposure.agentCwd,
        exposure.status,
        exposure.targetLabel,
        exposure.serviceDisplayText
      ]
    }

    let healthTokens: [String?] = [
      endpointHealth?.url,
      endpointHealth?.status,
      endpointHealth?.statusCode.map(String.init),
      endpointHealth?.remoteAddress,
      endpointHealth?.latencyMs.map(String.init),
      endpointHealth?.error,
      endpointHealthSummary
    ]

    let collisionTokens: [String?] = [
      localhostCollision?.port.description,
      localhostCollision?.localhostUrl,
      localhostCollision?.message,
      localhostCollisionSummary
    ] + (localhostCollision?.conflictsWith ?? []).flatMap { peer in
      [
        peer.serviceId,
        peer.name,
        peer.projectName,
        peer.worktreeName,
        peer.url,
        peer.address
      ]
    }

    return context + (serviceTokens + exposureTokens + healthTokens + collisionTokens).compactMap { $0 }
  }
}

public extension Array where Element == PortdeckService {
  func unknownServiceSections(
    showLikelySystemListeners: Bool,
    searchText: String,
    preferNamedURLs: Bool
  ) -> [PortdeckUnknownServiceSection] {
    let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let shouldShowLikelySystem = showLikelySystemListeners || !normalizedSearch.isEmpty
    var servicesByCategory: [PortdeckUnknownServiceCategory: [PortdeckService]] = [:]

    for service in self {
      let category = service.unknownServiceCategory
      guard category != .likelySystem || shouldShowLikelySystem else {
        continue
      }
      guard service.matchesSearch(
        searchText,
        preferNamedURLs: preferNamedURLs,
        context: ["Unknown", category.title, category.detail]
      ) else {
        continue
      }

      servicesByCategory[category, default: []].append(service)
    }

    return PortdeckUnknownServiceCategory.allCases.compactMap { category in
      guard let services = servicesByCategory[category], !services.isEmpty else {
        return nil
      }
      return PortdeckUnknownServiceSection(category: category, services: services)
    }
  }
}

private func uniqueMessages(_ messages: [String]) -> [String] {
  var seen = Set<String>()
  return messages.filter { seen.insert($0).inserted }
}

private let likelyMacOSSystemProcessNames: Set<String> = [
  "controlcenter",
  "rapportd"
]

private extension PortdeckService {
  var isLikelyMacOSSystemListener: Bool {
    guard source == "process" else {
      return false
    }

    let names = [processName, name]
      .compactMap { nonEmpty($0)?.lowercased() }

    guard names.contains(where: { likelyMacOSSystemProcessNames.contains($0) }) else {
      return false
    }

    return cwd == "/" || cwd == nil
  }
}

private func nonEmpty(_ value: String?) -> String? {
  guard let value, !value.isEmpty else {
    return nil
  }
  return value
}

private func fileURLString(for path: String?) -> String? {
  guard let path = nonEmpty(path), path.hasPrefix("/") else {
    return nil
  }

  return URL(fileURLWithPath: path).absoluteString
}

private func validGitHubRepositoryURLString(_ rawURL: String?) -> String? {
  guard let rawURL = nonEmpty(rawURL),
    let url = URL(string: rawURL),
    let scheme = url.scheme?.lowercased(),
    ["http", "https"].contains(scheme),
    url.host?.lowercased() == "github.com"
  else {
    return nil
  }

  let pathParts = url.pathComponents.filter { $0 != "/" }
  guard pathParts.count == 2 else {
    return nil
  }

  return rawURL
}

private func areSamePath(_ left: String?, _ right: String?) -> Bool {
  guard let left = nonEmpty(left), let right = nonEmpty(right) else {
    return false
  }

  return URL(fileURLWithPath: left).standardizedFileURL.path == URL(fileURLWithPath: right).standardizedFileURL.path
}

private func meaningfulContextLabel(_ value: String, excluding excludedValues: [String]) -> String? {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else {
    return nil
  }

  let normalized = normalizedContextLabel(trimmed)
  guard !excludedValues.contains(where: { normalizedContextLabel($0) == normalized }) else {
    return nil
  }

  return trimmed
}

private func normalizedContextLabel(_ value: String) -> String {
  value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func formatPercent(_ value: Double) -> String {
  let rounded = (value * 10).rounded() / 10
  if rounded.rounded() == rounded {
    return "\(Int(rounded))%"
  }
  return String(format: "%.1f%%", rounded)
}

private func formatCompactByteCount(_ bytes: Int) -> String {
  let units = ["B", "KB", "MB", "GB", "TB"]
  var value = Double(bytes)
  var unitIndex = 0

  while value >= 1024 && unitIndex < units.count - 1 {
    value /= 1024
    unitIndex += 1
  }

  if unitIndex == 0 {
    return "\(Int(value))\(units[unitIndex])"
  }

  return "\(Int(value.rounded()))\(units[unitIndex])"
}

public extension PortConflict {
  var displayMessage: String {
    let failingLocalhost = endpoints.first { endpoint in
      endpoint.endpointDisplayLabel?.hasPrefix("localhost:") == true && endpoint.healthSeverity == .error
    }
    let healthyConcrete = endpoints.first { endpoint in
      endpoint.endpointDisplayLabel?.hasPrefix("127.0.0.1:") == true && endpoint.healthSeverity == .ok
    } ?? endpoints.first { endpoint in
      endpoint.endpointDisplayLabel?.hasPrefix("[::1]:") == true && endpoint.healthSeverity == .ok
    }

    if let failingLocalhost, let healthyConcrete {
      return "\(failingLocalhost.endpointDisplayLabel ?? failingLocalhost.url) is failing, but \(healthyConcrete.endpointDisplayLabel ?? healthyConcrete.url) is healthy. These are different services."
    }

    return message
  }

  var summaryLines: [String] {
    endpoints.map(\.summaryLine)
  }
}

public extension PortConflictEndpoint {
  var endpointDisplayLabel: String? {
    endpointLabel(from: url)
  }

  var healthSeverity: EndpointHealthSeverity {
    guard let health else {
      return .unknown
    }

    switch health.status {
    case "ok":
      return .ok
    case "http-error", "unreachable", "timeout":
      return .error
    case "unknown":
      return .unknown
    default:
      return .warning
    }
  }

  var summaryLine: String {
    let label = endpointDisplayLabel ?? url
    let target = projectName ?? name
    let healthText = health.map { "(\(formatHealthResult($0)))" }

    if let target, let healthText {
      return "\(label) -> \(target) \(healthText)"
    }
    if let target {
      return "\(label) -> \(target)"
    }
    if let healthText {
      return "\(label) \(healthText)"
    }
    return label
  }
}

private func endpointLabel(from rawURL: String) -> String? {
  guard let schemeRange = rawURL.range(of: "://") else {
    return rawURL.isEmpty ? nil : rawURL
  }

  let afterScheme = rawURL[schemeRange.upperBound...]
  if let slashIndex = afterScheme.firstIndex(of: "/") {
    return String(afterScheme[..<slashIndex])
  }
  return String(afterScheme)
}

private func isValidOpenURLString(_ rawURL: String) -> Bool {
  guard let url = URL(string: rawURL),
    let scheme = url.scheme?.lowercased(),
    ["http", "https"].contains(scheme),
    url.host != nil
  else {
    return false
  }

  return true
}

private func displayHost(_ address: String) -> String {
  if isWildcardAddress(address) {
    return "localhost"
  }
  if address.contains(":") && !address.hasPrefix("[") && !address.hasSuffix("]") {
    return "[\(address)]"
  }
  return address
}

private func isWildcardAddress(_ address: String) -> Bool {
  ["*", "0.0.0.0", "::", "[::]"].contains(address)
}

private func formatHealthResult(_ health: EndpointHealth) -> String {
  switch health.status {
  case "ok":
    if let statusCode = health.statusCode {
      return "\(statusCode) OK"
    }
    return "OK"
  case "http-error":
    if let statusCode = health.statusCode {
      return "HTTP \(statusCode)"
    }
    return "HTTP error"
  case "timeout":
    return "timed out"
  case "unreachable":
    return "unreachable"
  default:
    return "unknown"
  }
}

public struct ServiceSubcontext: Decodable, Equatable, Sendable {
  public let type: String
  public let name: String?
  public let displayName: String
  public let path: String
  public let relativePath: String
  public let manifestPath: String

  public init(type: String, name: String?, displayName: String, path: String, relativePath: String, manifestPath: String) {
    self.type = type
    self.name = name
    self.displayName = displayName
    self.path = path
    self.relativePath = relativePath
    self.manifestPath = manifestPath
  }
}
