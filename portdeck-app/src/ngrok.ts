import type { DiscoveredProcessPort, PortdeckExposure, ProcessInfo } from "./types.js";

const DEFAULT_NGROK_AGENT_API_URL = "http://127.0.0.1:4040/api/tunnels";

type FetchTextResult = {
  status: number;
  body: string;
};

export type NgrokDiscoveryOptions = {
  agentApiUrl?: string;
  agentPid?: number;
  agentCwd?: string;
  processPorts?: DiscoveredProcessPort[];
  processes?: Map<number, ProcessInfo>;
  warnings: string[];
  fetchText?: (url: string) => Promise<FetchTextResult | undefined>;
};

type RawNgrokTunnel = {
  name?: unknown;
  public_url?: unknown;
  proto?: unknown;
  config?: {
    addr?: unknown;
  };
};

type NormalizedTarget = {
  targetUrl: string;
  targetHost?: string;
  targetPort?: number;
};

export async function discoverNgrokExposures(options: NgrokDiscoveryOptions): Promise<PortdeckExposure[]> {
  const agentApiUrl = options.agentApiUrl ?? DEFAULT_NGROK_AGENT_API_URL;
  const agent = inferNgrokAgent(options.processPorts ?? [], options.processes ?? new Map());
  const agentPid = options.agentPid ?? agent?.pid;
  const agentCwd = options.agentCwd ?? agent?.cwd;
  const fetchText = options.fetchText ?? fetchTextFromAgent;
  const result = await fetchText(agentApiUrl);
  if (!result || result.status < 200 || result.status >= 300) {
    return [];
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(result.body);
  } catch {
    options.warnings.push(`Could not parse ngrok tunnels from ${agentApiUrl}`);
    return [];
  }

  if (!isRecord(parsed) || !Array.isArray(parsed.tunnels)) {
    options.warnings.push(`Could not parse ngrok tunnels from ${agentApiUrl}`);
    return [];
  }

  return parsed.tunnels.flatMap((item) => normalizeNgrokTunnel(item, agentApiUrl, agentPid, agentCwd));
}

function normalizeNgrokTunnel(
  value: unknown,
  agentApiUrl: string,
  agentPid: number | undefined,
  agentCwd: string | undefined
): PortdeckExposure[] {
  if (!isRecord(value)) {
    return [];
  }

  const tunnel = value as RawNgrokTunnel;
  const publicUrl = typeof tunnel.public_url === "string" ? tunnel.public_url.trim() : "";
  const rawTarget = typeof tunnel.config?.addr === "string" ? tunnel.config.addr.trim() : "";
  if (!publicUrl || !rawTarget) {
    return [];
  }

  const normalizedTarget = normalizeTarget(rawTarget);
  return [
    {
      id: buildExposureId(publicUrl),
      kind: "ngrok",
      publicUrl,
      targetUrl: normalizedTarget.targetUrl,
      ...(normalizedTarget.targetHost ? { targetHost: normalizedTarget.targetHost } : {}),
      ...(normalizedTarget.targetPort !== undefined ? { targetPort: normalizedTarget.targetPort } : {}),
      agentApiUrl,
      ...(agentPid !== undefined ? { agentPid } : {}),
      ...(agentCwd ? { agentCwd } : {}),
      status: "unknown"
    }
  ];
}

function normalizeTarget(rawTarget: string): NormalizedTarget {
  const target = rawTarget.trim();
  if (/^\d+$/.test(target)) {
    const targetPort = Number(target);
    return {
      targetUrl: `http://localhost:${targetPort}`,
      targetHost: "localhost",
      targetPort
    };
  }

  const candidates = target.includes("://") ? [target] : [`http://${target}`];
  for (const candidate of candidates) {
    try {
      const url = new URL(candidate);
      const targetPort = Number(url.port);
      return {
        targetUrl: formatTargetUrl(url),
        targetHost: normalizeTargetHost(url.hostname),
        ...(Number.isInteger(targetPort) ? { targetPort } : {})
      };
    } catch {
      continue;
    }
  }

  return {
    targetUrl: target
  };
}

function formatTargetUrl(url: URL): string {
  const protocol = url.protocol || "http:";
  const host = formatTargetHost(url.hostname);
  return `${protocol}//${host}${url.port ? `:${url.port}` : ""}`;
}

function normalizeTargetHost(hostname: string): string {
  const trimmed = hostname.trim();
  if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
    return trimmed.slice(1, -1).toLowerCase();
  }
  return trimmed.toLowerCase();
}

function formatTargetHost(hostname: string): string {
  const normalized = normalizeTargetHost(hostname);
  if (normalized.includes(":")) {
    return `[${normalized}]`;
  }
  return normalized;
}

function buildExposureId(publicUrl: string): string {
  const withoutScheme = publicUrl.replace(/^[a-z]+:\/\//i, "");
  const host = withoutScheme.split("/")[0] ?? withoutScheme;
  const sanitized = host.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  return `ngrok-${sanitized || "tunnel"}`;
}

function inferNgrokAgent(
  processPorts: DiscoveredProcessPort[],
  processes: Map<number, ProcessInfo>
): { pid: number; cwd?: string } | undefined {
  const matches = processPorts
    .filter((port) => port.port === 4040)
    .map((port) => ({ port, process: processes.get(port.pid) }))
    .filter(({ port, process }) => isNgrokProcess(process, port.processName))
    .sort((left, right) => left.port.pid - right.port.pid);

  const match = matches[0];
  return match
    ? {
        pid: match.port.pid,
        ...(match.process?.cwd ? { cwd: match.process.cwd } : {})
      }
    : undefined;
}

export function isNgrokProcess(process: { processName?: string; command?: string } | undefined, fallbackName = ""): boolean {
  const processName = (process?.processName ?? fallbackName).toLowerCase();
  const command = process?.command?.toLowerCase() ?? "";
  return processName === "ngrok" || /(^|\s|\/)ngrok(\s|$)/.test(command);
}

async function fetchTextFromAgent(url: string): Promise<FetchTextResult | undefined> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 350);
  try {
    const response = await fetch(url, { signal: controller.signal });
    return {
      status: response.status,
      body: await response.text()
    };
  } catch {
    return undefined;
  } finally {
    clearTimeout(timeout);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value));
}
