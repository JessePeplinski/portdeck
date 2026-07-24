export type ServiceSource = "process" | "docker" | "registered" | "portdeck-run";
export type ServiceStatus = "running" | "stale" | "stopped" | "unknown";
export type Confidence = "high" | "medium" | "low";
export type ListenerFamily = "IPv4" | "IPv6" | "unknown";
export type ExposureKind = "ngrok";
export type ExposureStatus = "attached" | "dangling" | "unknown";

export type DiscoveredProcessPort = {
  pid: number;
  processName: string;
  port: number;
  protocol: "TCP";
  address: string;
};

export type ProcessInfo = {
  pid: number;
  processName: string;
  command?: string;
  cwd?: string;
};

export type ServiceActivity = {
  cpuPercent?: number;
  memoryRssBytes?: number;
  memoryUsageBytes?: number;
  memoryLimitBytes?: number;
};

export type GitInfo = {
  repoRoot: string;
  branch?: string;
  worktreePath: string;
  worktreeName: string;
  remoteUrl?: string;
  repositoryUrl?: string;
};

export type PackageSubcontext = {
  type: "package";
  name?: string;
  displayName: string;
  path: string;
  relativePath: string;
  manifestPath: string;
};

export type ServiceListener = {
  address: string;
  family?: ListenerFamily;
  port: number;
  url: string;
  isWildcard: boolean;
  isLoopback: boolean;
  isPreferred: boolean;
};

export type LocalhostCollisionPeer = {
  serviceId: string;
  name: string;
  projectName?: string;
  worktreeName?: string;
  url?: string;
  address?: string;
};

export type LocalhostCollision = {
  port: number;
  localhostUrl: string;
  message: string;
  conflictsWith: LocalhostCollisionPeer[];
};

export type EndpointHealthStatus = "ok" | "http-error" | "unreachable" | "timeout" | "unknown";

export type EndpointHealth = {
  url: string;
  status: EndpointHealthStatus;
  statusCode?: number;
  remoteAddress?: string;
  latencyMs?: number;
  error?: string;
};

export type PortConflictEndpoint = {
  url: string;
  serviceId?: string;
  name?: string;
  projectName?: string;
  worktreeName?: string;
  address?: string;
  health?: EndpointHealth;
};

export type PortConflict = {
  port: number;
  severity: "warning" | "error";
  title: string;
  message: string;
  endpoints: PortConflictEndpoint[];
};

export type PortdeckExposure = {
  id: string;
  kind: ExposureKind;
  publicUrl: string;
  targetUrl: string;
  targetHost?: string;
  targetPort?: number;
  agentApiUrl: string;
  agentPid?: number;
  agentCwd?: string;
  status: ExposureStatus;
  attachedServiceId?: string;
};

export type DockerContainerSummary = {
  id: string;
  name: string;
  image: string;
  ports: string;
};

export type DockerMount = {
  type?: string;
  source: string;
  destination: string;
  mode?: string;
  rw?: boolean;
};

export type DiscoveredDockerPort = {
  containerId: string;
  containerName: string;
  image: string;
  hostIp: string;
  hostPort: number;
  containerPort: number;
  protocol: string;
  labels: Record<string, string>;
  composeProjectWorkingDir?: string;
  composeConfigFiles?: string[];
  containerWorkingDir?: string;
  mounts?: DockerMount[];
};

export type PortdeckService = {
  id: string;
  name: string;
  source: ServiceSource;
  status: ServiceStatus;
  port?: number;
  url?: string;
  address?: string;
  protocol?: string;
  listeners?: ServiceListener[];
  localhostCollision?: LocalhostCollision;
  endpointHealth?: EndpointHealth;
  exposures?: PortdeckExposure[];
  pid?: number;
  processName?: string;
  command?: string;
  cwd?: string;
  hostIp?: string;
  containerName?: string;
  containerId?: string;
  containerPort?: number;
  image?: string;
  activity?: ServiceActivity;
  confidence: Confidence;
  subcontext?: PackageSubcontext;
  groupingReason?: string;
};

export type WorktreeGroup = {
  name: string;
  path?: string;
  branch?: string;
  remoteUrl?: string;
  repositoryUrl?: string;
  services: PortdeckService[];
};

export type ProjectGroup = {
  projectName: string;
  repoRoot?: string;
  remoteUrl?: string;
  repositoryUrl?: string;
  worktrees: WorktreeGroup[];
};

export type PortdeckStatus = {
  schemaVersion: "0.2";
  generatedAt: string;
  groups: ProjectGroup[];
  unknown: PortdeckService[];
  warnings: string[];
  portConflicts?: PortConflict[];
  exposures?: PortdeckExposure[];
};

export type BuildStatusInput = {
  generatedAt: string;
  processPorts: DiscoveredProcessPort[];
  processes: Map<number, ProcessInfo>;
  processActivityByPid?: Map<number, ServiceActivity>;
  dockerPorts: DiscoveredDockerPort[];
  dockerActivityByContainerId?: Map<string, ServiceActivity>;
  gitByCwd: Map<string, GitInfo>;
  packageByCwd?: Map<string, PackageSubcontext>;
  exposures?: PortdeckExposure[];
  warnings: string[];
  probeEndpoints?: (urls: string[]) => Promise<Map<string, EndpointHealth>>;
};
