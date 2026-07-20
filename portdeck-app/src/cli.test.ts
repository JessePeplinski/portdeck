import { describe, expect, test } from "vitest";
import { runPortdeckCli } from "./cli.js";
import type { PortdeckStatus } from "./types.js";

describe("runPortdeckCli", () => {
  test("prints status JSON", async () => {
    const stdout = new TestWriter();
    const code = await runPortdeckCli(["status", "--json"], {
      stdout,
      getStatus: async () => makeEmptyStatus()
    });

    expect(code).toBe(0);
    expect(JSON.parse(stdout.text())).toEqual(makeEmptyStatus());
  });

  test("prints stop success JSON and exits zero", async () => {
    const stdout = new TestWriter();
    const code = await runPortdeckCli(["stop", "--service-id", "pid-123-port-3000", "--json"], {
      stdout,
      stopService: async (serviceId) => ({
        ok: true,
        serviceId,
        action: "stop",
        message: "Stopped node on :3000"
      })
    });

    expect(code).toBe(0);
    expect(JSON.parse(stdout.text())).toEqual({
      ok: true,
      serviceId: "pid-123-port-3000",
      action: "stop",
      message: "Stopped node on :3000"
    });
  });

  test("prints stop failure JSON and exits nonzero", async () => {
    const stdout = new TestWriter();
    const code = await runPortdeckCli(["stop", "--service-id", "missing-service", "--json"], {
      stdout,
      stopService: async (serviceId) => ({
        ok: false,
        serviceId,
        action: "stop",
        message: "Service not found"
      })
    });

    expect(code).toBe(1);
    expect(JSON.parse(stdout.text())).toEqual({
      ok: false,
      serviceId: "missing-service",
      action: "stop",
      message: "Service not found"
    });
  });

  test("prints project suggestions and saves a confirmed project", async () => {
    const suggestions = new TestWriter();
    const suggestionCode = await runPortdeckCli(["projects", "suggest", "--path", "/repo/demo", "--json"], {
      stdout: suggestions,
      suggestProjects: async (projectPath) => ({
        path: projectPath,
        name: "Demo",
        suggestions: [{ id: "dev", title: "Development", detail: "npm dev", command: "npm run dev", source: "package" }]
      })
    });
    expect(suggestionCode).toBe(0);
    expect(JSON.parse(suggestions.text())).toEqual(expect.objectContaining({ path: "/repo/demo", name: "Demo" }));

    const saved = new TestWriter();
    const input = { name: "Demo", path: "/repo/demo", command: "npm run dev" };
    const saveCode = await runPortdeckCli(["projects", "save", "--input", JSON.stringify(input), "--json"], {
      stdout: saved,
      saveProject: async () => ({ id: "demo-id", ...input })
    });
    expect(saveCode).toBe(0);
    expect(JSON.parse(saved.text())).toEqual({ ok: true, project: { id: "demo-id", ...input } });
  });

  test("resolves only requested running services for project suggestions", async () => {
    const stdout = new TestWriter();
    const status = makeEmptyStatus();
    status.groups = [{
      projectName: "demo",
      repoRoot: "/repo/demo",
      worktrees: [{
        name: "main",
        path: "/repo/demo",
        services: [{
          id: "selected-service",
          name: "web",
          source: "process",
          status: "running",
          command: "npm run dev",
          cwd: "/repo/demo",
          confidence: "high"
        }, {
          id: "other-service",
          name: "api",
          source: "process",
          status: "running",
          command: "npm run start",
          cwd: "/repo/other",
          confidence: "high"
        }]
      }]
    }];
    let receivedServiceIDs: string[] = [];

    const code = await runPortdeckCli([
      "projects", "suggest", "--path", "/repo/demo",
      "--service-id", "selected-service", "--service-id", "missing-service", "--json"
    ], {
      stdout,
      getStatus: async () => status,
      suggestProjects: async (projectPath, observedServices = []) => {
        receivedServiceIDs = observedServices.map((service) => service.id);
        return { path: projectPath, name: "Demo", suggestions: [] };
      }
    });

    expect(code).toBe(0);
    expect(receivedServiceIDs).toEqual(["selected-service"]);
  });

  test("dispatches project run actions and preserves structured failures", async () => {
    const stdout = new TestWriter();
    const code = await runPortdeckCli(["run", "start", "--project-id", "demo", "--port", "3000", "--json"], {
      stdout,
      startProject: async (projectId, port) => ({
        ok: false,
        projectId,
        action: "start",
        message: `Port ${port} is already in use.`,
        port,
        suggestedPort: 3001
      })
    });
    expect(code).toBe(1);
    expect(JSON.parse(stdout.text())).toEqual(expect.objectContaining({ suggestedPort: 3001 }));
  });
});

class TestWriter {
  private chunks: string[] = [];

  write(chunk: string): true {
    this.chunks.push(chunk);
    return true;
  }

  text(): string {
    return this.chunks.join("");
  }
}

function makeEmptyStatus(): PortdeckStatus {
  return {
    schemaVersion: "0.1",
    generatedAt: "2026-06-09T00:00:00.000Z",
    groups: [],
    unknown: [],
    warnings: []
  };
}
