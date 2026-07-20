import { execa } from "execa";
import { getPortdeckStatus } from "./discovery.js";
import type { PortdeckService, PortdeckStatus } from "./types.js";

export type StopActionResult = {
  ok: boolean;
  serviceId: string;
  action: "stop";
  message: string;
};

export type StopServiceOptions = {
  getStatus?: () => Promise<PortdeckStatus>;
  sendSignal?: (pid: number, signal: NodeJS.Signals) => Promise<void> | void;
  stopDockerContainer?: (containerId: string) => Promise<void>;
};

export async function stopServiceById(serviceId: string, options: StopServiceOptions = {}): Promise<StopActionResult> {
  const getStatus = options.getStatus ?? getPortdeckStatus;
  const sendSignal = options.sendSignal ?? defaultSendSignal;
  const stopDockerContainer = options.stopDockerContainer ?? defaultStopDockerContainer;

  let status: PortdeckStatus;
  try {
    status = await getStatus();
  } catch {
    return stopFailure(serviceId, "Status unavailable");
  }

  const service = findServiceById(status, serviceId);
  if (!service) {
    return stopFailure(serviceId, "Service not found");
  }

  if (service.status !== "running") {
    return stopFailure(serviceId, "Service is not running");
  }

  if (service.source === "process") {
    if (!isValidPid(service.pid)) {
      return stopFailure(serviceId, "Service owner unavailable");
    }

    try {
      await sendSignal(service.pid, "SIGTERM");
      return stopSuccess(service, serviceId);
    } catch (error) {
      return stopFailure(serviceId, isMissingProcessError(error) ? "Service is not running" : "Could not stop service");
    }
  }

  if (service.source === "docker") {
    if (!service.containerId) {
      return stopFailure(serviceId, "Service owner unavailable");
    }

    try {
      await stopDockerContainer(service.containerId);
      return stopSuccess(service, serviceId);
    } catch {
      return stopFailure(serviceId, "Docker unavailable");
    }
  }

  return stopFailure(serviceId, "Service owner unavailable");
}

function findServiceById(status: PortdeckStatus, serviceId: string): PortdeckService | undefined {
  return allServices(status).find((service) => service.id === serviceId);
}

function allServices(status: PortdeckStatus): PortdeckService[] {
  return [
    ...status.groups.flatMap((group) => group.worktrees.flatMap((worktree) => worktree.services)),
    ...status.unknown
  ];
}

function stopSuccess(service: PortdeckService, serviceId: string): StopActionResult {
  return {
    ok: true,
    serviceId,
    action: "stop",
    message: `Stopped ${formatStopTarget(service)}`
  };
}

function stopFailure(serviceId: string, message: string): StopActionResult {
  return {
    ok: false,
    serviceId,
    action: "stop",
    message
  };
}

function formatStopTarget(service: PortdeckService): string {
  const name = service.source === "docker" ? service.containerName ?? service.name : service.processName ?? service.name;
  if (service.port !== undefined) {
    return `${name} on :${service.port}`;
  }
  return name;
}

function isValidPid(pid: number | undefined): pid is number {
  return typeof pid === "number" && Number.isInteger(pid) && pid > 0;
}

function isMissingProcessError(error: unknown): boolean {
  return Boolean(error && typeof error === "object" && "code" in error && error.code === "ESRCH");
}

function defaultSendSignal(pid: number, signal: NodeJS.Signals): void {
  process.kill(pid, signal);
}

async function defaultStopDockerContainer(containerId: string): Promise<void> {
  await execa("docker", ["stop", containerId], { reject: true });
}
