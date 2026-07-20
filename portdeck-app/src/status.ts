import path from "node:path";
import { isNgrokProcess } from "./ngrok.js";
import type {
  BuildStatusInput,
  Confidence,
  DiscoveredDockerPort,
  DiscoveredProcessPort,
  EndpointHealth,
  GitInfo,
  PackageSubcontext,
  PortConflict,
  PortConflictEndpoint,
  PortdeckExposure,
  PortdeckService,
  PortdeckStatus,
  ProjectGroup,
  ServiceListener,
  WorktreeGroup
} from "./types.js";

type ServiceWithContext = {
  service: PortdeckService;
  projectName?: string;
  worktreeName?: string;
};

type ProcessGrouping = {
  projectName: string;
  repoRoot?: string;
  remoteUrl?: string;
  repositoryUrl?: string;
  worktreeName: string;
  worktreePath?: string;
  branch?: string;
};

type LocalhostCollisionContext = {
  port: number;
  localhostUrl: string;
  services: ServiceWithContext[];
};

type DockerGroupingResolution =
  | {
      kind: "grouped";
      grouping: ProcessGrouping;
      confidence: Confidence;
      subcontext?: PackageSubcontext;
    }
  | {
      kind: "docker-only";
      projectName: string;
    }
  | {
      kind: "ambiguous";
      reason: string;
    };

type DockerPathMatch = {
  hostPath: string;
  git: GitInfo;
  subcontext?: PackageSubcontext;
};

export async function buildStatus(input: BuildStatusInput): Promise<PortdeckStatus> {
  const groups = new Map<string, ProjectGroup>();
  const unknown: PortdeckService[] = [];
  const warnings = [...input.warnings];
  const dockerHostPorts = new Set(input.dockerPorts.map((port) => port.hostPort));

  for (const ports of groupProcessPorts(input.processPorts)) {
    const port = ports[0]!;
    const process = input.processes.get(port.pid);
    if (isDockerDesktopBackendProcess(process, port.processName) && dockerHostPorts.has(port.port)) {
      continue;
    }

    const listeners = buildServiceListeners(
      ports.map((item) => item.address),
      port.port
    );
    const preferredListener = findPreferredListener(listeners);
    const service: PortdeckService = {
      id: `pid-${port.pid}-port-${port.port}`,
      name: inferProcessServiceName(process?.command, port.processName),
      source: "process",
      status: "running",
      port: port.port,
      url: preferredListener?.url,
      address: preferredListener?.address ?? port.address,
      protocol: port.protocol,
      listeners,
      pid: port.pid,
      processName: process?.processName ?? port.processName,
      confidence: process?.cwd && input.gitByCwd.has(process.cwd) ? "high" : process?.cwd ? "medium" : "low"
    };
    if (process?.command) {
      service.command = redactCommand(process.command);
    }
    if (process?.cwd) {
      service.cwd = process.cwd;
      const subcontext = input.packageByCwd?.get(process.cwd);
      if (subcontext) {
        service.subcontext = subcontext;
      }
    }
    const processActivity = input.processActivityByPid?.get(port.pid);
    if (hasActivity(processActivity)) {
      service.activity = processActivity;
    }

    if (isNgrokAgentService(port, process)) {
      service.confidence = "low";
      service.groupingReason = "ngrok agent is machine-level; cwd is provenance only";
      unknown.push(service);
      continue;
    }

    if (!process?.cwd) {
      unknown.push(service);
      continue;
    }

    const grouping = resolveProcessGrouping(process.cwd, input.gitByCwd.get(process.cwd));
    if (!grouping) {
      service.confidence = "low";
      service.groupingReason = processGroupingReason(process.cwd);
      unknown.push(service);
      continue;
    }

    const project = getProject(groups, grouping.projectName, grouping.repoRoot, grouping.remoteUrl, grouping.repositoryUrl);
    const worktree = getWorktree(
      project,
      grouping.worktreeName,
      grouping.worktreePath,
      grouping.branch,
      grouping.remoteUrl,
      grouping.repositoryUrl
    );
    worktree.services.push(service);
  }

  for (const ports of groupDockerPorts(input.dockerPorts)) {
    const port = ports[0]!;
    const projectName = port.labels["com.docker.compose.project"] || inferDockerProjectName(port.containerName);
    const listeners = buildServiceListeners(
      ports.map((item) => item.hostIp),
      port.hostPort
    );
    const preferredListener = findPreferredListener(listeners);
    const service: PortdeckService = {
      id: `docker-${port.containerId}-port-${port.hostPort}`,
      name: inferDockerServiceName(port.containerName, projectName, port.labels),
      source: "docker",
      status: "running",
      port: port.hostPort,
      url: preferredListener?.url,
      hostIp: preferredListener?.address ?? port.hostIp,
      protocol: port.protocol,
      listeners,
      containerName: port.containerName,
      containerId: port.containerId,
      containerPort: port.containerPort,
      image: port.image,
      processName: port.image,
      command: `docker container ${port.containerName}`,
      confidence: "medium"
    };
    const dockerActivity = input.dockerActivityByContainerId?.get(port.containerId);
    if (hasActivity(dockerActivity)) {
      service.activity = dockerActivity;
    }

    const dockerGrouping = resolveDockerGrouping(port, projectName, input);
    if (dockerGrouping.kind === "ambiguous") {
      service.confidence = "low";
      service.groupingReason = dockerGrouping.reason;
      unknown.push(service);
      continue;
    }

    if (dockerGrouping.kind === "grouped") {
      service.confidence = dockerGrouping.confidence;
      if (dockerGrouping.subcontext) {
        service.subcontext = dockerGrouping.subcontext;
      }
      const project = getProject(
        groups,
        dockerGrouping.grouping.projectName,
        dockerGrouping.grouping.repoRoot,
        dockerGrouping.grouping.remoteUrl,
        dockerGrouping.grouping.repositoryUrl
      );
      const worktree = getWorktree(
        project,
        dockerGrouping.grouping.worktreeName,
        dockerGrouping.grouping.worktreePath,
        dockerGrouping.grouping.branch,
        dockerGrouping.grouping.remoteUrl,
        dockerGrouping.grouping.repositoryUrl
      );
      worktree.services.push(service);
      continue;
    }

    const project = getProject(groups, dockerGrouping.projectName);
    const worktree = getDockerWorktree(project);
    worktree.services.push(service);
  }

  const exposures = input.exposures ? annotateExposures(input.exposures, groups, unknown, warnings) : undefined;
  const localhostCollisionContexts = annotateLocalhostCollisions(groups, unknown, warnings);
  const portConflicts = await buildPortConflicts(localhostCollisionContexts, input.probeEndpoints, warnings);

  return {
    schemaVersion: "0.1",
    generatedAt: input.generatedAt,
    groups: sortGroups(
      Array.from(groups.values()).map((group) => ({
        ...group,
        worktrees: sortWorktrees(
          group.worktrees.map((worktree) => ({
            ...worktree,
            services: sortServices(worktree.services)
          }))
        )
      }))
    ),
    unknown: sortServices(unknown),
    warnings: warnings.sort(),
    ...(portConflicts && portConflicts.length > 0 ? { portConflicts } : {}),
    ...(exposures && exposures.length > 0 ? { exposures } : {})
  };
}

function hasActivity(activity: PortdeckService["activity"] | undefined): activity is NonNullable<PortdeckService["activity"]> {
  return Boolean(
    activity &&
      (activity.cpuPercent !== undefined ||
        activity.memoryRssBytes !== undefined ||
        activity.memoryUsageBytes !== undefined ||
        activity.memoryLimitBytes !== undefined)
  );
}

function groupProcessPorts(ports: DiscoveredProcessPort[]): DiscoveredProcessPort[][] {
  const groups = new Map<string, DiscoveredProcessPort[]>();

  for (const port of ports) {
    const key = `${port.pid}:${port.port}:${port.protocol}`;
    const existing = groups.get(key);
    if (existing) {
      existing.push(port);
    } else {
      groups.set(key, [port]);
    }
  }

  return Array.from(groups.values());
}

function groupDockerPorts(ports: DiscoveredDockerPort[]): DiscoveredDockerPort[][] {
  const groups = new Map<string, DiscoveredDockerPort[]>();

  for (const port of ports) {
    const key = `${port.containerId}:${port.hostPort}:${port.containerPort}:${port.protocol}`;
    const existing = groups.get(key);
    if (existing) {
      existing.push(port);
    } else {
      groups.set(key, [port]);
    }
  }

  return Array.from(groups.values());
}

function buildServiceListeners(addresses: string[], port: number): ServiceListener[] {
  const seen = new Set<string>();
  const listeners = addresses.flatMap((address) => {
    if (seen.has(address)) {
      return [];
    }
    seen.add(address);
    return [
      {
        address,
        family: inferListenerFamily(address),
        port,
        url: buildLocalHttpUrl(address, port),
        isWildcard: isWildcardAddress(address),
        isLoopback: isLoopbackAddress(address),
        isPreferred: false
      } satisfies ServiceListener
    ];
  });

  const preferredIndex = listeners.reduce((bestIndex, listener, index) => {
    if (bestIndex === -1) {
      return index;
    }
    const best = listeners[bestIndex]!;
    const score = listenerPreferenceScore(listener.address);
    const bestScore = listenerPreferenceScore(best.address);
    return score < bestScore ? index : bestIndex;
  }, -1);

  return listeners.map((listener, index) => ({
    ...listener,
    isPreferred: index === preferredIndex
  }));
}

function findPreferredListener(listeners: ServiceListener[]): ServiceListener | undefined {
  return listeners.find((listener) => listener.isPreferred) ?? listeners[0];
}

function resolveProcessGrouping(cwd: string, git: GitInfo | undefined): ProcessGrouping | undefined {
  if (git) {
    return {
      projectName: path.basename(git.repoRoot),
      repoRoot: git.repoRoot,
      remoteUrl: git.remoteUrl,
      repositoryUrl: git.repositoryUrl,
      worktreeName: git.worktreeName,
      worktreePath: git.worktreePath,
      branch: git.branch
    };
  }

  return inferCodexWorktreeGrouping(cwd);
}

function inferCodexWorktreeGrouping(cwd: string): ProcessGrouping | undefined {
  const resolved = path.resolve(cwd);
  const marker = `${path.sep}.codex${path.sep}worktrees${path.sep}`;
  const markerIndex = resolved.indexOf(marker);
  if (markerIndex === -1) {
    return undefined;
  }

  const prefix = resolved.slice(0, markerIndex + marker.length);
  const [worktreeSlug, projectName] = resolved.slice(markerIndex + marker.length).split(path.sep);
  if (!worktreeSlug || !projectName) {
    return undefined;
  }

  return {
    projectName,
    worktreeName: `codex/${worktreeSlug}`,
    worktreePath: path.join(prefix, worktreeSlug, projectName)
  };
}

function processGroupingReason(cwd: string): string {
  return `No Git worktree found for ${cwd}`;
}

function isDockerDesktopBackendProcess(process: { processName?: string; command?: string } | undefined, fallbackName: string): boolean {
  const processName = process?.processName ?? fallbackName;
  return processName === "com.docker.backend" || Boolean(process?.command?.includes("com.docker.backend"));
}

function isNgrokAgentService(port: DiscoveredProcessPort, process: { processName?: string; command?: string } | undefined): boolean {
  return port.port === 4040 && isNgrokProcess(process, port.processName);
}

function buildLocalHttpUrl(address: string, port: number): string {
  return `http://${formatUrlHost(address)}:${port}`;
}

function formatUrlHost(address: string): string {
  const normalized = address.trim();
  if (!normalized || isWildcardAddress(normalized)) {
    return "localhost";
  }
  if (normalized.includes(":") && !normalized.startsWith("[") && !normalized.endsWith("]")) {
    return `[${normalized}]`;
  }
  return normalized;
}

function normalizeAddress(address: string): string {
  const normalized = address.trim();
  if (normalized.startsWith("[") && normalized.endsWith("]")) {
    return normalized.slice(1, -1);
  }
  return normalized;
}

function isWildcardAddress(address: string): boolean {
  return ["*", "0.0.0.0", "::", "[::]"].includes(address.trim());
}

function isLoopbackAddress(address: string): boolean {
  const normalized = normalizeAddress(address);
  return normalized === "127.0.0.1" || normalized === "::1" || normalized === "localhost";
}

function inferListenerFamily(address: string): ServiceListener["family"] {
  const normalized = normalizeAddress(address);
  if (normalized === "*") {
    return "unknown";
  }
  if (normalized.includes(":")) {
    return "IPv6";
  }
  if (/^\d+\.\d+\.\d+\.\d+$/.test(normalized)) {
    return "IPv4";
  }
  return "unknown";
}

function listenerPreferenceScore(address: string): number {
  const normalized = normalizeAddress(address);
  if (normalized === "127.0.0.1") {
    return 0;
  }
  if (normalized === "::1") {
    return 1;
  }
  if (!isWildcardAddress(address)) {
    return 2;
  }
  return 3;
}

function annotateLocalhostCollisions(
  groups: Map<string, ProjectGroup>,
  unknown: PortdeckService[],
  warnings: string[]
): LocalhostCollisionContext[] {
  const services = collectServices(groups, unknown);
  const servicesByPort = new Map<number, ServiceWithContext[]>();
  const collisionContexts: LocalhostCollisionContext[] = [];

  for (const item of services) {
    if (item.service.port === undefined) {
      continue;
    }
    const existing = servicesByPort.get(item.service.port);
    if (existing) {
      existing.push(item);
    } else {
      servicesByPort.set(item.service.port, [item]);
    }
  }

  for (const [port, servicesOnPort] of servicesByPort) {
    const distinctServices = dedupeServicesById(servicesOnPort);
    if (distinctServices.length < 2) {
      continue;
    }

    const localhostUrl = buildLocalHttpUrl("localhost", port);
    for (const item of distinctServices) {
      item.service.localhostCollision = {
        port,
        localhostUrl,
        message: buildCollisionMessage(item.service, port),
        conflictsWith: distinctServices
          .filter((candidate) => candidate.service.id !== item.service.id)
          .map(toCollisionPeer)
          .sort(sortCollisionPeers)
      };
    }

    warnings.push(buildCollisionWarning(port, distinctServices));
    collisionContexts.push({
      port,
      localhostUrl,
      services: distinctServices
    });
  }

  return collisionContexts;
}

async function buildPortConflicts(
  collisionContexts: LocalhostCollisionContext[],
  probeEndpoints: BuildStatusInput["probeEndpoints"],
  warnings: string[]
): Promise<PortConflict[] | undefined> {
  if (!probeEndpoints || collisionContexts.length === 0) {
    return undefined;
  }

  const portConflicts: PortConflict[] = [];
  for (const collision of collisionContexts) {
    const urls = buildProbeUrlsForPortConflict(collision);
    const healthByUrl = await probeEndpoints(urls);
    attachEndpointHealth(collision.services, healthByUrl);

    const conflict = buildPortConflict(collision, urls, healthByUrl);
    portConflicts.push(conflict);
    warnings.push(`${conflict.title}: ${conflict.message}`);
  }

  return portConflicts.sort((left, right) => left.port - right.port);
}

function buildProbeUrlsForPortConflict(collision: LocalhostCollisionContext): string[] {
  const urls = [
    collision.localhostUrl,
    buildLocalHttpUrl("127.0.0.1", collision.port),
    buildLocalHttpUrl("::1", collision.port)
  ];

  for (const item of collision.services) {
    if (item.service.url) {
      urls.push(item.service.url);
    }
    for (const listener of item.service.listeners ?? []) {
      urls.push(listener.url);
    }
  }

  return Array.from(new Set(urls));
}

function attachEndpointHealth(services: ServiceWithContext[], healthByUrl: Map<string, EndpointHealth>): void {
  for (const item of services) {
    const health = findServiceEndpointHealth(item.service, healthByUrl);
    if (health) {
      item.service.endpointHealth = health;
    }
  }
}

function findServiceEndpointHealth(service: PortdeckService, healthByUrl: Map<string, EndpointHealth>): EndpointHealth | undefined {
  if (service.url) {
    const health = healthByUrl.get(service.url);
    if (health) {
      return health;
    }
  }

  const preferredListenerUrl = service.listeners?.find((listener) => listener.isPreferred)?.url;
  if (preferredListenerUrl) {
    const health = healthByUrl.get(preferredListenerUrl);
    if (health) {
      return health;
    }
  }

  for (const listener of service.listeners ?? []) {
    const health = healthByUrl.get(listener.url);
    if (health) {
      return health;
    }
  }

  return undefined;
}

function buildPortConflict(
  collision: LocalhostCollisionContext,
  urls: string[],
  healthByUrl: Map<string, EndpointHealth>
): PortConflict {
  const endpoints = urls.map((url) => toPortConflictEndpoint(collision.services, url, healthByUrl.get(url)));

  return {
    port: collision.port,
    severity: inferPortConflictSeverity(collision, endpoints),
    title: `Port ${collision.port} conflict`,
    message: buildPortConflictMessage(collision, endpoints),
    endpoints
  };
}

function toPortConflictEndpoint(
  services: ServiceWithContext[],
  url: string,
  health: EndpointHealth | undefined
): PortConflictEndpoint {
  const service = findServiceForEndpointUrl(services, url);
  if (!service) {
    return {
      url,
      ...(health ? { health } : {})
    };
  }

  const listener = service.service.listeners?.find((candidate) => candidate.url === url);
  return {
    serviceId: service.service.id,
    name: service.service.name,
    ...(inferCollisionProjectName(service) ? { projectName: inferCollisionProjectName(service) } : {}),
    ...(service.worktreeName ? { worktreeName: service.worktreeName } : {}),
    url,
    ...(listener?.address ? { address: listener.address } : service.service.address ? { address: service.service.address } : {}),
    ...(health ? { health } : {})
  };
}

function findServiceForEndpointUrl(services: ServiceWithContext[], url: string): ServiceWithContext | undefined {
  return services.find((item) => item.service.url === url || item.service.listeners?.some((listener) => listener.url === url));
}

function inferPortConflictSeverity(collision: LocalhostCollisionContext, endpoints: PortConflictEndpoint[]): PortConflict["severity"] {
  const hasUnhealthyOpenedEndpoint = endpoints.some((endpoint) => {
    if (!isUnhealthyEndpoint(endpoint.health)) {
      return false;
    }
    return endpoint.url === collision.localhostUrl || Boolean(endpoint.serviceId);
  });

  return hasUnhealthyOpenedEndpoint ? "error" : "warning";
}

function buildPortConflictMessage(collision: LocalhostCollisionContext, endpoints: PortConflictEndpoint[]): string {
  const localhostEndpoint = endpoints.find((endpoint) => endpoint.url === collision.localhostUrl);
  const ipv4Endpoint = endpoints.find((endpoint) => endpoint.url === buildLocalHttpUrl("127.0.0.1", collision.port));
  const ipv6Endpoint = endpoints.find((endpoint) => endpoint.url === buildLocalHttpUrl("::1", collision.port));

  if (isUnhealthyEndpoint(localhostEndpoint?.health) && isOkEndpoint(ipv4Endpoint?.health)) {
    return `${endpointLabelFromUrl(collision.localhostUrl)} returns ${formatHealthResult(localhostEndpoint!.health!)} while ${endpointLabelFromUrl(ipv4Endpoint!.url)} returns ${formatHealthResult(ipv4Endpoint!.health!)}`;
  }

  if (isUnhealthyEndpoint(localhostEndpoint?.health) && isOkEndpoint(ipv6Endpoint?.health)) {
    return `${endpointLabelFromUrl(collision.localhostUrl)} returns ${formatHealthResult(localhostEndpoint!.health!)} while ${endpointLabelFromUrl(ipv6Endpoint!.url)} returns ${formatHealthResult(ipv6Endpoint!.health!)}`;
  }

  const unhealthyServiceEndpoint = endpoints.find((endpoint) => endpoint.serviceId && isUnhealthyEndpoint(endpoint.health));
  const healthyEndpoint = endpoints.find((endpoint) => isOkEndpoint(endpoint.health));
  if (unhealthyServiceEndpoint?.health && healthyEndpoint?.health) {
    return `${endpointLabelFromUrl(unhealthyServiceEndpoint.url)} returns ${formatHealthResult(unhealthyServiceEndpoint.health)} while ${endpointLabelFromUrl(healthyEndpoint.url)} returns ${formatHealthResult(healthyEndpoint.health)}`;
  }

  return buildCollisionWarning(collision.port, collision.services);
}

function isOkEndpoint(health: EndpointHealth | undefined): boolean {
  return health?.status === "ok";
}

function isUnhealthyEndpoint(health: EndpointHealth | undefined): boolean {
  return health?.status === "http-error" || health?.status === "timeout" || health?.status === "unreachable";
}

function formatHealthResult(health: EndpointHealth): string {
  if (health.status === "ok") {
    return health.statusCode ? `${health.statusCode} OK` : "OK";
  }
  if (health.status === "http-error") {
    return health.statusCode ? `HTTP ${health.statusCode}` : "HTTP error";
  }
  if (health.status === "timeout") {
    return "timed out";
  }
  if (health.status === "unreachable") {
    return "unreachable";
  }
  return "unknown";
}

function collectServices(groups: Map<string, ProjectGroup>, unknown: PortdeckService[]): ServiceWithContext[] {
  const services: ServiceWithContext[] = [];

  for (const group of groups.values()) {
    for (const worktree of group.worktrees) {
      for (const service of worktree.services) {
        services.push({
          service,
          projectName: group.projectName,
          worktreeName: worktree.name
        });
      }
    }
  }

  for (const service of unknown) {
    services.push({ service });
  }

  return services;
}

function annotateExposures(
  exposures: PortdeckExposure[],
  groups: Map<string, ProjectGroup>,
  unknown: PortdeckService[],
  warnings: string[]
): PortdeckExposure[] {
  const services = collectServices(groups, unknown);
  return exposures.map((exposure) => annotateExposure(exposure, services, warnings));
}

function annotateExposure(
  exposure: PortdeckExposure,
  services: ServiceWithContext[],
  warnings: string[]
): PortdeckExposure {
  if (exposure.targetPort === undefined) {
    warnings.push(`ngrok tunnel ${exposure.publicUrl} target ${exposure.targetUrl} is missing a local target port`);
    return {
      ...exposure,
      status: "unknown"
    };
  }

  if (!isSupportedLocalExposureTarget(exposure.targetHost)) {
    warnings.push(
      `ngrok tunnel ${exposure.publicUrl} targets ${exposureTargetLabel(exposure)}, which is not a supported local loopback target`
    );
    return {
      ...exposure,
      status: "unknown"
    };
  }

  const matches = dedupeServicesById(
    services.filter((item) => item.service.status === "running" && item.service.port === exposure.targetPort)
  );

  if (matches.length === 0) {
    warnings.push(`ngrok tunnel ${exposure.publicUrl} targets ${exposureTargetLabel(exposure)}, but no local listener is running`);
    return {
      ...exposure,
      status: "dangling"
    };
  }

  if (matches.length > 1) {
    warnings.push(`ngrok tunnel ${exposure.publicUrl} targets ${exposureTargetLabel(exposure)}, but multiple local listeners match`);
    return {
      ...exposure,
      status: "unknown"
    };
  }

  const service = matches[0]!.service;
  const annotated = {
    ...exposure,
    status: "attached",
    attachedServiceId: service.id
  } satisfies PortdeckExposure;
  service.exposures = [...(service.exposures ?? []), annotated];
  return annotated;
}

function isSupportedLocalExposureTarget(targetHost: string | undefined): boolean {
  if (!targetHost) {
    return false;
  }

  const normalized = normalizeAddress(targetHost).toLowerCase();
  return normalized === "localhost" || normalized === "127.0.0.1" || normalized === "::1";
}

function exposureTargetLabel(exposure: PortdeckExposure): string {
  if (exposure.targetHost && exposure.targetPort !== undefined) {
    return `${formatHostLabel(exposure.targetHost)}:${exposure.targetPort}`;
  }
  if (exposure.targetPort !== undefined) {
    return `:${exposure.targetPort}`;
  }
  return endpointLabelFromUrl(exposure.targetUrl);
}

function formatHostLabel(host: string): string {
  const normalized = normalizeAddress(host);
  if (normalized.includes(":")) {
    return `[${normalized}]`;
  }
  return normalized;
}

function dedupeServicesById(services: ServiceWithContext[]): ServiceWithContext[] {
  const seen = new Set<string>();
  return services.filter((item) => {
    if (seen.has(item.service.id)) {
      return false;
    }
    seen.add(item.service.id);
    return true;
  });
}

function buildCollisionMessage(service: PortdeckService, port: number): string {
  const localhostLabel = `localhost:${port}`;
  const preferredUrl = service.listeners?.find((listener) => listener.isPreferred)?.url ?? service.url;
  const preferredLabel = preferredUrl ? endpointLabelFromUrl(preferredUrl) : undefined;

  if (preferredLabel && preferredLabel !== localhostLabel) {
    return `${localhostLabel} may route to a different service than ${preferredLabel}`;
  }

  return `${localhostLabel} is shared by multiple services`;
}

function buildCollisionWarning(port: number, services: ServiceWithContext[]): string {
  const labels = new Set<string>();
  for (const item of services) {
    for (const listener of item.service.listeners ?? []) {
      const normalized = normalizeAddress(listener.address);
      if (normalized === "127.0.0.1") {
        labels.add("127.0.0.1");
      }
      if (normalized === "::1") {
        labels.add("[::1]");
      }
    }
  }

  const suffix = labels.size > 0 ? `; localhost may not match ${formatDisjunction(Array.from(labels))}` : "";
  return `localhost:${port} is ambiguous across ${services.length} services${suffix}`;
}

function formatDisjunction(items: string[]): string {
  if (items.length <= 1) {
    return items[0] ?? "";
  }
  return `${items.slice(0, -1).join(", ")} or ${items.at(-1)}`;
}

function toCollisionPeer(item: ServiceWithContext) {
  const preferredListener = item.service.listeners?.find((listener) => listener.isPreferred);
  const projectName = inferCollisionProjectName(item);
  return {
    serviceId: item.service.id,
    name: item.service.name,
    ...(projectName ? { projectName } : {}),
    ...(item.worktreeName ? { worktreeName: item.worktreeName } : {}),
    ...(item.service.url ? { url: item.service.url } : {}),
    ...(preferredListener?.address ? { address: preferredListener.address } : item.service.address ? { address: item.service.address } : {})
  };
}

function inferCollisionProjectName(item: ServiceWithContext): string | undefined {
  if (item.projectName) {
    return item.projectName;
  }
  if (item.service.subcontext?.displayName) {
    return item.service.subcontext.displayName;
  }
  if (item.service.cwd) {
    return path.basename(item.service.cwd) || undefined;
  }
  return undefined;
}

function sortCollisionPeers(left: ReturnType<typeof toCollisionPeer>, right: ReturnType<typeof toCollisionPeer>): number {
  return (
    (left.projectName ?? "").localeCompare(right.projectName ?? "") ||
    (left.worktreeName ?? "").localeCompare(right.worktreeName ?? "") ||
    left.name.localeCompare(right.name) ||
    left.serviceId.localeCompare(right.serviceId)
  );
}

function endpointLabelFromUrl(url: string): string {
  return url.replace(/^https?:\/\//, "").split("/")[0] ?? url;
}

function redactCommand(command: string): string {
  const parts = command.match(/[^\s=]+=(?:"[^"]*"|'[^']*')|"[^"]*"|'[^']*'|\S+/g) ?? [];
  const redacted: string[] = [];
  const secretFlagPattern = /^--?[a-z0-9-]*(secret|token|password|passwd|credential|key)[a-z0-9-]*/i;
  const secretNamePattern = /(secret|token|password|passwd|credential|key)/i;

  for (let index = 0; index < parts.length; index += 1) {
    const part = parts[index];
    if (!part) {
      continue;
    }

    if (secretFlagPattern.test(part)) {
      if (part.includes("=")) {
        redacted.push(part.replace(/=.*/, "=[redacted]"));
      } else {
        redacted.push(part);
        const next = parts[index + 1];
        if (next && !next.startsWith("-")) {
          redacted.push("[redacted]");
          index += 1;
        }
      }
      continue;
    }

    const assignmentName = /^([a-z_][a-z0-9_]*)=/i.exec(part)?.[1];
    if (assignmentName && secretNamePattern.test(assignmentName)) {
      redacted.push(part.replace(/=.*/, "=[redacted]"));
      continue;
    }

    if (/^(?:bearer|basic)$/i.test(part) && redacted.at(-1)?.toLowerCase() === "authorization:") {
      redacted.push(part);
      if (parts[index + 1]) {
        redacted.push("[redacted]");
        index += 1;
      }
      continue;
    }

    redacted.push(redactURLUserInfo(part));
  }

  return redacted.join(" ");
}

function redactURLUserInfo(value: string): string {
  return value.replace(
    /([a-z][a-z0-9+.-]*:\/\/[^\s/:@]+:)[^\s/@]+(@)/gi,
    "$1[redacted]$2"
  );
}

function resolveDockerGrouping(
  port: DiscoveredDockerPort,
  dockerProjectName: string,
  input: BuildStatusInput
): DockerGroupingResolution {
  const pathGrouping = resolveDockerPathGrouping(port, input);
  if (pathGrouping) {
    return pathGrouping;
  }

  const composeGrouping = resolveDockerComposeProjectGrouping(dockerProjectName, input.gitByCwd);
  if (composeGrouping) {
    return composeGrouping;
  }

  return {
    kind: "docker-only",
    projectName: dockerProjectName
  };
}

function resolveDockerPathGrouping(
  port: DiscoveredDockerPort,
  input: BuildStatusInput
): DockerGroupingResolution | undefined {
  const matches = collectDockerHostPathCandidates(port).flatMap((hostPath) => {
    const git = findGitInfoForHostPath(hostPath, input.gitByCwd);
    if (!git) {
      return [];
    }

    return [
      {
        hostPath,
        git,
        subcontext: findPackageContextForHostPath(hostPath, input.packageByCwd)
      } satisfies DockerPathMatch
    ];
  });

  if (matches.length === 0) {
    return undefined;
  }

  const uniqueWorktrees = uniqueDockerPathMatchesByWorktree(matches);
  if (uniqueWorktrees.length > 1) {
    return {
      kind: "ambiguous",
      reason: "Docker attribution is ambiguous: path metadata maps to multiple Git worktrees"
    };
  }

  const match = uniqueWorktrees[0]!;
  const subcontext = bestPackageContextForWorktree(matches, match.git);
  return {
    kind: "grouped",
    grouping: groupingFromGit(match.git),
    confidence: "high",
    ...(subcontext ? { subcontext } : {})
  };
}

function resolveDockerComposeProjectGrouping(
  dockerProjectName: string,
  gitByCwd: Map<string, GitInfo>
): DockerGroupingResolution | undefined {
  const matches = uniqueGitInfos(Array.from(gitByCwd.values())).filter((git) => {
    return path.basename(git.repoRoot) === dockerProjectName;
  });

  if (matches.length === 0) {
    return undefined;
  }

  const uniqueWorktrees = uniqueGitInfosByWorktree(matches);
  if (uniqueWorktrees.length !== 1) {
    return {
      kind: "ambiguous",
      reason: `Docker attribution is ambiguous: Compose project ${dockerProjectName} matches multiple Git worktrees`
    };
  }

  return {
    kind: "grouped",
    grouping: groupingFromGit(uniqueWorktrees[0]!),
    confidence: "medium"
  };
}

export function collectDockerHostPathCandidates(port: DiscoveredDockerPort): string[] {
  const candidates: string[] = [];

  addHostPathCandidate(candidates, port.composeProjectWorkingDir);
  for (const configFile of port.composeConfigFiles ?? []) {
    addHostPathCandidate(candidates, path.dirname(configFile));
  }

  for (const mount of port.mounts ?? []) {
    if (isDockerBindMount(mount)) {
      addHostPathCandidate(candidates, mount.source);
    }
  }

  const mappedWorkingDir = mapContainerPathToHostPath(port.containerWorkingDir, port.mounts ?? []);
  addHostPathCandidate(candidates, mappedWorkingDir);

  return Array.from(new Set(candidates));
}

function addHostPathCandidate(candidates: string[], candidate: string | undefined): void {
  if (!candidate || !path.isAbsolute(candidate)) {
    return;
  }
  candidates.push(path.resolve(candidate));
}

function isDockerBindMount(mount: NonNullable<DiscoveredDockerPort["mounts"]>[number]): boolean {
  return !mount.type || mount.type === "bind";
}

function mapContainerPathToHostPath(
  containerPath: string | undefined,
  mounts: NonNullable<DiscoveredDockerPort["mounts"]>
): string | undefined {
  if (!containerPath) {
    return undefined;
  }

  const normalizedContainerPath = path.posix.resolve(containerPath);
  const matchingMount = mounts
    .filter(isDockerBindMount)
    .filter((mount) => isWithinOrEqualPosix(path.posix.resolve(mount.destination), normalizedContainerPath))
    .sort((left, right) => right.destination.length - left.destination.length)[0];
  if (!matchingMount) {
    return undefined;
  }

  const relativePath = path.posix.relative(path.posix.resolve(matchingMount.destination), normalizedContainerPath);
  return path.join(matchingMount.source, relativePath);
}

function isWithinOrEqualPosix(basePath: string, targetPath: string): boolean {
  const relativePath = path.posix.relative(basePath, targetPath);
  return relativePath === "" || (!relativePath.startsWith("..") && !path.posix.isAbsolute(relativePath));
}

function isWithinOrEqual(basePath: string, targetPath: string): boolean {
  const relativePath = path.relative(path.resolve(basePath), path.resolve(targetPath));
  return relativePath === "" || (!relativePath.startsWith("..") && !path.isAbsolute(relativePath));
}

function findGitInfoForHostPath(hostPath: string, gitByCwd: Map<string, GitInfo>): GitInfo | undefined {
  const exact = gitByCwd.get(hostPath);
  if (exact) {
    return exact;
  }

  return Array.from(gitByCwd.values())
    .filter((git) => git.worktreePath && isWithinOrEqual(git.worktreePath, hostPath))
    .sort((left, right) => right.worktreePath.length - left.worktreePath.length)[0];
}

function findPackageContextForHostPath(
  hostPath: string,
  packageByCwd: BuildStatusInput["packageByCwd"]
): PackageSubcontext | undefined {
  if (!packageByCwd) {
    return undefined;
  }

  const exact = packageByCwd.get(hostPath);
  if (exact) {
    return exact;
  }

  return Array.from(packageByCwd.values())
    .filter((packageContext) => isWithinOrEqual(packageContext.path, hostPath))
    .sort((left, right) => right.path.length - left.path.length)[0];
}

function uniqueDockerPathMatchesByWorktree(matches: DockerPathMatch[]): DockerPathMatch[] {
  const byWorktree = new Map<string, DockerPathMatch>();
  for (const match of matches) {
    const key = gitWorktreeKey(match.git);
    const existing = byWorktree.get(key);
    if (!existing || match.hostPath.length > existing.hostPath.length) {
      byWorktree.set(key, match);
    }
  }
  return Array.from(byWorktree.values());
}

function bestPackageContextForWorktree(matches: DockerPathMatch[], git: GitInfo): PackageSubcontext | undefined {
  return matches
    .filter((match) => gitWorktreeKey(match.git) === gitWorktreeKey(git))
    .map((match) => match.subcontext)
    .filter((subcontext): subcontext is PackageSubcontext => Boolean(subcontext))
    .sort((left, right) => right.path.length - left.path.length)[0];
}

function uniqueGitInfos(infos: GitInfo[]): GitInfo[] {
  const unique = new Map<string, GitInfo>();
  for (const info of infos) {
    unique.set(`${info.repoRoot}|${info.worktreePath}|${info.branch ?? ""}`, info);
  }
  return Array.from(unique.values());
}

function uniqueGitInfosByWorktree(infos: GitInfo[]): GitInfo[] {
  const unique = new Map<string, GitInfo>();
  for (const info of infos) {
    unique.set(gitWorktreeKey(info), info);
  }
  return Array.from(unique.values());
}

function gitWorktreeKey(git: GitInfo): string {
  return `${git.repoRoot}|${git.worktreePath}`;
}

function groupingFromGit(git: GitInfo): ProcessGrouping {
  return {
    projectName: path.basename(git.repoRoot),
    repoRoot: git.repoRoot,
    remoteUrl: git.remoteUrl,
    repositoryUrl: git.repositoryUrl,
    worktreeName: git.worktreeName,
    worktreePath: git.worktreePath,
    branch: git.branch
  };
}

function getProject(
  groups: Map<string, ProjectGroup>,
  projectName: string,
  repoRoot?: string,
  remoteUrl?: string,
  repositoryUrl?: string
): ProjectGroup {
  const key = repoRoot ?? projectName;
  const existing = groups.get(key);
  if (existing) {
    applyProjectGitMetadata(existing, repoRoot, remoteUrl, repositoryUrl);
    return existing;
  }

  const sameNameEntries = Array.from(groups.entries()).filter(([, group]) => group.projectName === projectName);
  if (repoRoot) {
    const nameOnlyEntry = sameNameEntries.find(([, group]) => !group.repoRoot);
    if (nameOnlyEntry) {
      const [nameOnlyKey, project] = nameOnlyEntry;
      applyProjectGitMetadata(project, repoRoot, remoteUrl, repositoryUrl);
      groups.delete(nameOnlyKey);
      groups.set(repoRoot, project);
      return project;
    }
  } else if (sameNameEntries.length === 1) {
    return sameNameEntries[0]![1];
  }

  const project: ProjectGroup = {
    projectName,
    repoRoot,
    ...(remoteUrl ? { remoteUrl } : {}),
    ...(repositoryUrl ? { repositoryUrl } : {}),
    worktrees: []
  };
  groups.set(key, project);
  return project;
}

function applyProjectGitMetadata(
  project: ProjectGroup,
  repoRoot?: string,
  remoteUrl?: string,
  repositoryUrl?: string
): void {
  if (repoRoot) {
    project.repoRoot = repoRoot;
  }
  if (remoteUrl) {
    project.remoteUrl = remoteUrl;
  }
  if (repositoryUrl) {
    project.repositoryUrl = repositoryUrl;
  }
}

function getWorktree(
  project: ProjectGroup,
  name: string,
  pathValue?: string,
  branch?: string,
  remoteUrl?: string,
  repositoryUrl?: string
): WorktreeGroup {
  const existing = project.worktrees.find((worktree) => worktree.name === name && worktree.path === pathValue);
  if (existing) {
    applyWorktreeGitMetadata(existing, branch, remoteUrl, repositoryUrl);
    return existing;
  }

  const worktree: WorktreeGroup = {
    name,
    path: pathValue,
    branch,
    ...(remoteUrl ? { remoteUrl } : {}),
    ...(repositoryUrl ? { repositoryUrl } : {}),
    services: []
  };
  project.worktrees.push(worktree);
  return worktree;
}

function applyWorktreeGitMetadata(
  worktree: WorktreeGroup,
  branch?: string,
  remoteUrl?: string,
  repositoryUrl?: string
): void {
  if (branch) {
    worktree.branch = branch;
  }
  if (remoteUrl) {
    worktree.remoteUrl = remoteUrl;
  }
  if (repositoryUrl) {
    worktree.repositoryUrl = repositoryUrl;
  }
}

function getDockerWorktree(project: ProjectGroup): WorktreeGroup {
  if (project.repoRoot && project.worktrees.length === 1) {
    return project.worktrees[0]!;
  }

  return getWorktree(project, "docker");
}

function inferProcessServiceName(command: string | undefined, processName: string): string {
  const normalized = command?.toLowerCase() ?? "";
  if (/\b(npm|pnpm|yarn|bun)\s+(run\s+)?dev\b/.test(normalized)) {
    return "web";
  }
  if (/\b(next|vite|astro)\s+dev\b/.test(normalized)) {
    return "web";
  }
  if (/(^|\s)(?:\S+\/)?convex\s+dev\b/.test(normalized)) {
    return "convex";
  }
  return processName;
}

function inferDockerProjectName(containerName: string): string {
  return containerName.split("-")[0] || "docker";
}

function inferDockerServiceName(containerName: string, projectName: string, labels: Record<string, string>): string {
  const composeService = labels["com.docker.compose.service"];
  if (composeService) {
    return composeService;
  }

  let name = containerName;
  if (name.startsWith(`${projectName}-`)) {
    name = name.slice(projectName.length + 1);
  }
  if (name.startsWith(`${projectName}_`)) {
    name = name.slice(projectName.length + 1);
  }
  if (name.endsWith(`-${projectName}`)) {
    name = name.slice(0, -(projectName.length + 1));
  }
  if (name.endsWith(`_${projectName}`)) {
    name = name.slice(0, -(projectName.length + 1));
  }
  if (name.startsWith("supabase_")) {
    name = name.slice("supabase_".length);
  }
  name = name.replace(/-\d+$/, "");
  name = name.replace(/_\d+$/, "");
  return name || containerName;
}

function sortGroups(groups: ProjectGroup[]): ProjectGroup[] {
  return [...groups].sort((left, right) => {
    return left.projectName.localeCompare(right.projectName) || (left.repoRoot ?? "").localeCompare(right.repoRoot ?? "");
  });
}

function sortWorktrees(worktrees: WorktreeGroup[]): WorktreeGroup[] {
  return [...worktrees].sort((left, right) => {
    return left.name.localeCompare(right.name) || (left.path ?? "").localeCompare(right.path ?? "");
  });
}

function sortServices(services: PortdeckService[]): PortdeckService[] {
  return [...services].sort((left, right) => {
    const leftPort = left.port ?? Number.MAX_SAFE_INTEGER;
    const rightPort = right.port ?? Number.MAX_SAFE_INTEGER;
    return leftPort - rightPort || left.name.localeCompare(right.name);
  });
}
