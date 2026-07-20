import path from "node:path";
import type {
  DiscoveredDockerPort,
  DiscoveredProcessPort,
  DockerMount,
  DockerContainerSummary,
  ProcessInfo,
  ServiceActivity
} from "./types.js";

export function parseLsofListenOutput(output: string): DiscoveredProcessPort[] {
  if (output.split("\n").some((line) => /^p\d+$/.test(line.trim()))) {
    return parseLsofFieldOutput(output);
  }

  return parseLsofColumnOutput(output);
}

function parseLsofColumnOutput(output: string): DiscoveredProcessPort[] {
  const rows: DiscoveredProcessPort[] = [];
  const seen = new Set<string>();

  for (const line of output.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("COMMAND")) {
      continue;
    }

    const columns = trimmed.match(/^(\S+)\s+(\d+)\s+.*\s+TCP\s+(.+?)\s+\(LISTEN\)$/);
    if (!columns) {
      continue;
    }

    const [, processName, pidValue, endpoint] = columns;
    const endpointMatch = endpoint.match(/^(?:\[([^\]]+)\]|([^:]+)):(\d+)$/);
    if (!endpointMatch) {
      continue;
    }

    const port = Number(endpointMatch[3]);
    if (!Number.isInteger(port)) {
      continue;
    }

    const row = {
      pid: Number(pidValue),
      processName,
      port,
      protocol: "TCP",
      address: endpointMatch[1] ?? endpointMatch[2] ?? "localhost"
    } satisfies DiscoveredProcessPort;

    const key = `${row.pid}:${row.port}:${row.protocol}:${row.address}`;
    if (seen.has(key)) {
      continue;
    }

    seen.add(key);
    rows.push(row);
  }

  return rows;
}

function parseLsofFieldOutput(output: string): DiscoveredProcessPort[] {
  const rows: DiscoveredProcessPort[] = [];
  const seen = new Set<string>();
  let currentPid: number | undefined;
  let currentProcessName = "";
  let currentFile: { protocol?: string; endpoint?: string; state?: string } = {};

  const flushFile = () => {
    if (
      currentPid === undefined ||
      !currentProcessName ||
      !currentFile.endpoint ||
      currentFile.protocol !== "TCP" ||
      (currentFile.state && currentFile.state !== "LISTEN")
    ) {
      currentFile = {};
      return;
    }

    const endpoint = parseEndpoint(currentFile.endpoint);
    if (!endpoint) {
      currentFile = {};
      return;
    }

    const row = {
      pid: currentPid,
      processName: currentProcessName,
      port: endpoint.port,
      protocol: "TCP",
      address: endpoint.address
    } satisfies DiscoveredProcessPort;

    const key = `${row.pid}:${row.port}:${row.protocol}:${row.address}`;
    if (!seen.has(key)) {
      seen.add(key);
      rows.push(row);
    }

    currentFile = {};
  };

  for (const line of output.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }

    const tag = trimmed[0];
    const value = trimmed.slice(1);

    if (tag === "p") {
      flushFile();
      const pid = Number(value);
      currentPid = Number.isInteger(pid) ? pid : undefined;
      currentProcessName = "";
      continue;
    }

    if (tag === "c") {
      currentProcessName = value;
      continue;
    }

    if (tag === "f") {
      flushFile();
      continue;
    }

    if (tag === "P") {
      currentFile.protocol = value.toUpperCase();
      continue;
    }

    if (tag === "n") {
      currentFile.endpoint = value;
      continue;
    }

    if (tag === "T" && value.startsWith("ST=")) {
      currentFile.state = value.slice("ST=".length);
    }
  }

  flushFile();
  return rows;
}

function parseEndpoint(endpoint: string): { address: string; port: number } | undefined {
  const match = endpoint.match(/^(?:\[([^\]]+)\]|(.+)):(\d+)$/);
  if (!match) {
    return undefined;
  }

  const port = Number(match[3]);
  if (!Number.isInteger(port)) {
    return undefined;
  }

  return {
    address: match[1] ?? match[2] ?? "localhost",
    port
  };
}

export function parsePsOutput(output: string): Map<number, ProcessInfo> {
  const processes = new Map<number, ProcessInfo>();

  for (const line of output.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || /^PID\s+/.test(trimmed)) {
      continue;
    }

    const columns = trimmed.match(/^(\d+)\s+(.+)$/);
    if (!columns) {
      continue;
    }

    const [, pidValue, command] = columns;
    const pid = Number(pidValue);
    if (!Number.isInteger(pid)) {
      continue;
    }

    const normalizedCommand = command.trim();
    processes.set(pid, {
      pid,
      processName: inferExecutableName(normalizedCommand),
      command: normalizedCommand
    });
  }

  return processes;
}

export function parsePsActivityOutput(output: string): Map<number, ServiceActivity> {
  const activity = new Map<number, ServiceActivity>();

  for (const line of output.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || /^PID\s+/i.test(trimmed)) {
      continue;
    }

    const columns = trimmed.match(/^(\d+)\s+([0-9]+(?:\.[0-9]+)?)\s+(\d+)$/);
    if (!columns) {
      continue;
    }

    const pid = Number(columns[1]);
    const cpuPercent = Number(columns[2]);
    const rssKilobytes = Number(columns[3]);
    if (!Number.isInteger(pid) || !Number.isFinite(cpuPercent) || !Number.isFinite(rssKilobytes)) {
      continue;
    }

    activity.set(pid, {
      cpuPercent,
      memoryRssBytes: rssKilobytes * 1024
    });
  }

  return activity;
}

function inferExecutableName(command: string): string {
  const executable = command.match(/^"([^"]+)"|'([^']+)'|(\S+)/)?.slice(1).find(Boolean) ?? command;
  return path.basename(executable) || executable;
}

export function parseDockerPsJsonLines(output: string): DockerContainerSummary[] {
  const containers: DockerContainerSummary[] = [];

  for (const line of output.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }

    try {
      const parsed = JSON.parse(trimmed) as Record<string, unknown>;
      containers.push({
        id: String(parsed.ID ?? parsed.Id ?? ""),
        name: String(parsed.Names ?? parsed.Name ?? ""),
        image: String(parsed.Image ?? ""),
        ports: String(parsed.Ports ?? "")
      });
    } catch {
      continue;
    }
  }

  return containers.filter((container) => container.id && container.name);
}

export function parseDockerStatsJsonLines(output: string): Map<string, ServiceActivity> {
  const activity = new Map<string, ServiceActivity>();

  for (const line of output.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }

    try {
      const parsed = JSON.parse(trimmed) as Record<string, unknown>;
      const id = String(parsed.ID ?? parsed.Container ?? "");
      const cpuPercent = parsePercent(String(parsed.CPUPerc ?? ""));
      const memory = parseDockerMemoryUsage(String(parsed.MemUsage ?? ""));
      if (!id || cpuPercent === undefined || !memory) {
        continue;
      }

      activity.set(id, {
        cpuPercent,
        memoryUsageBytes: memory.usageBytes,
        memoryLimitBytes: memory.limitBytes
      });
    } catch {
      continue;
    }
  }

  return activity;
}

function parsePercent(value: string): number | undefined {
  const match = value.trim().match(/^([0-9]+(?:\.[0-9]+)?)%$/);
  if (!match) {
    return undefined;
  }

  const percent = Number(match[1]);
  return Number.isFinite(percent) ? percent : undefined;
}

function parseDockerMemoryUsage(value: string): { usageBytes: number; limitBytes: number } | undefined {
  const [usage, limit] = value.split("/").map((part) => part.trim());
  const usageBytes = parseDockerBytes(usage ?? "");
  const limitBytes = parseDockerBytes(limit ?? "");
  if (usageBytes === undefined || limitBytes === undefined) {
    return undefined;
  }

  return { usageBytes, limitBytes };
}

function parseDockerBytes(value: string): number | undefined {
  const match = value.trim().match(/^([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?i?B|[kKmMgGtT]?B)$/);
  if (!match) {
    return undefined;
  }

  const amount = Number(match[1]);
  const unit = match[2];
  if (!Number.isFinite(amount)) {
    return undefined;
  }

  const multiplier = dockerByteMultiplier(unit);
  return multiplier === undefined ? undefined : Math.round(amount * multiplier);
}

function dockerByteMultiplier(unit: string): number | undefined {
  switch (unit) {
    case "B":
      return 1;
    case "KiB":
      return 1024;
    case "MiB":
      return 1024 ** 2;
    case "GiB":
      return 1024 ** 3;
    case "TiB":
      return 1024 ** 4;
    case "kB":
    case "KB":
      return 1000;
    case "MB":
      return 1000 ** 2;
    case "GB":
      return 1000 ** 3;
    case "TB":
      return 1000 ** 4;
    default:
      return undefined;
  }
}

export function parseDockerInspectPorts(inspect: unknown): DiscoveredDockerPort[] {
  if (!Array.isArray(inspect)) {
    return [];
  }

  const ports: DiscoveredDockerPort[] = [];
  const seen = new Set<string>();

  for (const container of inspect) {
    if (!isRecord(container)) {
      continue;
    }

    const id = String(container.Id ?? "");
    const rawName = String(container.Name ?? "");
    const config = isRecord(container.Config) ? container.Config : {};
    const image = String(config.Image ?? "");
    const labels = normalizeStringRecord(config.Labels);
    const composeProjectWorkingDir = nonEmptyString(labels["com.docker.compose.project.working_dir"]);
    const composeConfigFiles = parseComposeConfigFiles(labels["com.docker.compose.project.config_files"]);
    const containerWorkingDir = nonEmptyString(config.WorkingDir);
    const mounts = parseDockerMounts(container.Mounts);
    const networkSettings = isRecord(container.NetworkSettings) ? container.NetworkSettings : {};
    const portMap = isRecord(networkSettings.Ports) ? networkSettings.Ports : {};

    for (const [containerPortKey, bindings] of Object.entries(portMap)) {
      if (!Array.isArray(bindings)) {
        continue;
      }

      const portKeyMatch = containerPortKey.match(/^(\d+)\/(\w+)$/);
      if (!portKeyMatch) {
        continue;
      }

      for (const binding of bindings) {
        if (!isRecord(binding)) {
          continue;
        }

        const hostPort = Number(binding.HostPort);
        if (!Number.isInteger(hostPort)) {
          continue;
        }

        const port = {
          containerId: id,
          containerName: rawName.replace(/^\//, ""),
          image,
          hostIp: String(binding.HostIp ?? "0.0.0.0"),
          hostPort,
          containerPort: Number(portKeyMatch[1]),
          protocol: portKeyMatch[2],
          labels,
          ...(composeProjectWorkingDir ? { composeProjectWorkingDir } : {}),
          ...(composeConfigFiles.length > 0 ? { composeConfigFiles } : {}),
          ...(containerWorkingDir ? { containerWorkingDir } : {}),
          ...(mounts.length > 0 ? { mounts } : {})
        } satisfies DiscoveredDockerPort;

        const key = `${port.containerId}:${port.hostIp}:${port.hostPort}:${port.containerPort}:${port.protocol}`;
        if (seen.has(key)) {
          continue;
        }

        seen.add(key);
        ports.push(port);
      }
    }
  }

  return ports;
}

function parseComposeConfigFiles(value: string | undefined): string[] {
  if (!value) {
    return [];
  }

  return value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
}

function parseDockerMounts(value: unknown): DockerMount[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.flatMap((item) => {
    if (!isRecord(item)) {
      return [];
    }

    const source = nonEmptyString(item.Source);
    const destination = nonEmptyString(item.Destination);
    if (!source || !destination) {
      return [];
    }

    return [
      {
        ...(nonEmptyString(item.Type) ? { type: nonEmptyString(item.Type) } : {}),
        source,
        destination,
        ...(nonEmptyString(item.Mode) ? { mode: nonEmptyString(item.Mode) } : {}),
        ...(typeof item.RW === "boolean" ? { rw: item.RW } : {})
      }
    ];
  });
}

function nonEmptyString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizeStringRecord(value: unknown): Record<string, string> {
  if (!isRecord(value)) {
    return {};
  }

  return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, String(item)]));
}
