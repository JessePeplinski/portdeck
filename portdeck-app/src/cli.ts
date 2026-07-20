#!/usr/bin/env node
import { realpathSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { getPortdeckStatus } from "./discovery.js";
import {
  loadSavedProjects,
  removeProject,
  safeProjectError,
  saveProject,
  suggestProjects,
  type ProjectSuggestionResult,
  type SavedProject,
  type SavedProjectsFile
} from "./projects.js";
import {
  restartSavedProject,
  startSavedProject,
  stopSavedProject,
  superviseSavedProject,
  type ProjectRunResult
} from "./run.js";
import { stopServiceById, type StopActionResult } from "./stop.js";
import type { PortdeckService, PortdeckStatus } from "./types.js";

type Writer = {
  write(chunk: string): unknown;
};

type CliDependencies = {
  stdout?: Writer;
  stderr?: Writer;
  getStatus?: () => Promise<PortdeckStatus>;
  stopService?: (serviceId: string) => Promise<StopActionResult>;
  listProjects?: () => Promise<SavedProjectsFile>;
  suggestProjects?: (projectPath: string, observedServices?: PortdeckService[]) => Promise<ProjectSuggestionResult>;
  saveProject?: (input: unknown) => Promise<SavedProject>;
  removeProject?: (projectId: string) => Promise<SavedProject>;
  startProject?: (projectId: string, port?: number) => Promise<ProjectRunResult>;
  stopProject?: (projectId: string) => Promise<ProjectRunResult>;
  restartProject?: (projectId: string, port: number) => Promise<ProjectRunResult>;
  superviseProject?: (projectId: string, port?: number) => Promise<number>;
};

const usage = [
  "Usage: portdeck status --json",
  "       portdeck stop --service-id <id> --json",
  "       portdeck projects list --json",
  "       portdeck projects suggest --path <path> [--service-id <id> ...] --json",
  "       portdeck projects save --input <project-json> --json",
  "       portdeck projects remove --project-id <id> --json",
  "       portdeck run start --project-id <id> [--port <port>] --json",
  "       portdeck run stop --project-id <id> --json",
  "       portdeck run restart --project-id <id> --port <port> --json",
  ""
].join("\n");

export async function runPortdeckCli(argv = process.argv.slice(2), dependencies: CliDependencies = {}): Promise<number> {
  const stdout = dependencies.stdout ?? process.stdout;
  const stderr = dependencies.stderr ?? process.stderr;
  const getStatus = dependencies.getStatus ?? getPortdeckStatus;
  const stopService = dependencies.stopService ?? stopServiceById;
  const listProjects = dependencies.listProjects ?? loadSavedProjects;
  const suggestProjectCommands = dependencies.suggestProjects ?? suggestProjects;
  const persistProject = dependencies.saveProject ?? saveProject;
  const deleteProject = dependencies.removeProject ?? removeProject;
  const startProject = dependencies.startProject ?? startSavedProject;
  const stopProject = dependencies.stopProject ?? stopSavedProject;
  const restartProject = dependencies.restartProject ?? restartSavedProject;
  const superviseProject = dependencies.superviseProject ?? superviseSavedProject;

  if (argv[0] === "__supervise") {
    const projectId = optionValue(argv, "--project-id");
    const port = optionalPort(argv);
    if (!projectId) return 1;
    return await superviseProject(projectId, port);
  }

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

  try {
    if (matches(argv, ["projects", "list", "--json"])) {
      stdout.write(`${JSON.stringify(await listProjects(), null, 2)}\n`);
      return 0;
    }

    if (argv[0] === "projects" && argv[1] === "suggest" && argv.includes("--json")) {
      const projectPath = optionValue(argv, "--path");
      if (!projectPath) return usageFailure(stderr);
      const requestedServiceIDs = new Set(optionValues(argv, "--service-id"));
      let observedServices: PortdeckService[] = [];
      if (requestedServiceIDs.size > 0) {
        try {
          const status = await getStatus();
          observedServices = statusServices(status).filter((service) => requestedServiceIDs.has(service.id));
        } catch {
          // Repository-based suggestions should still work when live discovery is temporarily unavailable.
        }
      }
      stdout.write(`${JSON.stringify(await suggestProjectCommands(projectPath, observedServices), null, 2)}\n`);
      return 0;
    }

    if (argv[0] === "projects" && argv[1] === "save" && argv.includes("--json")) {
      const input = optionValue(argv, "--input");
      if (!input) return usageFailure(stderr);
      const project = await persistProject(JSON.parse(input));
      stdout.write(`${JSON.stringify({ ok: true, project }, null, 2)}\n`);
      return 0;
    }

    if (argv[0] === "projects" && argv[1] === "remove" && argv.includes("--json")) {
      const projectId = optionValue(argv, "--project-id");
      if (!projectId) return usageFailure(stderr);
      const project = await deleteProject(projectId);
      stdout.write(`${JSON.stringify({ ok: true, projectId: project.id, message: `Removed ${project.name}.` }, null, 2)}\n`);
      return 0;
    }

    if (argv[0] === "run" && ["start", "stop", "restart"].includes(argv[1] ?? "") && argv.includes("--json")) {
      const projectId = optionValue(argv, "--project-id");
      if (!projectId) return usageFailure(stderr);
      const action = argv[1];
      const port = optionalPort(argv);
      if ((action === "restart" || argv.includes("--port")) && port === undefined) return usageFailure(stderr);
      const result = action === "start"
        ? await startProject(projectId, port)
        : action === "stop"
          ? await stopProject(projectId)
          : await restartProject(projectId, port!);
      stdout.write(`${JSON.stringify(result, null, 2)}\n`);
      return result.ok ? 0 : 1;
    }
  } catch (error) {
    stdout.write(`${JSON.stringify({ ok: false, message: safeProjectError(error) }, null, 2)}\n`);
    return 1;
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

function optionValue(argumentsList: string[], option: string): string | undefined {
  const index = argumentsList.indexOf(option);
  return index >= 0 ? argumentsList[index + 1] : undefined;
}

function optionValues(argumentsList: string[], option: string): string[] {
  const values: string[] = [];
  for (let index = 0; index < argumentsList.length; index += 1) {
    if (argumentsList[index] !== option) continue;
    const value = argumentsList[index + 1];
    if (value && !value.startsWith("--")) values.push(value);
    index += 1;
  }
  return values;
}

function statusServices(status: PortdeckStatus): PortdeckService[] {
  return [
    ...status.groups.flatMap((group) => group.worktrees.flatMap((worktree) => worktree.services)),
    ...status.unknown
  ];
}

function optionalPort(argumentsList: string[]): number | undefined {
  const rawPort = optionValue(argumentsList, "--port");
  if (rawPort === undefined) return undefined;
  const port = Number(rawPort);
  return Number.isInteger(port) ? port : undefined;
}

function matches(argumentsList: string[], expected: string[]): boolean {
  return argumentsList.length === expected.length && argumentsList.every((value, index) => value === expected[index]);
}

function usageFailure(stderr: Writer): number {
  stderr.write(usage);
  return 1;
}
