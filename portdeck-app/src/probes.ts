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
    const settle = (health: EndpointHealth) => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(health);
    };

    const request = transport.request(parsed, { method: "GET", timeout: timeoutMs }, (response) => {
      const statusCode = response.statusCode ?? 0;
      const status = statusCode >= 200 && statusCode < 400 ? "ok" : "http-error";
      const remoteAddress = response.socket.remoteAddress;
      response.resume();
      settle({
        url,
        status,
        statusCode,
        ...(remoteAddress ? { remoteAddress } : {}),
        latencyMs: elapsedMs(startedAt)
      });
    });

    request.on("timeout", () => {
      settle({
        url,
        status: "timeout",
        latencyMs: elapsedMs(startedAt),
        error: `Timed out after ${timeoutMs}ms`
      });
      request.destroy();
    });

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
