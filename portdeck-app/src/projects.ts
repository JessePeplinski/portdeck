import { constants as fsConstants, realpathSync } from "node:fs";
import {
  access,
  chmod,
  mkdir,
  readFile,
  readdir,
  realpath,
  rename,
  stat,
  unlink,
  writeFile
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import type { PortdeckService, PortdeckStatus, ProjectGroup, SavedProjectStatus } from "./types.js";

export const PROJECTS_SCHEMA_VERSION = "1" as const;
export const MIN_PROJECT_PORT = 1024;
export const MAX_PROJECT_PORT = 65535;
export const PROJECT_LOG_LIMIT_BYTES = 2 * 1024 * 1024;

export type SavedProject = {
  id: string;
  name: string;
  path: string;
  command: string;
  port?: number;
};

export type SavedProjectsFile = {
  schemaVersion: typeof PROJECTS_SCHEMA_VERSION;
  projects: SavedProject[];
};

export type ProjectSuggestion = {
  id: string;
  title: string;
  detail: string;
  command: string;
  port?: number;
  source: "package" | "compose" | "script" | "observed";
};

export type ProjectSuggestionResult = {
  path: string;
  name: string;
  suggestions: ProjectSuggestion[];
};

export type ProjectRunRecord = {
  projectId: string;
  pid?: number;
  state: "starting" | "running" | "failed";
  port?: number;
  previousPort?: number;
  startedAt: string;
  stopRequested?: boolean;
  lastError?: string;
};

export type ProjectRunStateFile = {
  schemaVersion: typeof PROJECTS_SCHEMA_VERSION;
  runs: ProjectRunRecord[];
};

export type ProjectStoragePaths = {
  root: string;
  projects: string;
  runState: string;
  logs: string;
};

export type ProjectStorageOptions = {
  root?: string;
};

export class ProjectConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ProjectConfigurationError";
  }
}

export function projectStoragePaths(options: ProjectStorageOptions = {}): ProjectStoragePaths {
  const root = options.root ?? process.env.PORTDECK_STATE_DIR ?? path.join(os.homedir(), ".portdeck");
  return {
    root,
    projects: path.join(root, "projects.json"),
    runState: path.join(root, "run-state.json"),
    logs: path.join(root, "logs")
  };
}

export async function loadSavedProjects(options: ProjectStorageOptions = {}): Promise<SavedProjectsFile> {
  const paths = projectStoragePaths(options);
  let raw: string;
  try {
    raw = await readFile(paths.projects, "utf8");
  } catch (error) {
    if (isMissingFileError(error)) {
      return emptyProjectsFile();
    }
    throw error;
  }

  let decoded: unknown;
  try {
    decoded = JSON.parse(raw);
  } catch {
    throw new ProjectConfigurationError(`Could not parse ${paths.projects}. The file was left unchanged.`);
  }
  return validateProjectsFile(decoded, paths.projects);
}

export async function saveProject(
  input: unknown,
  options: ProjectStorageOptions = {}
): Promise<SavedProject> {
  const candidate = await validateAndNormalizeProject(input);
  const file = await loadSavedProjects(options);
  const duplicatePath = file.projects.find(
    (project) => project.path === candidate.path && project.id !== candidate.id
  );
  if (duplicatePath) {
    throw new ProjectConfigurationError(`${duplicatePath.name} already uses ${candidate.path}.`);
  }

  const index = file.projects.findIndex((project) => project.id === candidate.id);
  if (index >= 0) {
    file.projects[index] = candidate;
  } else {
    file.projects.push(candidate);
  }
  await writeProjectsFile(file, options);
  return candidate;
}

export async function removeProject(
  projectId: string,
  options: ProjectStorageOptions = {}
): Promise<SavedProject> {
  const file = await loadSavedProjects(options);
  const project = file.projects.find((item) => item.id === projectId);
  if (!project) {
    throw new ProjectConfigurationError("Saved project not found.");
  }
  const run = (await loadRunState(options)).runs.find((item) => item.projectId === projectId);
  if (run?.pid && isProcessAlive(run.pid)) {
    throw new ProjectConfigurationError("Stop this PortDeck-run project before removing it.");
  }
  await writeProjectsFile(
    { ...file, projects: file.projects.filter((item) => item.id !== projectId) },
    options
  );
  await removeRunRecord(projectId, options);
  return project;
}

export async function suggestProjects(
  projectPath: string,
  observedServices: PortdeckService[] = []
): Promise<ProjectSuggestionResult> {
  const canonicalPath = await canonicalProjectDirectory(projectPath);
  const rootPackage = await readPackageManifest(path.join(canonicalPath, "package.json"));
  const packageManager = await detectPackageManager(canonicalPath);
  const suggestions: ProjectSuggestion[] = [];

  if (rootPackage) {
    addPackageSuggestions(suggestions, rootPackage, packageManager, ".");
    for (const workspacePath of await workspaceDirectories(canonicalPath, rootPackage.workspaces)) {
      const manifest = await readPackageManifest(path.join(workspacePath, "package.json"));
      if (manifest) {
        const relativePath = path.relative(canonicalPath, workspacePath);
        addPackageSuggestions(suggestions, manifest, packageManager, relativePath);
      }
    }
  }

  for (const composeFile of ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]) {
    if (await fileExists(path.join(canonicalPath, composeFile))) {
      suggestions.push({
        id: `compose-${composeFile}`,
        title: "Docker Compose",
        detail: composeFile,
        command: `docker compose -f ${shellQuote(composeFile)} up`,
        source: "compose"
      });
      break;
    }
  }

  for (const scriptName of ["run-dev-app.sh", "dev.sh", "start.sh"]) {
    const relativePath = path.join("scripts", scriptName);
    const absolutePath = path.join(canonicalPath, relativePath);
    if (await isExecutableFile(absolutePath)) {
      suggestions.push({
        id: `script-${scriptName}`,
        title: humanizeScriptName(scriptName),
        detail: relativePath,
        command: `./${relativePath}`,
        source: "script"
      });
    }
  }

  suggestions.push(...observedProjectSuggestions(canonicalPath, observedServices));

  const packageName = normalizedPackageDisplayName(rootPackage?.name);
  return {
    path: canonicalPath,
    name: packageName ?? path.basename(canonicalPath),
    suggestions: uniqueSuggestions(suggestions)
  };
}

export async function loadRunState(options: ProjectStorageOptions = {}): Promise<ProjectRunStateFile> {
  const paths = projectStoragePaths(options);
  let raw: string;
  try {
    raw = await readFile(paths.runState, "utf8");
  } catch (error) {
    if (isMissingFileError(error)) {
      return emptyRunStateFile();
    }
    throw error;
  }

  try {
    const decoded = JSON.parse(raw) as Partial<ProjectRunStateFile>;
    if (decoded.schemaVersion !== PROJECTS_SCHEMA_VERSION || !Array.isArray(decoded.runs)) {
      throw new Error("invalid run state");
    }
    return {
      schemaVersion: PROJECTS_SCHEMA_VERSION,
      runs: decoded.runs.filter(isProjectRunRecord)
    };
  } catch {
    return emptyRunStateFile();
  }
}

export async function upsertRunRecord(
  record: ProjectRunRecord,
  options: ProjectStorageOptions = {}
): Promise<void> {
  const file = await loadRunState(options);
  const index = file.runs.findIndex((item) => item.projectId === record.projectId);
  if (index >= 0) {
    file.runs[index] = record;
  } else {
    file.runs.push(record);
  }
  await writeRunStateFile(file, options);
}

export async function removeRunRecord(projectId: string, options: ProjectStorageOptions = {}): Promise<void> {
  const file = await loadRunState(options);
  if (!file.runs.some((item) => item.projectId === projectId)) {
    return;
  }
  await writeRunStateFile(
    { ...file, runs: file.runs.filter((item) => item.projectId !== projectId) },
    options
  );
}

export async function mergeSavedProjects(
  status: PortdeckStatus,
  options: ProjectStorageOptions = {}
): Promise<PortdeckStatus> {
  let saved: SavedProjectsFile;
  try {
    saved = await loadSavedProjects(options);
  } catch (error) {
    return {
      ...status,
      warnings: [...status.warnings, safeProjectError(error)].sort()
    };
  }
  if (saved.projects.length === 0) {
    return status;
  }

  const runs = await loadRunState(options);
  const remainingGroups = [...status.groups];
  let remainingUnknown = [...status.unknown];
  const savedGroups: ProjectGroup[] = [];

  for (const project of saved.projects) {
    const index = remainingGroups.findIndex((group) => groupMatchesProject(group, project.path));
    let group = index >= 0
      ? remainingGroups.splice(index, 1)[0]!
      : emptySavedProjectGroup(project);
    const claimedUnknown = remainingUnknown.filter((service) => isWithin(project.path, service.cwd));
    if (claimedUnknown.length > 0) {
      const claimedIDs = new Set(claimedUnknown.map((service) => service.id));
      remainingUnknown = remainingUnknown.filter((service) => !claimedIDs.has(service.id));
      group = attachServicesToSavedGroup(group, project, claimedUnknown);
    }
    const hasDiscoveredServices = group.worktrees.some((worktree) => worktree.services.length > 0);
    const run = runs.runs.find((item) => item.projectId === project.id);
    const alive = Boolean(run?.pid && isProcessAlive(run.pid));
    const recentStart = run?.state === "starting" && Date.now() - Date.parse(run.startedAt) < 15_000;
    const state: SavedProjectStatus["state"] = alive
      ? recentStart && !hasDiscoveredServices ? "starting" : "running"
      : hasDiscoveredServices
        ? "external"
        : run?.state === "failed"
          ? "failed"
          : "stopped";

    savedGroups.push({
      ...group,
      projectName: project.name,
      repoRoot: group.repoRoot ?? project.path,
      savedProject: {
        id: project.id,
        state,
        ...(project.port !== undefined ? { port: project.port } : {}),
        supportsPortSwitching: project.command.includes("{port}"),
        logPath: projectLogPath(project.id, options),
        ...(run?.lastError ? { lastError: run.lastError } : {}),
        ...(run?.previousPort !== undefined ? { previousPort: run.previousPort } : {})
      }
    });
  }

  return { ...status, groups: [...savedGroups, ...remainingGroups], unknown: remainingUnknown };
}

export function projectLogPath(projectId: string, options: ProjectStorageOptions = {}): string {
  return path.join(projectStoragePaths(options).logs, `${safeFileComponent(projectId)}.log`);
}

export function renderProjectCommand(project: SavedProject, port = project.port): string {
  if (!project.command.includes("{port}")) {
    return project.command;
  }
  if (port === undefined) {
    throw new ProjectConfigurationError("This project needs a port.");
  }
  validatePort(port);
  return project.command.replaceAll("{port}", String(port));
}

export function findSavedProject(file: SavedProjectsFile, projectId: string): SavedProject {
  const project = file.projects.find((item) => item.id === projectId);
  if (!project) {
    throw new ProjectConfigurationError("Saved project not found.");
  }
  return project;
}

export function validatePort(port: number): void {
  if (!Number.isInteger(port) || port < MIN_PROJECT_PORT || port > MAX_PROJECT_PORT) {
    throw new ProjectConfigurationError(`Port must be between ${MIN_PROJECT_PORT} and ${MAX_PROJECT_PORT}.`);
  }
}

export function safeProjectError(error: unknown): string {
  const message = error instanceof Error ? error.message : "Saved projects unavailable.";
  return message.replace(/\s+/g, " ").trim().slice(0, 280) || "Saved projects unavailable.";
}

export function isProcessAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) {
    return false;
  }
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function validateAndNormalizeProject(input: unknown): Promise<SavedProject> {
  if (!input || typeof input !== "object") {
    throw new ProjectConfigurationError("Saved project data is invalid.");
  }
  const value = input as Partial<SavedProject>;
  const name = typeof value.name === "string" ? value.name.trim() : "";
  const command = typeof value.command === "string" ? value.command.trim() : "";
  if (!name || name.length > 80) {
    throw new ProjectConfigurationError("Project name must be between 1 and 80 characters.");
  }
  if (!command || command.length > 2_000 || /[\r\n\0]/.test(command)) {
    throw new ProjectConfigurationError("Launch command must be one line between 1 and 2,000 characters.");
  }
  const canonicalPath = await canonicalProjectDirectory(typeof value.path === "string" ? value.path : "");
  const id = typeof value.id === "string" && /^[A-Za-z0-9._-]{1,100}$/.test(value.id)
    ? value.id
    : randomUUID();
  const hasPortToken = command.includes("{port}");
  if (hasPortToken && value.port === undefined) {
    throw new ProjectConfigurationError("Commands containing {port} need a primary port.");
  }
  if (!hasPortToken && value.port !== undefined) {
    throw new ProjectConfigurationError("Remove the primary port or add {port} to the launch command.");
  }
  if (value.port !== undefined) {
    validatePort(value.port);
  }
  return {
    id,
    name,
    path: canonicalPath,
    command,
    ...(value.port !== undefined ? { port: value.port } : {})
  };
}

function validateProjectsFile(decoded: unknown, filePath: string): SavedProjectsFile {
  if (!decoded || typeof decoded !== "object") {
    throw new ProjectConfigurationError(`Invalid saved project data in ${filePath}. The file was left unchanged.`);
  }
  const file = decoded as Partial<SavedProjectsFile>;
  if (file.schemaVersion !== PROJECTS_SCHEMA_VERSION || !Array.isArray(file.projects)) {
    throw new ProjectConfigurationError(`Unsupported saved project data in ${filePath}. The file was left unchanged.`);
  }
  const projects: SavedProject[] = [];
  const ids = new Set<string>();
  const paths = new Set<string>();
  for (const candidate of file.projects) {
    if (!isSavedProject(candidate) || ids.has(candidate.id) || paths.has(candidate.path)) {
      throw new ProjectConfigurationError(`Invalid saved project data in ${filePath}. The file was left unchanged.`);
    }
    ids.add(candidate.id);
    paths.add(candidate.path);
    projects.push(candidate);
  }
  return { schemaVersion: PROJECTS_SCHEMA_VERSION, projects };
}

function isSavedProject(candidate: unknown): candidate is SavedProject {
  if (!candidate || typeof candidate !== "object") return false;
  const value = candidate as Partial<SavedProject>;
  return typeof value.id === "string"
    && typeof value.name === "string"
    && typeof value.path === "string"
    && path.isAbsolute(value.path)
    && typeof value.command === "string"
    && (value.port === undefined || (Number.isInteger(value.port) && value.port >= MIN_PROJECT_PORT && value.port <= MAX_PROJECT_PORT))
    && (value.command.includes("{port}") === (value.port !== undefined));
}

async function writeProjectsFile(file: SavedProjectsFile, options: ProjectStorageOptions): Promise<void> {
  const paths = projectStoragePaths(options);
  await ensurePrivateDirectory(paths.root);
  await atomicWriteJSON(paths.projects, file);
}

async function writeRunStateFile(file: ProjectRunStateFile, options: ProjectStorageOptions): Promise<void> {
  const paths = projectStoragePaths(options);
  await ensurePrivateDirectory(paths.root);
  await atomicWriteJSON(paths.runState, file);
}

async function atomicWriteJSON(filePath: string, value: unknown): Promise<void> {
  const temporaryPath = `${filePath}.${process.pid}.${randomUUID()}.tmp`;
  await writeFile(temporaryPath, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await chmod(temporaryPath, 0o600);
  try {
    await rename(temporaryPath, filePath);
  } catch (error) {
    await unlink(temporaryPath).catch(() => undefined);
    throw error;
  }
  await chmod(filePath, 0o600);
}

async function ensurePrivateDirectory(directory: string): Promise<void> {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await chmod(directory, 0o700);
}

async function canonicalProjectDirectory(rawPath: string): Promise<string> {
  if (!rawPath.trim()) {
    throw new ProjectConfigurationError("Choose a project folder.");
  }
  let canonicalPath: string;
  try {
    canonicalPath = await realpath(path.resolve(rawPath));
    const metadata = await stat(canonicalPath);
    if (!metadata.isDirectory()) throw new Error("not a directory");
  } catch {
    throw new ProjectConfigurationError("Project folder does not exist or is not accessible.");
  }
  return canonicalPath;
}

type PackageManifest = {
  name?: string;
  scripts?: Record<string, string>;
  dependencies?: Record<string, string>;
  devDependencies?: Record<string, string>;
  workspaces?: string[] | { packages?: string[] };
};

async function readPackageManifest(filePath: string): Promise<PackageManifest | undefined> {
  try {
    const decoded = JSON.parse(await readFile(filePath, "utf8")) as PackageManifest;
    return decoded && typeof decoded === "object" ? decoded : undefined;
  } catch {
    return undefined;
  }
}

async function detectPackageManager(root: string): Promise<"npm" | "pnpm" | "yarn" | "bun"> {
  if (await fileExists(path.join(root, "bun.lock")) || await fileExists(path.join(root, "bun.lockb"))) return "bun";
  if (await fileExists(path.join(root, "pnpm-lock.yaml"))) return "pnpm";
  if (await fileExists(path.join(root, "yarn.lock"))) return "yarn";
  return "npm";
}

function addPackageSuggestions(
  suggestions: ProjectSuggestion[],
  manifest: PackageManifest,
  manager: "npm" | "pnpm" | "yarn" | "bun",
  relativePath: string
): void {
  const scripts = manifest.scripts ?? {};
  for (const script of ["dev", "start", "serve"]) {
    if (typeof scripts[script] !== "string") continue;
    const framework = detectedFramework(manifest);
    const supportsPort = script === "dev" && framework !== undefined;
    const baseCommand = packageScriptCommand(manager, script, relativePath);
    const command = supportsPort ? appendPortArgument(baseCommand, manager) : baseCommand;
    const workspace = relativePath === "." ? "" : ` · ${relativePath}`;
    suggestions.push({
      id: `package-${relativePath}-${script}`.replaceAll(path.sep, "-"),
      title: `${script === "dev" ? "Development" : script[0]!.toUpperCase() + script.slice(1)}${workspace}`,
      detail: [manifest.name, framework, `${manager} ${script}`].filter(Boolean).join(" · "),
      command,
      ...(supportsPort ? { port: defaultFrameworkPort(framework) } : {}),
      source: "package"
    });
  }
}

function observedProjectSuggestions(
  projectRoot: string,
  services: PortdeckService[]
): ProjectSuggestion[] {
  const suggestions: ProjectSuggestion[] = [];

  for (const service of services) {
    if (service.source !== "process" || !service.command) continue;
    const tokens = tokenizeObservedCommand(service.command);
    if (!tokens?.length) continue;

    const packageSuggestion = observedPackageSuggestion(projectRoot, service, tokens);
    if (packageSuggestion) suggestions.push(packageSuggestion);

    const unitySuggestion = observedUnitySuggestion(projectRoot, tokens);
    if (unitySuggestion) suggestions.push(unitySuggestion);
  }

  return uniqueSuggestions(suggestions);
}

function observedPackageSuggestion(
  projectRoot: string,
  service: PortdeckService,
  tokens: string[]
): ProjectSuggestion | undefined {
  const commandTokens = unwrappedCommandTokens(tokens);
  const manager = path.basename(commandTokens[0] ?? "");
  if (!(["npm", "pnpm", "yarn", "bun"] as const).includes(manager as "npm" | "pnpm" | "yarn" | "bun")) {
    return undefined;
  }

  const runIndex = commandTokens.indexOf("run");
  const script = runIndex >= 0 ? commandTokens[runIndex + 1] : commandTokens[1];
  if (!script || !["dev", "start", "serve"].includes(script)) return undefined;

  const workingPath = service.subcontext?.path ?? service.cwd ?? projectRoot;
  const relativeWorkingPath = isWithin(projectRoot, workingPath)
    ? path.relative(comparablePath(projectRoot), comparablePath(workingPath)) || "."
    : ".";
  const typedManager = manager as "npm" | "pnpm" | "yarn" | "bun";
  return {
    id: `observed-${typedManager}-${script}-${safeFileComponent(relativeWorkingPath)}`,
    title: `Observed ${script === "dev" ? "development" : script} command`,
    detail: `${typedManager} ${script} · normalized from a running process`,
    command: packageScriptCommand(typedManager, script, relativeWorkingPath),
    source: "observed"
  };
}

function observedUnitySuggestion(
  projectRoot: string,
  tokens: string[]
): ProjectSuggestion | undefined {
  const executable = tokens[0];
  if (!executable
    || !executable.startsWith("/Applications/Unity/Hub/Editor/")
    || !executable.endsWith("/Unity.app/Contents/MacOS/Unity")
    || tokens.some((token) => token.toLowerCase() === "-batchmode")) {
    return undefined;
  }

  const projectPathIndex = tokens.findIndex((token) => token.toLowerCase() === "-projectpath");
  const rawProjectPath = projectPathIndex >= 0 ? tokens[projectPathIndex + 1] : undefined;
  if (!rawProjectPath) return undefined;
  const absoluteProjectPath = path.isAbsolute(rawProjectPath)
    ? rawProjectPath
    : path.resolve(projectRoot, rawProjectPath);
  if (!isWithin(projectRoot, absoluteProjectPath)) return undefined;

  const relativeProjectPath = path.relative(comparablePath(projectRoot), comparablePath(absoluteProjectPath)) || ".";
  const version = executable.split("/")[5] ?? "installed version";
  return {
    id: `observed-unity-${safeFileComponent(version)}-${safeFileComponent(relativeProjectPath)}`,
    title: "Unity Editor",
    detail: `Observed Unity ${version} · session flags removed`,
    command: `${shellQuote(executable)} -projectPath ${shellQuote(relativeProjectPath)}`,
    source: "observed"
  };
}

function unwrappedCommandTokens(tokens: string[]): string[] {
  let start = 0;
  if (path.basename(tokens[start] ?? "") === "env") {
    start += 1;
    while (/^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[start] ?? "")) start += 1;
  }
  if (["sh", "bash", "zsh"].includes(path.basename(tokens[start] ?? "")) && tokens[start + 1] === "-c") {
    start += 2;
    const shellTokens = tokens.slice(start);
    if (shellTokens.length === 1) {
      return tokenizeObservedCommand(shellTokens[0]!) ?? [];
    }
  }
  return tokens.slice(start);
}

function tokenizeObservedCommand(command: string): string[] | undefined {
  if (!command || command.length > 10_000 || /[\r\n\0]/.test(command)) return undefined;
  const tokens: string[] = [];
  let token = "";
  let quote: "'" | '"' | undefined;
  let escaped = false;

  for (const character of command.trim()) {
    if (escaped) {
      token += character;
      escaped = false;
    } else if (character === "\\" && quote !== "'") {
      escaped = true;
    } else if (quote) {
      if (character === quote) quote = undefined;
      else token += character;
    } else if (character === "'" || character === '"') {
      quote = character;
    } else if (/\s/.test(character)) {
      if (token) {
        tokens.push(token);
        token = "";
      }
    } else {
      token += character;
    }
  }

  if (escaped || quote) return undefined;
  if (token) tokens.push(token);
  return tokens;
}

function packageScriptCommand(
  manager: "npm" | "pnpm" | "yarn" | "bun",
  script: string,
  relativePath: string
): string {
  if (relativePath === ".") return `${manager} run ${script}`;
  const quoted = shellQuote(relativePath);
  switch (manager) {
  case "npm": return `npm --prefix ${quoted} run ${script}`;
  case "pnpm": return `pnpm --dir ${quoted} run ${script}`;
  case "yarn": return `yarn --cwd ${quoted} run ${script}`;
  case "bun": return `bun --cwd ${quoted} run ${script}`;
  }
}

function appendPortArgument(command: string, manager: "npm" | "pnpm" | "yarn" | "bun"): string {
  return manager === "yarn" ? `${command} --port {port}` : `${command} -- --port {port}`;
}

function detectedFramework(manifest: PackageManifest): "Next.js" | "Vite" | "Astro" | undefined {
  const dependencies = { ...manifest.dependencies, ...manifest.devDependencies };
  if (dependencies.next) return "Next.js";
  if (dependencies.astro) return "Astro";
  if (dependencies.vite || dependencies["@remix-run/dev"]) return "Vite";
  return undefined;
}

function defaultFrameworkPort(framework: "Next.js" | "Vite" | "Astro"): number {
  if (framework === "Next.js") return 3000;
  if (framework === "Astro") return 4321;
  return 5173;
}

async function workspaceDirectories(root: string, rawWorkspaces: PackageManifest["workspaces"]): Promise<string[]> {
  const patterns = Array.isArray(rawWorkspaces) ? rawWorkspaces : rawWorkspaces?.packages ?? [];
  const directories: string[] = [];
  for (const pattern of patterns) {
    if (typeof pattern !== "string" || pattern.startsWith("../") || path.isAbsolute(pattern)) continue;
    if (pattern.endsWith("/*")) {
      const parent = path.join(root, pattern.slice(0, -2));
      try {
        for (const entry of await readdir(parent, { withFileTypes: true })) {
          if (entry.isDirectory()) directories.push(path.join(parent, entry.name));
        }
      } catch {
        // Missing optional workspace directories are ignored.
      }
    } else if (!pattern.includes("*")) {
      directories.push(path.join(root, pattern));
    }
  }
  return directories.sort();
}

function groupMatchesProject(group: ProjectGroup, projectPath: string): boolean {
  if (samePath(group.repoRoot, projectPath)) return true;
  return group.worktrees.some((worktree) =>
    samePath(worktree.path, projectPath)
      || worktree.services.some((service) => isWithin(projectPath, service.cwd))
  );
}

function emptySavedProjectGroup(project: SavedProject): ProjectGroup {
  return {
    projectName: project.name,
    repoRoot: project.path,
    worktrees: [{ name: path.basename(project.path), path: project.path, services: [] }]
  };
}

function attachServicesToSavedGroup(
  group: ProjectGroup,
  project: SavedProject,
  services: PortdeckStatus["unknown"]
): ProjectGroup {
  const worktrees = group.worktrees.map((worktree) => ({ ...worktree, services: [...worktree.services] }));
  let targetIndex = worktrees.findIndex((worktree) => samePath(worktree.path, project.path));
  if (targetIndex < 0) {
    targetIndex = worktrees.findIndex((worktree) =>
      services.some((service) => isWithin(worktree.path ?? "", service.cwd))
    );
  }
  if (targetIndex < 0) {
    worktrees.push({ name: path.basename(project.path), path: project.path, services: [] });
    targetIndex = worktrees.length - 1;
  }
  const existingIDs = new Set(worktrees[targetIndex]!.services.map((service) => service.id));
  worktrees[targetIndex]!.services.push(...services.filter((service) => !existingIDs.has(service.id)));
  return { ...group, worktrees };
}

function samePath(left: string | undefined, right: string): boolean {
  return Boolean(left && comparablePath(left) === comparablePath(right));
}

function isWithin(basePath: string, targetPath: string | undefined): boolean {
  if (!basePath || !targetPath) return false;
  const relative = path.relative(comparablePath(basePath), comparablePath(targetPath));
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function comparablePath(value: string): string {
  try {
    return realpathSync.native(value);
  } catch {
    return path.resolve(value);
  }
}

function emptyProjectsFile(): SavedProjectsFile {
  return { schemaVersion: PROJECTS_SCHEMA_VERSION, projects: [] };
}

function emptyRunStateFile(): ProjectRunStateFile {
  return { schemaVersion: PROJECTS_SCHEMA_VERSION, runs: [] };
}

function isProjectRunRecord(candidate: unknown): candidate is ProjectRunRecord {
  if (!candidate || typeof candidate !== "object") return false;
  const value = candidate as Partial<ProjectRunRecord>;
  return typeof value.projectId === "string"
    && ["starting", "running", "failed"].includes(value.state ?? "")
    && typeof value.startedAt === "string"
    && (value.pid === undefined || (Number.isInteger(value.pid) && value.pid > 0));
}

function isMissingFileError(error: unknown): boolean {
  return Boolean(error && typeof error === "object" && "code" in error && error.code === "ENOENT");
}

async function fileExists(filePath: string): Promise<boolean> {
  try {
    await access(filePath, fsConstants.F_OK);
    return true;
  } catch {
    return false;
  }
}

async function isExecutableFile(filePath: string): Promise<boolean> {
  try {
    const metadata = await stat(filePath);
    await access(filePath, fsConstants.X_OK);
    return metadata.isFile();
  } catch {
    return false;
  }
}

function normalizedPackageDisplayName(name: string | undefined): string | undefined {
  if (!name?.trim()) return undefined;
  return name.trim().replace(/^@[^/]+\//, "");
}

function uniqueSuggestions(suggestions: ProjectSuggestion[]): ProjectSuggestion[] {
  const commands = new Set<string>();
  return suggestions.filter((suggestion) => {
    if (commands.has(suggestion.command)) return false;
    commands.add(suggestion.command);
    return true;
  });
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'"'"'`)}'`;
}

function humanizeScriptName(value: string): string {
  return value.replace(/\.sh$/, "").split("-").map((part) => part[0]!.toUpperCase() + part.slice(1)).join(" ");
}

function safeFileComponent(value: string): string {
  return value.replace(/[^A-Za-z0-9._-]/g, "-");
}
