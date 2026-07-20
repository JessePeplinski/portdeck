import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, realpath, rm, writeFile } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { afterAll, beforeAll, describe, expect, test } from "vitest";

const execFileAsync = promisify(execFile);
const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

describe("bundled PortDeck helper", () => {
  let root = "";
  let bundlePath = "";
  let noticesPath = "";
  let stateDirectory = "";
  let homeDirectory = "";
  let projectDirectory = "";
  const projectId = "bundled-helper-fixture";

  beforeAll(async () => {
    root = await mkdtemp(path.join(await realpath(os.tmpdir()), "portdeck-bundled-helper-"));
    bundlePath = path.join(root, "PortDeckRuntime", "portdeck-cli.js");
    noticesPath = path.join(root, "Licenses", "PortDeck-Helper-THIRD-PARTY-NOTICES.txt");
    stateDirectory = path.join(root, "state");
    homeDirectory = path.join(root, "home");
    projectDirectory = path.join(root, "project");
    await Promise.all([
      mkdir(stateDirectory, { recursive: true }),
      mkdir(homeDirectory, { recursive: true }),
      mkdir(projectDirectory, { recursive: true })
    ]);

    await execFileAsync(process.execPath, [
      path.join(packageRoot, "scripts", "build-bundled-helper.mjs"),
      "--outfile", bundlePath,
      "--notices-file", noticesPath
    ], { cwd: packageRoot });
  }, 30_000);

  afterAll(async () => {
    if (bundlePath) {
      await runCLI(["run", "stop", "--project-id", projectId, "--json"]).catch(() => undefined);
    }
    if (root) await rm(root, { recursive: true, force: true });
  });

  test("produces compatible status JSON outside the checkout with bundled notices", async () => {
    const status = JSON.parse(await runCLI(["status", "--json"]));
    expect(status.schemaVersion).toBe("0.1");
    expect(status.groups).toEqual(expect.any(Array));
    expect(status.unknown).toEqual(expect.any(Array));
    expect(status.warnings).toEqual(expect.any(Array));

    const notices = await readFile(noticesPath, "utf8");
    expect(notices).toContain("execa 9.6.1");
    expect(notices).toContain("cross-spawn 7.0.6");

    const repeatedNoticesPath = path.join(root, "repeat", "THIRD-PARTY-NOTICES.txt");
    await execFileAsync(process.execPath, [
      path.join(packageRoot, "scripts", "build-bundled-helper.mjs"),
      "--outfile", path.join(root, "repeat", "portdeck-cli.js"),
      "--notices-file", repeatedNoticesPath
    ], { cwd: packageRoot });
    expect(await readFile(repeatedNoticesPath, "utf8")).toBe(notices);

    const packageHeadings = [...notices.matchAll(/^={80}\n([^\n]+)$/gm)].map((match) => match[1]);
    expect(packageHeadings).toEqual([...packageHeadings].sort(compareText));
  }, 30_000);

  test("preserves saved-project start, stop, and port switching", async () => {
    const serverPath = path.join(projectDirectory, "server.mjs");
    await writeFile(serverPath, [
      'import http from "node:http";',
      "const port = Number(process.argv[2]);",
      'http.createServer((_request, response) => response.end("ok")).listen(port, "127.0.0.1");',
      ""
    ].join("\n"));

    const firstPort = await freePort();
    let secondPort = await freePort();
    while (secondPort === firstPort) secondPort = await freePort();
    const project = {
      id: projectId,
      name: "Bundled Helper Fixture",
      path: projectDirectory,
      command: `${shellQuote(process.execPath)} ${shellQuote(serverPath)} {port}`,
      port: firstPort
    };

    const saved = JSON.parse(await runCLI([
      "projects", "save", "--input", JSON.stringify(project), "--json"
    ]));
    expect(saved.ok).toBe(true);

    const started = JSON.parse(await runCLI(["run", "start", "--project-id", projectId, "--json"]));
    expect(started.ok).toBe(true);
    await waitForPort(firstPort, true);
    await expectSavedProject(firstPort, "running");

    const restarted = JSON.parse(await runCLI([
      "run", "restart", "--project-id", projectId, "--port", String(secondPort), "--json"
    ]));
    expect(restarted).toMatchObject({ ok: true, state: "running", port: secondPort });
    await waitForPort(firstPort, false);
    await waitForPort(secondPort, true);
    await expectSavedProject(secondPort, "running");

    const stopped = JSON.parse(await runCLI(["run", "stop", "--project-id", projectId, "--json"]));
    expect(stopped).toMatchObject({ ok: true, state: "stopped" });
    await waitForPort(secondPort, false);
    await expectSavedProject(secondPort, "stopped");
  }, 45_000);

  async function runCLI(argumentsList: string[]): Promise<string> {
    const result = await execFileAsync(process.execPath, [bundlePath, ...argumentsList], {
      cwd: root,
      env: {
        ...process.env,
        HOME: homeDirectory,
        PORTDECK_STATE_DIR: stateDirectory,
        SHELL: "/bin/zsh"
      },
      maxBuffer: 8 * 1024 * 1024
    });
    return result.stdout;
  }

  async function expectSavedProject(port: number, state: string): Promise<void> {
    for (let attempt = 0; attempt < 30; attempt += 1) {
      const status = JSON.parse(await runCLI(["status", "--json"]));
      const savedProject = status.groups.find((group: { savedProject?: { id: string } }) => (
        group.savedProject?.id === projectId
      ))?.savedProject;
      if (savedProject?.port === port && savedProject?.state === state) return;
      await delay(100);
    }
    throw new Error(`Saved project did not reach ${state} on port ${port}.`);
  }
});

async function freePort(): Promise<number> {
  return await new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen({ host: "127.0.0.1", port: 0 }, () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close();
        reject(new Error("Could not allocate a test port."));
        return;
      }
      server.close(() => resolve(address.port));
    });
  });
}

async function waitForPort(port: number, open: boolean): Promise<void> {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (await portIsOpen(port) === open) return;
    await delay(100);
  }
  throw new Error(`Port ${port} did not become ${open ? "open" : "closed"}.`);
}

async function portIsOpen(port: number): Promise<boolean> {
  return await new Promise((resolve) => {
    const socket = net.createConnection({ host: "127.0.0.1", port });
    socket.setTimeout(100);
    socket.once("connect", () => {
      socket.destroy();
      resolve(true);
    });
    const close = () => {
      socket.destroy();
      resolve(false);
    };
    socket.once("error", close);
    socket.once("timeout", close);
  });
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}
