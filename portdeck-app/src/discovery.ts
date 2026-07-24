import { execa } from "execa";
import { readFile } from "node:fs/promises";
import path from "node:path";
import {
  parseDockerInspectPorts,
  parseDockerPsJsonLines,
  parseDockerStatsJsonLines,
  parseLsofListenOutput,
  parsePsActivityOutput,
  parsePsOutput
} from "./parsers.js";
import { discoverNgrokExposures } from "./ngrok.js";
import { probeHttpEndpoints } from "./probes.js";
import { buildStatus, collectDockerHostPathCandidates } from "./status.js";
import type {
  DiscoveredDockerPort,
  DiscoveredProcessPort,
  GitInfo,
  PackageSubcontext,
  PortdeckExposure,
  PortdeckStatus,
  ProcessInfo,
  ServiceActivity
} from "./types.js";

type DiscoveryResult = {
  processPorts: DiscoveredProcessPort[];
  processes: Map<number, ProcessInfo>;
  processActivityByPid: Map<number, ServiceActivity>;
  dockerPorts: DiscoveredDockerPort[];
  dockerActivityByContainerId: Map<string, ServiceActivity>;
  gitByCwd: Map<string, GitInfo>;
  packageByCwd: Map<string, PackageSubcontext>;
  exposures: PortdeckExposure[];
  warnings: string[];
};

export async function getPortdeckStatus(): Promise<PortdeckStatus> {
  const discovery = await discover();
  return await buildStatus({
    generatedAt: new Date().toISOString(),
    probeEndpoints: probeHttpEndpoints,
    ...discovery
  });
}

export async function discover(): Promise<DiscoveryResult> {
  const warnings: string[] = [];
  const processPorts = await discoverProcessPorts(warnings);
  const processes = await discoverProcesses(processPorts, warnings);
  const processActivityByPid = await discoverProcessActivity(processPorts);
  const dockerPorts = await discoverDockerPorts(warnings);
  const dockerActivityByContainerId = await discoverDockerActivity(dockerPorts);
  const discoveryPaths = collectDiscoveryPaths(processes, dockerPorts);
  const gitByCwd = await discoverGitInfo(discoveryPaths, warnings);
  const packageByCwd = await discoverPackageContexts(discoveryPaths, gitByCwd);
  const exposures = await discoverNgrokExposures({
    processPorts,
    processes,
    warnings
  });

  return {
    processPorts,
    processes,
    processActivityByPid,
    gitByCwd,
    packageByCwd,
    dockerPorts,
    dockerActivityByContainerId,
    exposures,
    warnings
  };
}

async function discoverProcessActivity(ports: DiscoveredProcessPort[]): Promise<Map<number, ServiceActivity>> {
  const pids = Array.from(new Set(ports.map((port) => port.pid))).sort((left, right) => left - right);
  if (pids.length === 0) {
    return new Map();
  }

  const warnings: string[] = [];
  const result = await safeExeca("ps", ["-o", "pid=,%cpu=,rss=", "-p", pids.join(",")], warnings, "inspect process activity", {
    quiet: true
  });
  return result ? parsePsActivityOutput(result.stdout) : new Map();
}

async function discoverProcessPorts(warnings: string[]): Promise<DiscoveredProcessPort[]> {
  const result = await safeExeca(
    "lsof",
    ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcPnT"],
    warnings,
    "list listening TCP ports"
  );
  if (!result) {
    return [];
  }
  return parseLsofListenOutput(result.stdout);
}

async function discoverProcesses(
  ports: DiscoveredProcessPort[],
  warnings: string[]
): Promise<Map<number, ProcessInfo>> {
  const pids = Array.from(new Set(ports.map((port) => port.pid))).sort((left, right) => left - right);
  if (pids.length === 0) {
    return new Map();
  }

  const result = await safeExeca("ps", ["-o", "pid=,command=", "-p", pids.join(",")], warnings, "inspect processes");
  const processes = result ? parsePsOutput(result.stdout) : new Map<number, ProcessInfo>();

  await Promise.all(
    pids.map(async (pid) => {
      const process = processes.get(pid) ?? {
        pid,
        processName: ports.find((port) => port.pid === pid)?.processName ?? "unknown"
      };
      const cwd = await readProcessCwd(pid, warnings);
      if (cwd) {
        process.cwd = cwd;
      }
      processes.set(pid, process);
    })
  );

  return processes;
}

async function readProcessCwd(pid: number, warnings: string[]): Promise<string | undefined> {
  const result = await safeExeca("lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], warnings, `read cwd for pid ${pid}`, {
    quiet: true
  });
  if (!result) {
    warnings.push(`cwd unavailable for pid ${pid}`);
    return undefined;
  }

  const cwdLine = result.stdout
    .split("\n")
    .map((line) => line.trim())
    .find((line) => line.startsWith("n/"));
  return cwdLine?.slice(1);
}

function collectDiscoveryPaths(processes: Map<number, ProcessInfo>, dockerPorts: DiscoveredDockerPort[]): string[] {
  const paths = new Set<string>();

  for (const process of processes.values()) {
    if (process.cwd) {
      paths.add(process.cwd);
    }
  }

  for (const dockerPort of dockerPorts) {
    for (const hostPath of collectDockerHostPathCandidates(dockerPort)) {
      paths.add(hostPath);
    }
  }

  return Array.from(paths);
}

async function discoverGitInfo(cwdValues: string[], warnings: string[]): Promise<Map<string, GitInfo>> {
  const gitByCwd = new Map<string, GitInfo>();

  await Promise.all(
    cwdValues.map(async (cwd) => {
      const git = await readGitInfo(cwd, warnings);
      if (git) {
        gitByCwd.set(cwd, git);
      }
    })
  );

  return gitByCwd;
}

async function discoverPackageContexts(
  cwdValues: string[],
  gitByCwd: Map<string, GitInfo>
): Promise<Map<string, PackageSubcontext>> {
  const packageByCwd = new Map<string, PackageSubcontext>();

  await Promise.all(
    cwdValues.map(async (cwd) => {
      const git = gitByCwd.get(cwd);
      if (!git) {
        return;
      }

      const packageContext = await resolvePackageContext(cwd, git.worktreePath);
      if (packageContext) {
        packageByCwd.set(cwd, packageContext);
      }
    })
  );

  return packageByCwd;
}

export async function resolvePackageContext(cwd: string, worktreePath: string): Promise<PackageSubcontext | undefined> {
  const boundary = path.resolve(worktreePath);
  let directory = path.resolve(cwd);

  while (isWithinOrEqual(boundary, directory)) {
    const manifestPath = path.join(directory, "package.json");
    const packageContext = await readPackageContext(manifestPath, directory, boundary);
    if (packageContext) {
      return packageContext;
    }

    if (directory === boundary) {
      break;
    }

    const parent = path.dirname(directory);
    if (parent === directory) {
      break;
    }
    directory = parent;
  }

  return undefined;
}

async function readPackageContext(
  manifestPath: string,
  packagePath: string,
  worktreePath: string
): Promise<PackageSubcontext | undefined> {
  let manifest: string;
  try {
    manifest = await readFile(manifestPath, "utf8");
  } catch {
    return undefined;
  }

  const relativePath = path.relative(worktreePath, packagePath) || ".";
  const name = readPackageName(manifest);
  return {
    type: "package",
    ...(name ? { name } : {}),
    displayName: name || inferPackageDisplayName(packagePath, relativePath),
    path: packagePath,
    relativePath,
    manifestPath
  };
}

function readPackageName(manifest: string): string | undefined {
  try {
    const parsed = JSON.parse(manifest) as { name?: unknown };
    return typeof parsed.name === "string" && parsed.name.trim() ? parsed.name : undefined;
  } catch {
    return undefined;
  }
}

function inferPackageDisplayName(packagePath: string, relativePath: string): string {
  return path.basename(packagePath) || relativePath;
}

function isWithinOrEqual(basePath: string, targetPath: string): boolean {
  const relativePath = path.relative(basePath, targetPath);
  return relativePath === "" || (!relativePath.startsWith("..") && !path.isAbsolute(relativePath));
}

async function readGitInfo(cwd: string, warnings: string[]): Promise<GitInfo | undefined> {
  const repoRoot = await safeExeca("git", ["-C", cwd, "rev-parse", "--show-toplevel"], warnings, `read git root for ${cwd}`, {
    quiet: true
  });
  if (!repoRoot?.stdout.trim()) {
    return undefined;
  }

  const currentRoot = repoRoot.stdout.trim();
  const branch = await safeExeca("git", ["-C", cwd, "branch", "--show-current"], warnings, `read git branch for ${cwd}`, {
    quiet: true
  });
  const worktreeList = await safeExeca(
    "git",
    ["-C", cwd, "worktree", "list", "--porcelain"],
    warnings,
    `read git worktrees for ${cwd}`,
    { quiet: true }
  );

  const branchName = branch?.stdout.trim() || undefined;
  const metadata = resolveGitWorktreeMetadata(worktreeList?.stdout ?? "", currentRoot, cwd, branchName);
  const remote = await safeExeca("git", ["-C", cwd, "remote", "get-url", "origin"], warnings, `read git origin for ${cwd}`, {
    quiet: true
  });
  const remoteMetadata = resolveGitRemoteMetadata(remote?.stdout);
  return {
    ...metadata,
    branch: branchName,
    ...remoteMetadata
  };
}

async function discoverDockerPorts(warnings: string[]): Promise<DiscoveredDockerPort[]> {
  const dockerPs = await safeExeca("docker", ["ps", "--format", "{{json .}}"], warnings, "list Docker containers", {
    quiet: true
  });
  if (!dockerPs) {
    return [];
  }

  const containers = parseDockerPsJsonLines(dockerPs.stdout).filter((container) => container.ports.trim());
  if (containers.length === 0) {
    return [];
  }

  const inspect = await safeExeca(
    "docker",
    ["inspect", ...containers.map((container) => container.id)],
    warnings,
    "inspect Docker published ports",
    { quiet: true }
  );
  if (!inspect) {
    return [];
  }

  try {
    return parseDockerInspectPorts(JSON.parse(inspect.stdout));
  } catch {
    warnings.push("Could not parse Docker inspect output");
    return [];
  }
}

async function discoverDockerActivity(ports: DiscoveredDockerPort[]): Promise<Map<string, ServiceActivity>> {
  const containerIds = Array.from(new Set(ports.map((port) => port.containerId))).sort();
  if (containerIds.length === 0) {
    return new Map();
  }

  const warnings: string[] = [];
  const result = await safeExeca(
    "docker",
    ["stats", "--no-stream", "--format", "{{json .}}", ...containerIds],
    warnings,
    "inspect Docker activity",
    { quiet: true }
  );
  if (!result) {
    return new Map();
  }

  const parsed = parseDockerStatsJsonLines(result.stdout);
  const normalized = new Map<string, ServiceActivity>();
  for (const containerId of containerIds) {
    const activity = findDockerActivity(parsed, containerId);
    if (activity) {
      normalized.set(containerId, activity);
    }
  }
  return normalized;
}

function findDockerActivity(activityByContainerId: Map<string, ServiceActivity>, containerId: string): ServiceActivity | undefined {
  const exact = activityByContainerId.get(containerId);
  if (exact) {
    return exact;
  }

  for (const [candidateId, activity] of activityByContainerId) {
    if (containerId.startsWith(candidateId) || candidateId.startsWith(containerId)) {
      return activity;
    }
  }
  return undefined;
}

export function resolveGitWorktreeMetadata(
  worktreeOutput: string,
  currentRepoRoot: string,
  cwd: string,
  branch?: string
): Pick<GitInfo, "repoRoot" | "worktreePath" | "worktreeName"> {
  const worktrees = parseWorktreePaths(worktreeOutput);
  const repoRoot = worktrees[0] ?? currentRepoRoot;
  const worktreePath = resolveWorktreePath(worktrees, cwd, currentRepoRoot);

  return {
    repoRoot,
    worktreePath,
    worktreeName: inferWorktreeName(worktreePath, repoRoot, branch)
  };
}

function parseWorktreePaths(worktreeOutput: string): string[] {
  return worktreeOutput
    .split("\n")
    .filter((line) => line.startsWith("worktree "))
    .map((line) => line.slice("worktree ".length));
}

function resolveWorktreePath(worktrees: string[], cwd: string, currentRepoRoot: string): string {
  if (worktrees.length === 0) {
    return currentRepoRoot;
  }

  const matched = worktrees
    .filter((worktree) => cwd === worktree || cwd.startsWith(`${worktree}/`))
    .sort((left, right) => right.length - left.length)[0];

  return matched ?? currentRepoRoot;
}

function inferWorktreeName(worktreePath: string, repoRoot: string, branch?: string): string {
  if (worktreePath === repoRoot) {
    return branch || "main";
  }
  return branch || worktreePath.split("/").filter(Boolean).at(-1) || "worktree";
}

export function resolveGitRemoteMetadata(remoteUrl: string | undefined): Pick<GitInfo, "remoteUrl" | "repositoryUrl"> {
  const trimmedRemote = remoteUrl?.trim();
  if (!trimmedRemote) {
    return {};
  }

  const repositoryUrl = normalizeGitHubRepositoryUrl(trimmedRemote);
  if (!repositoryUrl) {
    return {};
  }

  return {
    ...(safeRemoteURLForOutput(trimmedRemote) ? { remoteUrl: trimmedRemote } : {}),
    repositoryUrl
  };
}

function safeRemoteURLForOutput(remoteUrl: string): string | undefined {
  if (/^git@github\.com:/i.test(remoteUrl)) {
    return remoteUrl;
  }

  try {
    const url = new URL(remoteUrl);
    if (url.password || (["http:", "https:"].includes(url.protocol.toLowerCase()) && url.username)) {
      return undefined;
    }
    return remoteUrl;
  } catch {
    return undefined;
  }
}

export function normalizeGitHubRepositoryUrl(remoteUrl: string): string | undefined {
  const trimmedRemote = remoteUrl.trim();
  if (!trimmedRemote) {
    return undefined;
  }

  const scpMatch = /^git@github\.com:([^/\s]+)\/([^/\s]+?)(?:\.git)?$/i.exec(trimmedRemote);
  if (scpMatch?.[1] && scpMatch[2]) {
    return buildGitHubRepositoryUrl(scpMatch[1], scpMatch[2]);
  }

  try {
    const url = new URL(trimmedRemote);
    const protocol = url.protocol.toLowerCase();
    if (!["http:", "https:", "ssh:"].includes(protocol) || url.hostname.toLowerCase() !== "github.com") {
      return undefined;
    }
    if (protocol === "ssh:" && url.username !== "git") {
      return undefined;
    }

    const pathParts = url.pathname.split("/").filter(Boolean);
    if (pathParts.length !== 2) {
      return undefined;
    }

    return buildGitHubRepositoryUrl(pathParts[0]!, pathParts[1]!);
  } catch {
    return undefined;
  }
}

function buildGitHubRepositoryUrl(owner: string, rawRepo: string): string | undefined {
  const normalizedOwner = owner.trim();
  const normalizedRepo = rawRepo.trim().replace(/\.git$/i, "");
  if (!isSafeGitHubPathSegment(normalizedOwner) || !isSafeGitHubPathSegment(normalizedRepo)) {
    return undefined;
  }

  return `https://github.com/${normalizedOwner}/${normalizedRepo}`;
}

function isSafeGitHubPathSegment(segment: string): boolean {
  return /^[A-Za-z0-9_.-]+$/.test(segment) && segment !== "." && segment !== "..";
}

async function safeExeca(
  command: string,
  args: string[],
  warnings: string[],
  label: string,
  options: { quiet?: boolean } = {}
): Promise<{ stdout: string } | undefined> {
  try {
    return await execa(command, args, { reject: true });
  } catch (error) {
    if (!options.quiet) {
      warnings.push(`${label} failed: ${formatCommandError(error)}`);
    }
    return undefined;
  }
}

function formatCommandError(error: unknown): string {
  if (error instanceof Error) {
    return error.message.split("\n")[0] ?? error.message;
  }
  return String(error);
}
