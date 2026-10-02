import { describe, expect, test, vi } from "vitest";
import { discover } from "./discovery.js";

const activity = vi.hoisted(() => ({ active: 0, peak: 0, cwdCalls: 0, gitCalls: 0 }));
const pids = Array.from({ length: 40 }, (_, index) => 1000 + index);

vi.mock("./ngrok.js", () => ({ discoverNgrokExposures: async () => [] }));
vi.mock("execa", () => ({
  execa: async (command: string, args: string[]) => {
    if (command === "lsof" && args.includes("-iTCP")) {
      return { stdout: pids.map((pid) => `p${pid}\ncnode\nf1\nPTCP\nn127.0.0.1:${pid + 2000}\nTST=LISTEN`).join("\n") };
    }
    if (command === "ps") {
      return { stdout: args.includes("pid=,etime=,command=") ? pids.map((pid) => `${pid} 00:10 node server.js`).join("\n") : "" };
    }
    if (command === "docker") return { stdout: "" };
    activity.active += 1;
    activity.peak = Math.max(activity.peak, activity.active);
    try {
      await new Promise((resolve) => setTimeout(resolve, 2));
      if (command === "lsof") {
        activity.cwdCalls += 1;
        return { stdout: `n/fixture/project-${args[args.indexOf("-p") + 1]}` };
      }
      activity.gitCalls += 1;
      const cwd = args[1];
      if (args.includes("--show-toplevel")) return { stdout: cwd };
      if (args.includes("--show-current")) return { stdout: "main" };
      if (args.includes("worktree")) return { stdout: `worktree ${cwd}\nbranch refs/heads/main\n` };
      return { stdout: "https://github.com/example/demo.git" };
    } finally {
      activity.active -= 1;
    }
  }
}));

describe("discovery resource usage", () => {
  test("bounds concurrent process and Git inspections without dropping services", async () => {
    activity.active = activity.peak = activity.cwdCalls = activity.gitCalls = 0;
    const result = await discover();
    expect(result.processPorts).toHaveLength(40);
    expect(result.processes.size).toBe(40);
    expect(result.gitByCwd.size).toBe(40);
    expect(activity.cwdCalls).toBe(40);
    expect(activity.gitCalls).toBe(160);
    expect(activity.peak).toBeLessThanOrEqual(4);
    expect(activity.active).toBe(0);
  });
});
