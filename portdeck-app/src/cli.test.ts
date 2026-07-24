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

  test("rejects removed project commands", async () => {
    const stderr = new TestWriter();
    const code = await runPortdeckCli(["projects", "list", "--json"], { stderr });

    expect(code).toBe(1);
    expect(stderr.text()).toContain("portdeck status --json");
    expect(stderr.text()).not.toContain("portdeck projects");
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
    schemaVersion: "0.2",
    generatedAt: "2026-06-09T00:00:00.000Z",
    groups: [],
    unknown: [],
    warnings: []
  };
}
