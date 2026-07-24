import Foundation
import PortDeckCore
import Testing

@Test func summarizesAndClassifiesRepresentativeLocalServices() throws {
  let healthyProcess = localTestService(
    id: "process-api",
    name: "production API",
    source: "process",
    port: 3000,
    endpointHealth: EndpointHealth(
      url: "http://localhost:3000",
      status: "ok",
      statusCode: 200,
      remoteAddress: "127.0.0.1",
      latencyMs: 12,
      error: nil
    ),
    activity: ServiceActivity(cpuPercent: 2.5, memoryRssBytes: 42_000_000, memoryUsageBytes: nil, memoryLimitBytes: nil)
  )
  let healthyDocker = localTestService(
    id: "docker-db",
    name: "database",
    source: "docker",
    port: 5432,
    containerID: "container-1"
  )
  let endpointError = localTestService(
    id: "process-web",
    name: "web",
    port: 4000,
    endpointHealth: EndpointHealth(
      url: "http://localhost:4000",
      status: "http-error",
      statusCode: 503,
      remoteAddress: "::1",
      latencyMs: 80,
      error: "Service unavailable"
    )
  )
  let collision = localTestService(
    id: "process-worker",
    name: "worker",
    port: 5000,
    collision: LocalhostCollision(
      port: 5000,
      localhostUrl: "http://localhost:5000",
      message: "localhost is ambiguous",
      conflictsWith: [
        LocalhostCollisionPeer(
          serviceId: "peer",
          name: "other API",
          projectName: "Other",
          worktreeName: "main",
          url: "http://127.0.0.1:5000",
          address: "127.0.0.1"
        )
      ]
    )
  )
  let project = localTestProject(name: "PortDeck", services: [healthyProcess, healthyDocker, endpointError, collision])
  let unknown = localTestService(id: "unknown", name: "mystery", source: "process", port: 9000)
  let status = localTestStatus(groups: [project], unknown: [unknown], warnings: ["Check Docker permissions"])

  #expect(LocalStatusPresentation.service(healthyProcess) == LocalServicePresentation(label: "Healthy", detail: nil, tone: .positive))
  #expect(LocalStatusPresentation.service(healthyDocker).label == "Running")
  #expect(LocalStatusPresentation.service(healthyDocker).detail == nil)
  #expect(LocalStatusPresentation.service(endpointError).label == "Endpoint error")
  #expect(LocalStatusPresentation.service(endpointError).detail?.contains("HTTP 503") == true)
  #expect(LocalStatusPresentation.service(collision).label == "Port conflict")
  #expect(LocalStatusPresentation.service(collision).detail?.contains("Other") == true)
  #expect(LocalStatusPresentation.visibleServiceStateLabel(
    LocalStatusPresentation.service(healthyProcess),
    isStopping: false
  ) == nil)
  #expect(LocalStatusPresentation.visibleServiceStateLabel(
    LocalStatusPresentation.service(healthyDocker),
    isStopping: false
  ) == nil)
  #expect(LocalStatusPresentation.visibleServiceStateLabel(
    LocalStatusPresentation.service(endpointError),
    isStopping: false
  ) == "Endpoint error")
  #expect(LocalStatusPresentation.visibleServiceStateLabel(
    LocalStatusPresentation.service(healthyProcess),
    isStopping: true
  ) == "Stopping…")

  let projectSummary = LocalStatusPresentation.projectSummary(project)
  #expect(projectSummary.serviceCount == 4)
  #expect(projectSummary.problemServiceCount == 2)
  #expect(projectSummary.problemLabel == "2 need attention")

  let overview = LocalStatusPresentation.overview(for: status, showLikelySystemListeners: true)
  #expect(overview.projectCount == 1)
  #expect(overview.serviceCount == 5)
  #expect(overview.problemCount == 3)
}

@Test func ordersProblemsBySeverityAndFiltersUnrelatedConflicts() {
  let errorConflict = localTestConflict(port: 3000, severity: "error", title: "API collision", project: "PortDeck")
  let warningConflict = localTestConflict(port: 4000, severity: "warning", title: "Preview collision", project: "Preview")
  let exposure = PortdeckExposure(
    id: "ngrok-stale",
    kind: "ngrok",
    publicUrl: "https://stale.ngrok.app",
    targetUrl: "http://localhost:4999",
    targetHost: "localhost",
    targetPort: 4999,
    agentApiUrl: "http://127.0.0.1:4040",
    agentPid: 42,
    agentCwd: "/tmp/demo",
    status: "dangling",
    attachedServiceId: nil
  )
  let status = localTestStatus(
    warnings: ["Docker daemon is slow"],
    conflicts: [warningConflict, errorConflict],
    exposures: [exposure]
  )

  let problems = LocalStatusPresentation.problems(in: status, matching: "")
  #expect(problems.map(\.title) == ["API collision", "Preview collision", exposure.danglingDisplayText, "Local runtime warning"])
  #expect(problems.first?.tone == .critical)
  #expect(problems.dropFirst().allSatisfy { $0.tone == .warning })
  #expect(LocalStatusPresentation.problems(in: status, matching: "PortDeck").map(\.title) == ["API collision"])
  #expect(LocalStatusPresentation.problems(in: status, matching: "stale.ngrok.app").map(\.id) == ["exposure-ngrok-stale"])
  #expect(LocalStatusPresentation.problems(in: status, matching: "not-present").isEmpty)
}

@Test func localSearchMatchesHealthCollisionActivityExposureAndUnknownMetadata() {
  let exposure = PortdeckExposure(
    id: "ngrok-attached",
    kind: "ngrok",
    publicUrl: "https://demo.ngrok.app",
    targetUrl: "http://localhost:3000",
    targetHost: "localhost",
    targetPort: 3000,
    agentApiUrl: "http://127.0.0.1:4040",
    agentPid: 12,
    agentCwd: "/tmp/demo",
    status: "attached",
    attachedServiceId: "service"
  )
  let service = localTestService(
    id: "service",
    name: "API",
    port: 3000,
    endpointHealth: EndpointHealth(
      url: "http://localhost:3000/health",
      status: "timeout",
      statusCode: 504,
      remoteAddress: "::1",
      latencyMs: 1200,
      error: "Gateway timeout"
    ),
    collision: LocalhostCollision(
      port: 3000,
      localhostUrl: "http://localhost:3000",
      message: "localhost maps to another listener",
      conflictsWith: [
        LocalhostCollisionPeer(
          serviceId: "peer",
          name: "Admin",
          projectName: "Control Plane",
          worktreeName: "feature/admin",
          url: "http://127.0.0.1:3000",
          address: "127.0.0.1"
        )
      ]
    ),
    exposures: [exposure],
    activity: ServiceActivity(cpuPercent: 7.5, memoryRssBytes: 67_108_864, memoryUsageBytes: nil, memoryLimitBytes: nil),
    groupingReason: "Multiple repositories matched"
  )

  for query in ["timeout", "504", "::1", "1200", "Gateway timeout", "Control Plane", "feature/admin", "7.5%", "64MB", "demo.ngrok.app", "Multiple repositories"] {
    #expect(service.matchesSearch(query, preferNamedURLs: false, context: []), "Expected Local search to match \(query)")
  }

  let sections = [service].unknownServiceSections(
    showLikelySystemListeners: false,
    searchText: "needs attribution",
    preferNamedURLs: false
  )
  #expect(sections.map(\.category) == [.needsAttribution])
}

@Test func stabilizesProjectWorktreeServiceAndUnknownOrderingAcrossSnapshots() {
  let serviceA = localTestService(id: "a", name: "A", port: 3000)
  let serviceB = localTestService(id: "b", name: "B", port: 3001)
  let serviceC = localTestService(id: "c", name: "C", port: 3002)
  let projectA = localTestProject(name: "A Project", services: [serviceA, serviceB])
  let projectB = localTestProject(name: "B Project", services: [serviceC])
  let unknownA = localTestService(id: "unknown-a", name: "Unknown A", port: 8000)
  let unknownB = localTestService(id: "unknown-b", name: "Unknown B", port: 8001)
  let previous = localTestStatus(groups: [projectA, projectB], unknown: [unknownA, unknownB])

  let incomingProjectA = localTestProject(name: "A Project", services: [serviceB, serviceA, serviceC])
  let incoming = localTestStatus(groups: [projectB, incomingProjectA], unknown: [unknownB, unknownA])
  let stabilized = LocalStatusPresentation.stabilized(incoming, preserving: previous)

  #expect(stabilized.groups.map(\.projectName) == ["A Project", "B Project"])
  #expect(stabilized.groups[0].worktrees[0].services.map(\.id) == ["a", "b", "c"])
  #expect(stabilized.unknown.map(\.id) == ["unknown-a", "unknown-b"])
}

@Test func omitsMissingMetadataAndBuildsSpecificAccessibilityLabels() {
  let emptyWorktree = WorktreeGroup(name: "PortDeck", path: "/repo", branch: nil, services: [])
  #expect(LocalStatusPresentation.worktreeMetadata(
    emptyWorktree,
    projectName: "PortDeck",
    repoRoot: "/repo",
    projectWorktreeCount: 1
  ).isEmpty)

  let package = ServiceSubcontext(
    type: "workspace",
    name: "mac",
    displayName: "PortDeck Mac",
    path: "/repo/portdeck-mac",
    relativePath: "portdeck-mac",
    manifestPath: "/repo/portdeck-mac/Package.swift"
  )
  let worktree = WorktreeGroup(
    name: "local-tab-refresh",
    path: "/repo-local-tab-refresh",
    branch: "feature/local-tab-ux-refresh",
    services: [localTestService(id: "app", name: "PortDeck", port: 3000, subcontext: package)]
  )
  let metadata = LocalStatusPresentation.worktreeMetadata(
    worktree,
    projectName: "PortDeck",
    repoRoot: "/repo",
    projectWorktreeCount: 2
  )
  #expect(metadata.map(\.text) == ["feature/local-tab-ux-refresh", "local-tab-refresh", "PortDeck Mac"])

  #expect(localOpenServiceAccessibilityLabel(serviceName: "production API", destination: "localhost:3000") == "Open production API at localhost:3000")
  #expect(localStopServiceAccessibilityLabel(serviceName: "production API") == "Stop production API")
  #expect(localServiceRowAccessibilityLabel(
    serviceName: "production API",
    source: "Process",
    state: "running"
  ) == "production API, Process service, running")
  #expect(localProjectDisclosureAccessibilityLabel(projectName: "PortDeck", isExpanded: false) == "Expand PortDeck project")
  #expect(localProjectActionsAccessibilityLabel(projectName: "PortDeck") == "Open PortDeck project actions")
  #expect(localWorktreeActionsAccessibilityLabel(worktreeName: "local-tab-refresh") == "Open local-tab-refresh worktree actions")
  #expect(localPollingAgeSeconds(lastUpdated: Date(timeIntervalSince1970: 100), relativeTo: Date(timeIntervalSince1970: 108.9)) == 8)
  #expect(localLastCheckedLabel(ageSeconds: 8) == "Checked 8s ago")
  #expect(!localSectionIsExpanded(searchText: "", isCollapsed: true))
  #expect(localSectionIsExpanded(searchText: "api", isCollapsed: true))
  #expect(!localSectionIsExpanded(searchText: "   ", isCollapsed: true))
}

private func localTestStatus(
  groups: [ProjectGroup] = [],
  unknown: [PortdeckService] = [],
  warnings: [String] = [],
  conflicts: [PortConflict]? = nil,
  exposures: [PortdeckExposure]? = nil
) -> PortdeckStatus {
  PortdeckStatus(
    schemaVersion: "0.2",
    generatedAt: "2026-07-17T12:00:00Z",
    groups: groups,
    unknown: unknown,
    warnings: warnings,
    portConflicts: conflicts,
    exposures: exposures
  )
}

private func localTestProject(
  name: String,
  services: [PortdeckService]
) -> ProjectGroup {
  ProjectGroup(
    projectName: name,
    repoRoot: "/repos/\(name)",
    worktrees: [
      WorktreeGroup(name: "main", path: "/repos/\(name)", branch: "main", services: services)
    ]
  )
}

private func localTestConflict(port: Int, severity: String, title: String, project: String) -> PortConflict {
  PortConflict(
    port: port,
    severity: severity,
    title: title,
    message: "localhost:\(port) has multiple listeners",
    endpoints: [
      PortConflictEndpoint(
        url: "http://localhost:\(port)",
        serviceId: "service-\(port)",
        name: "API",
        projectName: project,
        worktreeName: "main",
        address: "::1",
        health: nil
      )
    ]
  )
}

private func localTestService(
  id: String,
  name: String,
  source: String = "process",
  port: Int?,
  endpointHealth: EndpointHealth? = nil,
  collision: LocalhostCollision? = nil,
  exposures: [PortdeckExposure]? = nil,
  activity: ServiceActivity? = nil,
  containerID: String? = nil,
  subcontext: ServiceSubcontext? = nil,
  groupingReason: String? = nil
) -> PortdeckService {
  PortdeckService(
    id: id,
    name: name,
    source: source,
    status: "running",
    port: port,
    url: port.map { "http://localhost:\($0)" },
    address: "127.0.0.1",
    protocolName: "http",
    localhostCollision: collision,
    endpointHealth: endpointHealth,
    exposures: exposures,
    pid: source == "process" ? 123 : nil,
    processName: source == "process" ? name : nil,
    command: source == "process" ? "npm run dev" : nil,
    cwd: "/repos/demo",
    hostIp: nil,
    containerName: source == "docker" ? name : nil,
    containerId: containerID,
    containerPort: source == "docker" ? port : nil,
    image: source == "docker" ? "postgres:17" : nil,
    activity: activity,
    confidence: groupingReason == nil ? "high" : "low",
    subcontext: subcontext,
    groupingReason: groupingReason
  )
}
