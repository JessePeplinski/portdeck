import http from "node:http";
import https from "node:https";
import type { EndpointHealth } from "./types.js";

const DEFAULT_ENDPOINT_PROBE_TIMEOUT_MS = 1_200;

export async function probeHttpEndpoints(urls: string[], timeoutMs = DEFAULT_ENDPOINT_PROBE_TIMEOUT_MS): Promise<Map<string, EndpointHealth>> {
  const uniqueUrls = Array.from(new Set(urls));
  const results = await Promise.all(uniqueUrls.map((url) => probeHttpEndpoint(url, timeoutMs)));
  return new Map(results.map((health) => [health.url, health]));
}

async function probeHttpEndpoint(url: string, timeoutMs: number): Promise<EndpointHealth> {
  const startedAt = Date.now();
  let parsed: URL;

  try {
    parsed = new URL(url);
  } catch (error) {
    return {
      url,
      status: "unreachable",
      latencyMs: elapsedMs(startedAt),
      error: error instanceof Error ? error.message : "Invalid URL"
    };
  }

  const transport = parsed.protocol === "https:" ? https : http;

  return new Promise<EndpointHealth>((resolve) => {
    let settled = false;
    let deadline: ReturnType<typeof setTimeout> | undefined;
    const settle = (health: EndpointHealth) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(deadline);
      request.destroy();
      resolve(health);
    };

    const request = transport.request(parsed, { method: "GET", timeout: timeoutMs }, (response) => {
      const statusCode = response.statusCode ?? 0;
      const status = statusCode >= 200 && statusCode < 400 ? "ok" : "http-error";
      const remoteAddress = response.socket.remoteAddress;
      settle({
        url,
        status,
        statusCode,
        ...(remoteAddress ? { remoteAddress } : {}),
        latencyMs: elapsedMs(startedAt)
      });
      // Health uses headers only. Draining a large or streaming body keeps
      // sockets and the discovery helper alive after the result is complete.
      response.destroy();
    });

    const timeout = () => {
      settle({
        url,
        status: "timeout",
        latencyMs: elapsedMs(startedAt),
        error: `Timed out after ${timeoutMs}ms`
      });
    };
    request.on("timeout", timeout);
    // Socket timeouts measure inactivity; trickled headers reset them forever.
    deadline = setTimeout(timeout, timeoutMs);

    request.on("error", (error) => {
      settle({
        url,
        status: "unreachable",
        latencyMs: elapsedMs(startedAt),
        error: error.message
      });
    });

    request.end();
  });
}

function elapsedMs(startedAt: number): number {
  return Math.max(0, Date.now() - startedAt);
}

// Scheme detection is separate from health: development certificates need not
// be trusted by Node, and no response body or redirect is followed.
export async function detectHttpsEndpoints(urls: string[], timeoutMs = 500): Promise<Set<string>> {
  const pending = Array.from(new Set(urls));
  const detected = new Set<string>();
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(8, pending.length) }, async () => {
    while (next < pending.length) {
      const url = pending[next++]!;
      if (await acceptsHttps(url, timeoutMs)) detected.add(url);
    }
  }));
  return detected;
}

async function acceptsHttps(url: string, timeoutMs: number): Promise<boolean> {
  const endpoint = new URL(url);
  const port = endpoint.port || "80";
  endpoint.protocol = "https:";
  endpoint.port = port;
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result: boolean) => {
      if (settled) return;
      settled = true;
      clearTimeout(deadline);
      request.destroy();
      resolve(result);
    };
    const request = https.request(endpoint, {
      method: "HEAD",
      rejectUnauthorized: false,
      agent: false
    }, (response) => {
      finish(true);
      response.destroy();
    });
    const deadline = setTimeout(() => finish(false), timeoutMs);
    request.on("error", () => finish(false));
    request.end();
  });
}
