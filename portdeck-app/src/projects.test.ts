import { chmod, mkdtemp, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, test } from "vitest";
import {
  ProjectConfigurationError,
  loadSavedProjects,
  mergeSavedProjects,
  projectStoragePaths,
  saveProject,
  suggestProjects
} from "./projects.js";
import type { PortdeckService, PortdeckStatus } from "./types.js";

const temporaryRoots: string[] = [];

afterEach(async () => {
  const { rm } = await import("node:fs/promises");
  await Promise.all(temporaryRoots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("saved project storage", () => {
  test("persists a private versioned project file and updates by id", async () => {
    const root = await temporaryDirectory();
    const projectPath = await projectDirectory(root, "demo");
    const saved = await saveProject({ name: "Demo", path: projectPath, command: "npm run dev -- --port {port}", port: 3000 }, { root });
    await saveProject({ ...saved, name: "Demo App", port: 3001 }, { root });

    expect(await loadSavedProjects({ root })).toEqual({
      schemaVersion: "1",
      projects: [{ ...saved, name: "Demo App", port: 3001 }]
    });
    const paths = projectStoragePaths({ root });
    expect((await stat(root)).mode & 0o777).toBe(0o700);
    expect((await stat(paths.projects)).mode & 0o777).toBe(0o600);
  });

  test("preserves malformed configuration and reports a recoverable error", async () => {
    const root = await temporaryDirectory();
    await writeFile(path.join(root, "projects.json"), "{ broken", { mode: 0o600 });

    await expect(loadSavedProjects({ root })).rejects.toThrow(ProjectConfigurationError);
    expect(await readFile(path.join(root, "projects.json"), "utf8")).toBe("{ broken");
  });

  test("rejects duplicate folders and inconsistent port templates", async () => {
    const root = await temporaryDirectory();
    const projectPath = await projectDirectory(root, "demo");
    await saveProject({ name: "Demo", path: projectPath, command: "npm run dev" }, { root });

    await expect(saveProject({ name: "Duplicate", path: projectPath, command: "npm start" }, { root })).rejects.toThrow("already uses");
    await expect(saveProject({ name: "Bad Port", path: await projectDirectory(root, "bad"), command: "npm run dev", port: 3000 }, { root })).rejects.toThrow("add {port}");
  });
});

describe("project suggestions", () => {
  test.each([
    ["package-lock.json", "npm run dev -- --port {port}"],
    ["pnpm-lock.yaml", "pnpm run dev -- --port {port}"],
    ["yarn.lock", "yarn run dev --port {port}"],
    ["bun.lock", "bun run dev -- --port {port}"]
  ])("detects package manager from %s", async (lockfile, expectedCommand) => {
    const root = await temporaryDirectory();
    await writeFile(path.join(root, lockfile), "");
    await writeFile(path.join(root, "package.json"), JSON.stringify({
      name: "@demo/web",
      scripts: { dev: "vite", start: "node server.js" },
      devDependencies: { vite: "1.0.0" }
    }));

    const result = await suggestProjects(root);
    expect(result.name).toBe("web");
    expect(result.suggestions[0]).toEqual(expect.objectContaining({ command: expectedCommand, port: 5173 }));
    expect(result.suggestions[1]).toEqual(expect.objectContaining({ command: expect.stringContaining("run start") }));
    expect(result.suggestions[1]).not.toHaveProperty("port");
  });

  test("suggests workspace, Compose, and executable repo commands without modifying the project", async () => {
    const root = await temporaryDirectory();
    await writeFile(path.join(root, "package.json"), JSON.stringify({ name: "workspace", workspaces: ["apps/*"] }));
    await mkdir(path.join(root, "apps", "web"), { recursive: true });
    await writeFile(path.join(root, "apps", "web", "package.json"), JSON.stringify({
      name: "web",
      scripts: { dev: "next dev" },
      dependencies: { next: "1.0.0" }
    }));
    await writeFile(path.join(root, "compose.yaml"), "services: {}\n");
    await mkdir(path.join(root, "scripts"));
    const script = path.join(root, "scripts", "run-dev-app.sh");
    await writeFile(script, "#!/bin/sh\n");
    await chmod(script, 0o755);

    const result = await suggestProjects(root);
    expect(result.suggestions.map((item) => item.command)).toEqual([
      "npm --prefix 'apps/web' run dev -- --port {port}",
      "docker compose -f 'compose.yaml' up",
      "./scripts/run-dev-app.sh"
    ]);
  });

  test("normalizes a running package command without copying its arguments", async () => {
    const root = await temporaryDirectory();
    const workspace = await projectDirectory(root, path.join("apps", "web"));
    const service: PortdeckService = {
      id: "web-4100",
      name: "web",
      source: "process",
      status: "running",
      port: 4100,
      command: "/bin/zsh -c \"npm run dev -- --port 4100 --token private-value\"",
      cwd: workspace,
      confidence: "high"
    };

    const result = await suggestProjects(root, [service]);

    expect(result.suggestions).toEqual([expect.objectContaining({
      command: "npm --prefix 'apps/web' run dev",
      source: "observed"
    })]);
    expect(JSON.stringify(result)).not.toContain("private-value");
    expect(result.suggestions[0]).not.toHaveProperty("port");
  });

  test("reduces a running Unity editor to projectPath and ignores workers and session flags", async () => {
    const root = await temporaryDirectory();
    const unityProject = await projectDirectory(root, path.join("unity-game", "TheBlackRelay"));
    const unityExecutable = "/Applications/Unity/Hub/Editor/6000.5.1f1/Unity.app/Contents/MacOS/Unity";
    const services: PortdeckService[] = [{
      id: "unity-editor",
      name: "Unity",
      source: "process",
      status: "running",
      command: `'${unityExecutable}' -projectpath '${unityProject}' -accessToken private-token -hubSessionId private-session`,
      cwd: unityProject,
      confidence: "high"
    }, {
      id: "unity-worker",
      name: "Unity AssetImportWorker",
      source: "process",
      status: "running",
      command: `'${unityExecutable}' -batchMode -projectPath '${unityProject}' -accessToken private-token`,
      cwd: unityProject,
      confidence: "high"
    }, {
      id: "unrecognized",
      name: "custom",
      source: "process",
      status: "running",
      command: "node custom-server.js --token private-token",
      cwd: root,
      confidence: "high"
    }];

    const result = await suggestProjects(root, services);

    expect(result.suggestions).toEqual([expect.objectContaining({
      title: "Unity Editor",
      command: `'${unityExecutable}' -projectPath 'unity-game/TheBlackRelay'`,
      source: "observed"
    })]);
    expect(JSON.stringify(result)).not.toContain("private-token");
    expect(JSON.stringify(result)).not.toContain("private-session");
    expect(JSON.stringify(result)).not.toContain("batchMode");
  });
});

describe("saved project status merging", () => {
  test("pins stopped projects and identifies matching external services without duplicates", async () => {
    const storageRoot = await temporaryDirectory();
    const stoppedPath = await projectDirectory(storageRoot, "stopped");
    const externalPath = await projectDirectory(storageRoot, "external");
    const stopped = await saveProject({ name: "Stopped", path: stoppedPath, command: "npm run dev" }, { root: storageRoot });
    const external = await saveProject({ name: "External", path: externalPath, command: "npm run dev -- --port {port}", port: 3000 }, { root: storageRoot });
    const status = makeStatus(externalPath);

    const merged = await mergeSavedProjects(status, { root: storageRoot });

    expect(merged.groups.map((group) => group.projectName)).toEqual(["Stopped", "External"]);
    expect(merged.groups[0]?.savedProject).toEqual(expect.objectContaining({ id: stopped.id, state: "stopped" }));
    expect(merged.groups[1]?.savedProject).toEqual(expect.objectContaining({ id: external.id, state: "external", port: 3000 }));
    expect(merged.groups[1]?.worktrees[0]?.services).toHaveLength(1);
  });

  test("retains discovered status when saved configuration is malformed", async () => {
    const root = await temporaryDirectory();
    await writeFile(path.join(root, "projects.json"), "invalid");
    const status = makeStatus("/repo/demo");
    const merged = await mergeSavedProjects(status, { root });
    expect(merged.groups).toEqual(status.groups);
    expect(merged.warnings[0]).toContain("left unchanged");
  });

  test("moves matching non-Git service rows from unknown into the saved project", async () => {
    const root = await temporaryDirectory();
    const projectPath = await projectDirectory(root, "plain-folder");
    const saved = await saveProject({ name: "Plain Folder", path: projectPath, command: "npm run dev" }, { root });
    const service = makeStatus(projectPath).groups[0]!.worktrees[0]!.services[0]!;
    const status: PortdeckStatus = {
      schemaVersion: "0.1",
      generatedAt: "2026-07-17T00:00:00.000Z",
      groups: [],
      unknown: [service],
      warnings: []
    };

    const merged = await mergeSavedProjects(status, { root });

    expect(merged.unknown).toEqual([]);
    expect(merged.groups).toHaveLength(1);
    expect(merged.groups[0]?.savedProject).toEqual(expect.objectContaining({ id: saved.id, state: "external" }));
    expect(merged.groups[0]?.worktrees[0]?.services).toEqual([service]);
  });
});

async function temporaryDirectory(): Promise<string> {
  const root = await mkdtemp(path.join(os.tmpdir(), "portdeck-projects-test-"));
  temporaryRoots.push(root);
  return root;
}

async function projectDirectory(root: string, name: string): Promise<string> {
  const directory = path.join(root, name);
  await mkdir(directory, { recursive: true });
  return directory;
}

function makeStatus(projectPath: string): PortdeckStatus {
  return {
    schemaVersion: "0.1",
    generatedAt: "2026-07-17T00:00:00.000Z",
    groups: [{
      projectName: "external",
      repoRoot: projectPath,
      worktrees: [{
        name: "main",
        path: projectPath,
        services: [{
          id: "pid-1-port-3000",
          name: "web",
          source: "process",
          status: "running",
          port: 3000,
          cwd: projectPath,
          confidence: "high"
        }]
      }]
    }],
    unknown: [],
    warnings: []
  };
}
