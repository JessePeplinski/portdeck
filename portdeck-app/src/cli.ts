#!/usr/bin/env node
import { realpathSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { getPortdeckStatus } from "./discovery.js";
import { stopServiceById, type StopActionResult } from "./stop.js";
import type { PortdeckStatus } from "./types.js";

type Writer = {
  write(chunk: string): unknown;
};

type CliDependencies = {
  stdout?: Writer;
  stderr?: Writer;
  getStatus?: () => Promise<PortdeckStatus>;
  stopService?: (serviceId: string) => Promise<StopActionResult>;
};

const usage = [
  "Usage: portdeck status --json",
  "       portdeck stop --service-id <id> --json",
  ""
].join("\n");

export async function runPortdeckCli(argv = process.argv.slice(2), dependencies: CliDependencies = {}): Promise<number> {
  const stdout = dependencies.stdout ?? process.stdout;
  const stderr = dependencies.stderr ?? process.stderr;
  const getStatus = dependencies.getStatus ?? getPortdeckStatus;
  const stopService = dependencies.stopService ?? stopServiceById;

  if (argv.length === 2 && argv[0] === "status" && argv[1] === "--json") {
    const status = await getStatus();
    stdout.write(`${JSON.stringify(status, null, 2)}\n`);
    return 0;
  }

  if (argv.length === 4 && argv[0] === "stop" && argv[1] === "--service-id" && argv[2] && argv[3] === "--json") {
    const result = await stopService(argv[2]);
    stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return result.ok ? 0 : 1;
  }

  return usageFailure(stderr);
}

if (isEntrypoint()) {
  process.exitCode = await runPortdeckCli();
}

function isEntrypoint(): boolean {
  const entrypoint = process.argv[1];
  if (!entrypoint) return false;
  try {
    return realpathSync(entrypoint) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return path.resolve(entrypoint) === fileURLToPath(import.meta.url);
  }
}

function usageFailure(stderr: Writer): number {
  stderr.write(usage);
  return 1;
}
