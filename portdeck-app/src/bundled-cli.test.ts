import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, realpath, rm } from "node:fs/promises";
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
  let homeDirectory = "";

  beforeAll(async () => {
    root = await mkdtemp(path.join(await realpath(os.tmpdir()), "portdeck-bundled-helper-"));
    bundlePath = path.join(root, "PortDeckRuntime", "portdeck-cli.js");
    noticesPath = path.join(root, "Licenses", "PortDeck-Helper-THIRD-PARTY-NOTICES.txt");
    homeDirectory = path.join(root, "home");
    await mkdir(homeDirectory, { recursive: true });

    await execFileAsync(process.execPath, [
      path.join(packageRoot, "scripts", "build-bundled-helper.mjs"),
      "--outfile", bundlePath,
      "--notices-file", noticesPath
    ], { cwd: packageRoot });
  }, 30_000);

  afterAll(async () => {
    if (root) await rm(root, { recursive: true, force: true });
  });

  test("produces compatible status JSON outside the checkout with bundled notices", async () => {
    const status = JSON.parse(await runCLI(["status", "--json"]));
    expect(status.schemaVersion).toBe("0.2");
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

  async function runCLI(argumentsList: string[]): Promise<string> {
    const result = await execFileAsync(process.execPath, [bundlePath, ...argumentsList], {
      cwd: root,
      env: {
        ...process.env,
        HOME: homeDirectory,
        SHELL: "/bin/zsh"
      },
      maxBuffer: 8 * 1024 * 1024
    });
    return result.stdout;
  }
});

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}
