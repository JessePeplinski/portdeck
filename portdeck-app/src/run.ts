import { spawn } from "node:child_process";
import { constants as fsConstants } from "node:fs";
import { access, chmod, mkdir, open } from "node:fs/promises";
import net from "node:net";
import path from "node:path";
import {
  MAX_PROJECT_PORT,
  MIN_PROJECT_PORT,
  PROJECT_LOG_LIMIT_BYTES,
  ProjectConfigurationError,
  findSavedProject,
  isProcessAlive,
  loadRunState,
  loadSavedProjects,
  projectLogPath,
  removeRunRecord,
  renderProjectCommand,
  safeProjectError,
  saveProject,
  upsertRunRecord,
  validatePort,
  type ProjectRunRecord,
  type ProjectStorageOptions,
  type SavedProject
} from "./projects.js";

export type ProjectRunAction = "start" | "stop" | "restart";

export type ProjectRunResult = {
  ok: boolean;
  projectId: string;
  action: ProjectRunAction;
  message: string;
  state?: "starting" | "running" | "stopped" | "failed";
  port?: number;
  previousPort?: number;
  suggestedPort?: number;
  logPath?: string;
};

export type ProjectRunOptions = ProjectStorageOptions & {
  cliEntrypoint?: string;
  nodeExecutable?: string;
  shell?: string;
  now?: () => Date;
  spawnSupervisor?: typeof spawnSupervisorProcess;
  portAvailable?: (port: number) => Promise<boolean>;
  processAlive?: (pid: number) => boolean;
  signalProcessGroup?: (pid: number, signal: NodeJS.Signals) => void;
  wait?: (milliseconds: number) => Promise<void>;
};

export async function startSavedProject(
  projectId: string,
  requestedPort: number | undefined,
  options: ProjectRunOptions = {}
): Promise<ProjectRunResult> {
  const file = await loadSavedProjects(options);
  const project = findSavedProject(file, projectId);
  const existing = (await loadRunState(options)).runs.find((run) => run.projectId === projectId);
  const alive = options.processAlive ?? isProcessAlive;
  if (existing?.pid && alive(existing.pid)) {
    return failure(projectId, "start", `${project.name} is already running through PortDeck.`, project.port);
  }

  const port = requestedPort ?? project.port;
  if (project.command.includes("{port}")) {
    if (port === undefined) {
      return failure(projectId, "start", "Choose a port before starting this project.");
    }
    const conflict = await portConflictResult(project, port, "start", options);
    if (conflict) return conflict;
  } else if (requestedPort !== undefined) {
    return failure(projectId, "start", "This launch command does not support port switching.", project.port);
  }

  const result = await spawnProjectSupervisor(project, port, "start", options);
  if (!result.ok || requestedPort === undefined || requestedPort === project.port) {
    return result;
  }
  return await confirmPortAndPersist(project, requestedPort, result, "start", options);
}

export async function stopSavedProject(
  projectId: string,
  options: ProjectRunOptions = {}
): Promise<ProjectRunResult> {
  const file = await loadSavedProjects(options);
  const project = findSavedProject(file, projectId);
  const state = await loadRunState(options);
  const record = state.runs.find((run) => run.projectId === projectId);
  const alive = options.processAlive ?? isProcessAlive;
  if (!record?.pid || !alive(record.pid)) {
    await removeRunRecord(projectId, options);
    return failure(projectId, "stop", `${project.name} is not running through PortDeck.`, project.port);
  }

  await upsertRunRecord({ ...record, stopRequested: true }, options);
  try {
    (options.signalProcessGroup ?? signalProcessGroup)(record.pid, "SIGTERM");
  } catch (error) {
    if (!isMissingProcessError(error)) {
      return failure(projectId, "stop", `Could not stop ${project.name}.`, record.port);
    }
  }

  const wait = options.wait ?? delay;
  for (let attempt = 0; attempt < 25 && alive(record.pid); attempt += 1) {
    await wait(200);
  }
  if (alive(record.pid)) {
    return failure(projectId, "stop", `${project.name} did not stop after five seconds.`, record.port);
  }
  await removeRunRecord(projectId, options);
  return {
    ok: true,
    projectId,
    action: "stop",
    message: `Stopped ${project.name}.`,
    state: "stopped",
    ...(record.port !== undefined ? { port: record.port } : {}),
    logPath: projectLogPath(projectId, options)
  };
}

export async function restartSavedProject(
  projectId: string,
  port: number,
  options: ProjectRunOptions = {}
): Promise<ProjectRunResult> {
  const file = await loadSavedProjects(options);
  const project = findSavedProject(file, projectId);
  if (!project.command.includes("{port}")) {
    return failure(projectId, "restart", "This launch command does not support port switching.", project.port);
  }
  validatePort(port);
  const conflict = await portConflictResult(project, port, "restart", options);
  if (conflict && port !== project.port) return conflict;

  const previousPort = project.port;
  const current = (await loadRunState(options)).runs.find((run) => run.projectId === projectId);
  if (current?.pid && (options.processAlive ?? isProcessAlive)(current.pid)) {
    const stopped = await stopSavedProject(projectId, options);
    if (!stopped.ok) {
      return { ...stopped, action: "restart", previousPort };
    }
  }

  const started = await spawnProjectSupervisor(project, port, "restart", options, previousPort);
  if (!started.ok) return started;
  return await confirmPortAndPersist(project, port, started, "restart", options, previousPort);
}

export async function superviseSavedProject(
  projectId: string,
  port: number | undefined,
  options: ProjectRunOptions = {}
): Promise<number> {
  const project = findSavedProject(await loadSavedProjects(options), projectId);
  const command = renderProjectCommand(project, port);
  const logPath = projectLogPath(projectId, options);
  await mkdir(path.dirname(logPath), { recursive: true, mode: 0o700 });
  await chmod(path.dirname(logPath), 0o700);
  const log = await new BoundedLogWriter(logPath, PROJECT_LOG_LIMIT_BYTES).open();
  const shell = await resolvedShell(options.shell);
  const child = spawn(shell, ["-lc", command], {
    cwd: project.path,
    env: { ...process.env, PORTDECK_RUN_PROJECT_ID: projectId },
    stdio: ["ignore", "pipe", "pipe"]
  });

  let stopping = false;
  const requestStop = () => {
    stopping = true;
    try { child.kill("SIGTERM"); } catch { /* Child already exited. */ }
  };
  process.once("SIGTERM", requestStop);
  process.once("SIGINT", requestStop);

  child.stdout?.on("data", (chunk: Buffer) => { void log.write(chunk); });
  child.stderr?.on("data", (chunk: Buffer) => { void log.write(chunk); });
  child.on("error", (error) => { void log.write(Buffer.from(`${safeProjectError(error)}\n`)); });

  // Let the parent CLI persist the initial supervisor PID before replacing it
  // with the authoritative running record.
  await delay(200);

  await upsertRunRecord({
    projectId,
    pid: process.pid,
    state: "running",
    ...(port !== undefined ? { port } : {}),
    startedAt: (options.now ?? (() => new Date()))().toISOString()
  }, options);

  const exit = await new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }));
  });
  await log.close();

  const state = await loadRunState(options);
  const current = state.runs.find((run) => run.projectId === projectId);
  if (current?.pid === process.pid) {
    if (current.stopRequested || stopping) {
      await removeRunRecord(projectId, options);
    } else {
      await upsertRunRecord({
        ...current,
        pid: undefined,
        state: "failed",
        lastError: exit.code === 0
          ? "Launch command exited before PortDeck stopped it."
          : `Launch command exited${exit.code !== null ? ` with code ${exit.code}` : exit.signal ? ` after ${exit.signal}` : ""}.`
      }, options);
    }
  }
  return exit.code ?? 1;
}

export async function isPortAvailable(port: number): Promise<boolean> {
  validatePort(port);
  return await new Promise((resolve) => {
    const server = net.createServer();
    server.unref();
    server.once("error", () => resolve(false));
    server.listen({ host: "127.0.0.1", port, exclusive: true }, () => {
      server.close(() => resolve(true));
    });
  });
}

export async function findNextAvailablePort(
  port: number,
  check: (candidate: number) => Promise<boolean> = isPortAvailable
): Promise<number | undefined> {
  validatePort(port);
  for (let offset = 1; offset <= MAX_PROJECT_PORT - MIN_PROJECT_PORT; offset += 1) {
    const candidate = MIN_PROJECT_PORT + ((port - MIN_PROJECT_PORT + offset) % (MAX_PROJECT_PORT - MIN_PROJECT_PORT + 1));
    if (await check(candidate)) return candidate;
  }
  return undefined;
}

async function spawnProjectSupervisor(
  project: SavedProject,
  port: number | undefined,
  action: ProjectRunAction,
  options: ProjectRunOptions,
  previousPort?: number
): Promise<ProjectRunResult> {
  const entrypoint = options.cliEntrypoint ?? process.argv[1];
  if (!entrypoint) {
    return failure(project.id, action, "PortDeck launcher entrypoint is unavailable.", port);
  }
  const spawnSupervisor = options.spawnSupervisor ?? spawnSupervisorProcess;
  const child = spawnSupervisor(
    options.nodeExecutable ?? process.execPath,
    entrypoint,
    project.id,
    port
  );
  if (!child.pid) {
    return failure(project.id, action, `Could not start ${project.name}.`, port);
  }
  const record: ProjectRunRecord = {
    projectId: project.id,
    pid: child.pid,
    state: "starting",
    ...(port !== undefined ? { port } : {}),
    ...(previousPort !== undefined ? { previousPort } : {}),
    startedAt: (options.now ?? (() => new Date()))().toISOString()
  };
  await upsertRunRecord(record, options);
  child.unref();
  return {
    ok: true,
    projectId: project.id,
    action,
    message: `Starting ${project.name}${port !== undefined ? ` on :${port}` : ""}.`,
    state: "starting",
    ...(port !== undefined ? { port } : {}),
    ...(previousPort !== undefined ? { previousPort } : {}),
    logPath: projectLogPath(project.id, options)
  };
}

function spawnSupervisorProcess(
  nodeExecutable: string,
  entrypoint: string,
  projectId: string,
  port: number | undefined
): ReturnType<typeof spawn> {
  const argumentsList = [entrypoint, "__supervise", "--project-id", projectId];
  if (port !== undefined) argumentsList.push("--port", String(port));
  return spawn(nodeExecutable, argumentsList, { detached: true, stdio: "ignore" });
}

async function confirmPortAndPersist(
  project: SavedProject,
  port: number,
  started: ProjectRunResult,
  action: ProjectRunAction,
  options: ProjectRunOptions,
  previousPort = project.port
): Promise<ProjectRunResult> {
  const check = options.portAvailable ?? isPortAvailable;
  const alive = options.processAlive ?? isProcessAlive;
  const wait = options.wait ?? delay;
  for (let attempt = 0; attempt < 60; attempt += 1) {
    if (!(await check(port))) {
      await saveProject({ ...project, port }, options);
      return { ...started, action, state: "running", message: `Started ${project.name} on :${port}.` };
    }
    const run = (await loadRunState(options)).runs.find((item) => item.projectId === project.id);
    if (!run?.pid || !alive(run.pid) || run.state === "failed") break;
    await wait(200);
  }

  const current = (await loadRunState(options)).runs.find((item) => item.projectId === project.id);
  if (current?.pid && alive(current.pid)) {
    try { (options.signalProcessGroup ?? signalProcessGroup)(current.pid, "SIGTERM"); } catch { /* Already exited. */ }
  }
  await upsertRunRecord({
    projectId: project.id,
    state: "failed",
    ...(port !== undefined ? { port } : {}),
    ...(previousPort !== undefined ? { previousPort } : {}),
    startedAt: current?.startedAt ?? new Date().toISOString(),
    lastError: `Launch command did not bind to :${port}.`
  }, options);
  return {
    ok: false,
    projectId: project.id,
    action,
    message: `Could not start ${project.name} on :${port}.`,
    state: "failed",
    port,
    ...(previousPort !== undefined ? { previousPort } : {}),
    logPath: projectLogPath(project.id, options)
  };
}

async function portConflictResult(
  project: SavedProject,
  port: number,
  action: ProjectRunAction,
  options: ProjectRunOptions
): Promise<ProjectRunResult | undefined> {
  validatePort(port);
  const available = options.portAvailable ?? isPortAvailable;
  if (await available(port)) return undefined;
  const current = (await loadRunState(options)).runs.find((run) => run.projectId === project.id);
  if (current?.pid && (options.processAlive ?? isProcessAlive)(current.pid) && current.port === port) {
    return undefined;
  }
  const suggestedPort = await findNextAvailablePort(port, available);
  return {
    ok: false,
    projectId: project.id,
    action,
    message: `Port ${port} is already in use.`,
    state: "failed",
    port,
    ...(suggestedPort !== undefined ? { suggestedPort } : {}),
    logPath: projectLogPath(project.id, options)
  };
}

function failure(
  projectId: string,
  action: ProjectRunAction,
  message: string,
  port?: number
): ProjectRunResult {
  return {
    ok: false,
    projectId,
    action,
    message,
    state: "failed",
    ...(port !== undefined ? { port } : {})
  };
}

function signalProcessGroup(pid: number, signal: NodeJS.Signals): void {
  process.kill(-pid, signal);
}

function isMissingProcessError(error: unknown): boolean {
  return Boolean(error && typeof error === "object" && "code" in error && error.code === "ESRCH");
}

async function resolvedShell(override: string | undefined): Promise<string> {
  const candidate = override ?? process.env.SHELL ?? "/bin/zsh";
  try {
    await access(candidate, fsConstants.X_OK);
    return candidate;
  } catch {
    throw new ProjectConfigurationError("The configured login shell is unavailable.");
  }
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

class BoundedLogWriter {
  private handle?: Awaited<ReturnType<typeof open>>;
  private written = 0;
  private capped = false;
  private pending = Promise.resolve();

  constructor(private readonly filePath: string, private readonly limit: number) {}

  async open(): Promise<BoundedLogWriter> {
    this.handle = await open(this.filePath, "w", 0o600);
    await chmod(this.filePath, 0o600);
    return this;
  }

  async write(chunk: Buffer): Promise<void> {
    this.pending = this.pending.then(async () => {
      if (!this.handle || this.capped) return;
      const remaining = this.limit - this.written;
      if (remaining <= 0) {
        await this.markCapped();
        return;
      }
      const slice = chunk.subarray(0, remaining);
      await this.handle.write(slice);
      this.written += slice.length;
      if (slice.length < chunk.length || this.written >= this.limit) await this.markCapped();
    });
    await this.pending;
  }

  async close(): Promise<void> {
    await this.pending;
    await this.handle?.close();
    this.handle = undefined;
  }

  private async markCapped(): Promise<void> {
    if (!this.handle || this.capped) return;
    this.capped = true;
    const marker = Buffer.from("\n[PortDeck log limit reached]\n");
    const position = Math.max(0, this.limit - marker.length);
    await this.handle.write(marker, 0, marker.length, position);
  }
}
