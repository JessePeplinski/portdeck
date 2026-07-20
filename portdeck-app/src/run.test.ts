import { mkdtemp, mkdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, test, vi } from "vitest";
import { loadRunState, loadSavedProjects, saveProject } from "./projects.js";
import { findNextAvailablePort, restartSavedProject, startSavedProject, stopSavedProject } from "./run.js";

const temporaryRoots: string[] = [];

afterEach(async () => {
  const { rm } = await import("node:fs/promises");
  await Promise.all(temporaryRoots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("saved project lifecycle", () => {
  test("starts a project through a detached supervisor and records ownership", async () => {
    const fixture = await savedProjectFixture("npm run dev");
    const unref = vi.fn();
    const result = await startSavedProject(fixture.project.id, undefined, {
      root: fixture.root,
      cliEntrypoint: "/portdeck/cli.js",
      spawnSupervisor: () => ({ pid: 4321, unref } as never),
      processAlive: () => true
    });

    expect(result).toEqual(expect.objectContaining({ ok: true, action: "start", state: "starting" }));
    expect(unref).toHaveBeenCalledOnce();
    expect((await loadRunState({ root: fixture.root })).runs[0]).toEqual(expect.objectContaining({
      projectId: fixture.project.id,
      pid: 4321,
      state: "starting"
    }));
  });

  test("blocks an occupied port and suggests the next free port", async () => {
    const fixture = await savedProjectFixture("npm run dev -- --port {port}", 3000);
    const available = vi.fn(async (port: number) => port === 3002);
    const result = await startSavedProject(fixture.project.id, undefined, {
      root: fixture.root,
      portAvailable: available
    });

    expect(result).toEqual(expect.objectContaining({
      ok: false,
      message: "Port 3000 is already in use.",
      suggestedPort: 3002
    }));
  });

  test("restarts on a confirmed port and persists it only after binding", async () => {
    const fixture = await savedProjectFixture("npm run dev -- --port {port}", 3000);
    const unref = vi.fn();
    const checks = [true, false];
    const result = await restartSavedProject(fixture.project.id, 3001, {
      root: fixture.root,
      cliEntrypoint: "/portdeck/cli.js",
      spawnSupervisor: () => ({ pid: 5555, unref } as never),
      portAvailable: async () => checks.shift() ?? false,
      processAlive: () => true,
      wait: async () => undefined
    });

    expect(result).toEqual(expect.objectContaining({ ok: true, action: "restart", state: "running", port: 3001 }));
    expect((await loadSavedProjects({ root: fixture.root })).projects[0]?.port).toBe(3001);
  });

  test("keeps the previous port when a restart never binds", async () => {
    const fixture = await savedProjectFixture("npm run dev -- --port {port}", 3000);
    const result = await restartSavedProject(fixture.project.id, 3001, {
      root: fixture.root,
      cliEntrypoint: "/portdeck/cli.js",
      spawnSupervisor: () => ({ pid: 5555, unref: vi.fn() } as never),
      portAvailable: async () => true,
      processAlive: () => true,
      signalProcessGroup: () => undefined,
      wait: async () => undefined
    });

    expect(result).toEqual(expect.objectContaining({ ok: false, previousPort: 3000, port: 3001 }));
    expect((await loadSavedProjects({ root: fixture.root })).projects[0]?.port).toBe(3000);
    expect((await loadRunState({ root: fixture.root })).runs[0]).toEqual(expect.objectContaining({ state: "failed", previousPort: 3000 }));
  });

  test("stops only the owned process group", async () => {
    const fixture = await savedProjectFixture("npm run dev");
    await startSavedProject(fixture.project.id, undefined, {
      root: fixture.root,
      cliEntrypoint: "/portdeck/cli.js",
      spawnSupervisor: () => ({ pid: 7777, unref: vi.fn() } as never)
    });
    const signals: Array<[number, NodeJS.Signals]> = [];
    let aliveChecks = 0;
    const result = await stopSavedProject(fixture.project.id, {
      root: fixture.root,
      processAlive: () => aliveChecks++ === 0,
      signalProcessGroup: (pid, signal) => signals.push([pid, signal]),
      wait: async () => undefined
    });

    expect(signals).toEqual([[7777, "SIGTERM"]]);
    expect(result).toEqual(expect.objectContaining({ ok: true, state: "stopped" }));
    expect((await loadRunState({ root: fixture.root })).runs).toEqual([]);
  });
});

test("findNextAvailablePort wraps and returns the first free candidate", async () => {
  expect(await findNextAvailablePort(65535, async (port) => port === 1025)).toBe(1025);
});

async function savedProjectFixture(command: string, port?: number) {
  const root = await mkdtemp(path.join(os.tmpdir(), "portdeck-run-test-"));
  temporaryRoots.push(root);
  const projectPath = path.join(root, "project");
  await mkdir(projectPath);
  const project = await saveProject({ name: "Demo", path: projectPath, command, ...(port !== undefined ? { port } : {}) }, { root });
  return { root, project };
}
