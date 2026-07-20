import { describe, expect, test } from "vitest";
import { discoverNgrokExposures } from "./ngrok.js";

describe("discoverNgrokExposures", () => {
  test("returns no exposures when the ngrok agent API is unavailable", async () => {
    const warnings: string[] = [];

    await expect(
      discoverNgrokExposures({
        warnings,
        fetchText: async () => undefined
      })
    ).resolves.toEqual([]);
    expect(warnings).toEqual([]);
  });

  test("normalizes tunnel targets and carries agent provenance", async () => {
    const warnings: string[] = [];

    const exposures = await discoverNgrokExposures({
      warnings,
      agentApiUrl: "http://127.0.0.1:4040/api/tunnels",
      agentPid: 4321,
      agentCwd: "/repo/acme-web",
      fetchText: async () => ({
        status: 200,
        body: JSON.stringify({
          tunnels: [
            {
              name: "command_line",
              public_url: "https://demo.ngrok.app",
              proto: "https",
              config: {
                addr: "localhost:3000"
              }
            },
            {
              name: "ipv6",
              public_url: "https://ipv6.ngrok.app",
              proto: "https",
              config: {
                addr: "http://[::1]:5173"
              }
            }
          ]
        })
      })
    });

    expect(exposures).toEqual([
      {
        id: "ngrok-demo-ngrok-app",
        kind: "ngrok",
        publicUrl: "https://demo.ngrok.app",
        targetUrl: "http://localhost:3000",
        targetHost: "localhost",
        targetPort: 3000,
        agentApiUrl: "http://127.0.0.1:4040/api/tunnels",
        agentPid: 4321,
        agentCwd: "/repo/acme-web",
        status: "unknown"
      },
      {
        id: "ngrok-ipv6-ngrok-app",
        kind: "ngrok",
        publicUrl: "https://ipv6.ngrok.app",
        targetUrl: "http://[::1]:5173",
        targetHost: "::1",
        targetPort: 5173,
        agentApiUrl: "http://127.0.0.1:4040/api/tunnels",
        agentPid: 4321,
        agentCwd: "/repo/acme-web",
        status: "unknown"
      }
    ]);
    expect(warnings).toEqual([]);
  });

  test("warns and skips malformed tunnel API responses", async () => {
    const warnings: string[] = [];

    const exposures = await discoverNgrokExposures({
      warnings,
      fetchText: async () => ({
        status: 200,
        body: JSON.stringify({ tunnels: "nope" })
      })
    });

    expect(exposures).toEqual([]);
    expect(warnings).toEqual(["Could not parse ngrok tunnels from http://127.0.0.1:4040/api/tunnels"]);
  });
});
