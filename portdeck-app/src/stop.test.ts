import { describe, expect, test } from "vitest";
import { stopServiceById } from "./stop.js";
import type { PortdeckService, PortdeckStatus } from "./types.js";

describe("stopServiceById", () => {
  test("sends SIGTERM to a process service pid", async () => {
    const signals: Array<{ pid: number; signal: NodeJS.Signals }> = [];
    const service = makeProcessService({ id: "pid-123-port-3000", pid: 123, port: 3000, processName: "node" });

    const result = await stopServiceById("pid-123-port-3000", {
      getStatus: async () => makeStatus([service]),
      sendSignal: async (pid, signal) => {
        signals.push({ pid, signal });
      }
    });

    expect(signals).toEqual([{ pid: 123, signal: "SIGTERM" }]);
    expect(result).toEqual({
      ok: true,
      serviceId: "pid-123-port-3000",
      action: "stop",
      message: "Stopped node on :3000"
    });
  });

  test("stops a Docker service by container id", async () => {
    const containers: string[] = [];
    const service = makeDockerService({
      id: "docker-abc123-port-5432",
      containerId: "abc123",
      containerName: "portdeck-db-1",
      port: 5432
    });

    const result = await stopServiceById("docker-abc123-port-5432", {
      getStatus: async () => makeStatus([service]),
      stopDockerContainer: async (containerId) => {
        containers.push(containerId);
      }
    });

    expect(containers).toEqual(["abc123"]);
    expect(result).toEqual({
      ok: true,
      serviceId: "docker-abc123-port-5432",
      action: "stop",
      message: "Stopped portdeck-db-1 on :5432"
    });
  });

  test("fails cleanly when the service is missing", async () => {
    const result = await stopServiceById("missing-service", {
      getStatus: async () => makeStatus([])
    });

    expect(result).toEqual({
      ok: false,
      serviceId: "missing-service",
      action: "stop",
      message: "Service not found"
    });
  });

  test("fails cleanly when a process service has no pid", async () => {
    const service = makeProcessService({ id: "pid-missing-port-3000", pid: undefined, port: 3000 });

    const result = await stopServiceById("pid-missing-port-3000", {
      getStatus: async () => makeStatus([service])
    });

    expect(result.ok).toBe(false);
    expect(result.message).toBe("Service owner unavailable");
  });

  test("fails cleanly when a Docker service has no container id", async () => {
    const service = makeDockerService({ id: "docker-missing-port-5432", containerId: undefined, port: 5432 });

    const result = await stopServiceById("docker-missing-port-5432", {
      getStatus: async () => makeStatus([service])
    });

    expect(result.ok).toBe(false);
    expect(result.message).toBe("Service owner unavailable");
  });

  test("fails quietly when Docker stop is unavailable", async () => {
    const service = makeDockerService({ id: "docker-abc123-port-5432", containerId: "abc123", port: 5432 });

    const result = await stopServiceById("docker-abc123-port-5432", {
      getStatus: async () => makeStatus([service]),
      stopDockerContainer: async () => {
        throw new Error("Cannot connect to the Docker daemon at unix:///var/run/docker.sock");
      }
    });

    expect(result).toEqual({
      ok: false,
      serviceId: "docker-abc123-port-5432",
      action: "stop",
      message: "Docker unavailable"
    });
  });

  test("does not stop stale services", async () => {
    const service = makeProcessService({ id: "pid-123-port-3000", pid: 123, port: 3000, status: "stale" });
    const signals: number[] = [];

    const result = await stopServiceById("pid-123-port-3000", {
      getStatus: async () => makeStatus([service]),
      sendSignal: async (pid) => {
        signals.push(pid);
      }
    });

    expect(signals).toEqual([]);
    expect(result.ok).toBe(false);
    expect(result.message).toBe("Service is not running");
  });
});

function makeStatus(services: PortdeckService[]): PortdeckStatus {
  return {
    schemaVersion: "0.1",
    generatedAt: "2026-06-09T00:00:00.000Z",
    groups: [
      {
        projectName: "portdeck",
        repoRoot: "/repo/portdeck",
        worktrees: [
          {
            name: "main",
            path: "/repo/portdeck",
            branch: "main",
            services
          }
        ]
      }
    ],
    unknown: [],
    warnings: []
  };
}

function makeProcessService(overrides: Partial<PortdeckService>): PortdeckService {
  return {
    id: "pid-123-port-3000",
    name: "web",
    source: "process",
    status: "running",
    port: 3000,
    url: "http://localhost:3000",
    address: "127.0.0.1",
    protocol: "TCP",
    pid: 123,
    processName: "node",
    command: "npm run dev",
    cwd: "/repo/portdeck",
    confidence: "high",
    ...overrides
  };
}

function makeDockerService(overrides: Partial<PortdeckService>): PortdeckService {
  return {
    id: "docker-abc123-port-5432",
    name: "db",
    source: "docker",
    status: "running",
    port: 5432,
    url: "http://localhost:5432",
    hostIp: "127.0.0.1",
    protocol: "tcp",
    containerName: "portdeck-db-1",
    containerId: "abc123",
    containerPort: 5432,
    image: "postgres:16",
    confidence: "medium",
    ...overrides
  };
}
