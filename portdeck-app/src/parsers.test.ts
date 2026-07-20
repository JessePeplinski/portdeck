import { describe, expect, test } from "vitest";
import {
  parseDockerStatsJsonLines,
  parseDockerInspectPorts,
  parseDockerPsJsonLines,
  parseLsofListenOutput,
  parsePsActivityOutput,
  parsePsOutput
} from "./parsers.js";

describe("parseLsofListenOutput", () => {
  test("extracts field-mode listening TCP ports with full process names", () => {
    const output = [
      "p4941",
      "ccom.docker.backend",
      "f73",
      "PTCP",
      "n*:54321",
      "TST=LISTEN",
      "p62061",
      "cconvex-local-backend",
      "f14",
      "PTCP",
      "n*:3210",
      "TST=LISTEN"
    ].join("\n");

    expect(parseLsofListenOutput(output)).toEqual([
      {
        pid: 4941,
        processName: "com.docker.backend",
        port: 54321,
        protocol: "TCP",
        address: "*"
      },
      {
        pid: 62061,
        processName: "convex-local-backend",
        port: 3210,
        protocol: "TCP",
        address: "*"
      }
    ]);
  });

  test("preserves field-mode ports across distinct address bindings", () => {
    const output = [
      "p1234",
      "cnode",
      "f21",
      "PTCP",
      "n127.0.0.1:3000",
      "TST=LISTEN",
      "f22",
      "PTCP",
      "n[::1]:3000",
      "TST=LISTEN"
    ].join("\n");

    expect(parseLsofListenOutput(output)).toEqual([
      {
        pid: 1234,
        processName: "node",
        port: 3000,
        protocol: "TCP",
        address: "127.0.0.1"
      },
      {
        pid: 1234,
        processName: "node",
        port: 3000,
        protocol: "TCP",
        address: "::1"
      }
    ]);
  });

  test("extracts listening localhost TCP ports with process identity", () => {
    const output = [
      "COMMAND   PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME",
      "node    1234 jesse   22u  IPv4 0xabc123      0t0  TCP 127.0.0.1:3000 (LISTEN)",
      "python  5678 jesse    4u  IPv6 0xdef456      0t0  TCP [::1]:8000 (LISTEN)"
    ].join("\n");

    expect(parseLsofListenOutput(output)).toEqual([
      {
        pid: 1234,
        processName: "node",
        port: 3000,
        protocol: "TCP",
        address: "127.0.0.1"
      },
      {
        pid: 5678,
        processName: "python",
        port: 8000,
        protocol: "TCP",
        address: "::1"
      }
    ]);
  });

  test("ignores non-listening rows and rows without ports", () => {
    const output = [
      "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME",
      "node 42 jesse 12u IPv4 0xabc 0t0 TCP 127.0.0.1:3000->127.0.0.1:61000 (ESTABLISHED)",
      "Control 99 jesse 7u IPv4 0xdef 0t0 TCP *:* (LISTEN)"
    ].join("\n");

    expect(parseLsofListenOutput(output)).toEqual([]);
  });

  test("preserves the same pid and port across multiple address bindings", () => {
    const output = [
      "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME",
      "node 1234 jesse 22u IPv4 0xabc 0t0 TCP 127.0.0.1:3000 (LISTEN)",
      "node 1234 jesse 23u IPv6 0xdef 0t0 TCP [::1]:3000 (LISTEN)"
    ].join("\n");

    expect(parseLsofListenOutput(output)).toEqual([
      {
        pid: 1234,
        processName: "node",
        port: 3000,
        protocol: "TCP",
        address: "127.0.0.1"
      },
      {
        pid: 1234,
        processName: "node",
        port: 3000,
        protocol: "TCP",
        address: "::1"
      }
    ]);
  });

  test("deduplicates exact repeated address bindings", () => {
    const output = [
      "p1234",
      "cnode",
      "f21",
      "PTCP",
      "n127.0.0.1:3000",
      "TST=LISTEN",
      "f22",
      "PTCP",
      "n127.0.0.1:3000",
      "TST=LISTEN"
    ].join("\n");

    expect(parseLsofListenOutput(output)).toEqual([
      {
        pid: 1234,
        processName: "node",
        port: 3000,
        protocol: "TCP",
        address: "127.0.0.1"
      }
    ]);
  });
});

describe("parsePsOutput", () => {
  test("extracts process command lines and derives executable names by pid", () => {
    const output = [
      "  PID COMMAND",
      " 1234 node /repo/node_modules/.bin/vite dev --host 127.0.0.1",
      " 5678 /Applications/Docker.app/Contents/MacOS/com.docker.backend services",
      " 62061 /Users/jesse/.cache/convex/convex-local-backend --port 3210"
    ].join("\n");

    expect(parsePsOutput(output)).toEqual(
      new Map([
        [1234, { pid: 1234, processName: "node", command: "node /repo/node_modules/.bin/vite dev --host 127.0.0.1" }],
        [
          5678,
          {
            pid: 5678,
            processName: "com.docker.backend",
            command: "/Applications/Docker.app/Contents/MacOS/com.docker.backend services"
          }
        ],
        [
          62061,
          {
            pid: 62061,
            processName: "convex-local-backend",
            command: "/Users/jesse/.cache/convex/convex-local-backend --port 3210"
          }
        ]
      ])
    );
  });
});

describe("parsePsActivityOutput", () => {
  test("extracts process CPU percent and RSS bytes by pid", () => {
    const output = [
      "  PID  %CPU    RSS",
      " 1234   4.5  153600",
      " 5678   0.0    2048"
    ].join("\n");

    expect(parsePsActivityOutput(output)).toEqual(
      new Map([
        [1234, { cpuPercent: 4.5, memoryRssBytes: 157286400 }],
        [5678, { cpuPercent: 0, memoryRssBytes: 2097152 }]
      ])
    );
  });

  test("ignores malformed process activity rows", () => {
    const output = [
      "  PID  %CPU    RSS",
      " nope   4.5  153600",
      " 1234   CPU  153600",
      " 5678   0.1  RSS"
    ].join("\n");

    expect(parsePsActivityOutput(output)).toEqual(new Map());
  });
});

describe("Docker parsers", () => {
  test("parses docker ps JSON lines", () => {
    const output = [
      JSON.stringify({
        ID: "abc123",
        Names: "portdeck-postgres-1",
        Image: "postgres:16",
        Ports: "127.0.0.1:5432->5432/tcp"
      }),
      JSON.stringify({
        ID: "def456",
        Names: "redis",
        Image: "redis:7",
        Ports: ""
      })
    ].join("\n");

    expect(parseDockerPsJsonLines(output)).toEqual([
      {
        id: "abc123",
        name: "portdeck-postgres-1",
        image: "postgres:16",
        ports: "127.0.0.1:5432->5432/tcp"
      },
      {
        id: "def456",
        name: "redis",
        image: "redis:7",
        ports: ""
      }
    ]);
  });

  test("extracts published ports from docker inspect NetworkSettings.Ports", () => {
    const inspect = [
      {
        Id: "abc123",
        Name: "/portdeck-postgres-1",
        Config: {
          Image: "postgres:16",
          WorkingDir: "/workspace/apps/web",
          Labels: {
            "com.docker.compose.project": "portdeck",
            "com.docker.compose.project.working_dir": "/repo/portdeck",
            "com.docker.compose.project.config_files": "/repo/portdeck/docker-compose.yml,/repo/portdeck/docker-compose.override.yml"
          }
        },
        Mounts: [
          {
            Type: "bind",
            Source: "/repo/portdeck/apps/web",
            Destination: "/workspace/apps/web",
            Mode: "rw",
            RW: true
          }
        ],
        NetworkSettings: {
          Ports: {
            "5432/tcp": [{ HostIp: "127.0.0.1", HostPort: "5432" }],
            "8080/tcp": null
          }
        }
      }
    ];

    expect(parseDockerInspectPorts(inspect)).toEqual([
      {
        containerId: "abc123",
        containerName: "portdeck-postgres-1",
        image: "postgres:16",
        hostIp: "127.0.0.1",
        hostPort: 5432,
        containerPort: 5432,
        protocol: "tcp",
        labels: {
          "com.docker.compose.project": "portdeck",
          "com.docker.compose.project.working_dir": "/repo/portdeck",
          "com.docker.compose.project.config_files": "/repo/portdeck/docker-compose.yml,/repo/portdeck/docker-compose.override.yml"
        },
        composeProjectWorkingDir: "/repo/portdeck",
        composeConfigFiles: ["/repo/portdeck/docker-compose.yml", "/repo/portdeck/docker-compose.override.yml"],
        containerWorkingDir: "/workspace/apps/web",
        mounts: [
          {
            type: "bind",
            source: "/repo/portdeck/apps/web",
            destination: "/workspace/apps/web",
            mode: "rw",
            rw: true
          }
        ]
      }
    ]);
  });

  test("preserves Docker bindings that expose the same host port on distinct host IPs", () => {
    const inspect = [
      {
        Id: "abc123",
        Name: "/postgres",
        Config: { Image: "postgres:16", Labels: {} },
        NetworkSettings: {
          Ports: {
            "5432/tcp": [
              { HostIp: "127.0.0.1", HostPort: "5432" },
              { HostIp: "::", HostPort: "5432" }
            ]
          }
        }
      }
    ];

    expect(parseDockerInspectPorts(inspect)).toEqual([
      expect.objectContaining({
        hostIp: "127.0.0.1",
        hostPort: 5432
      }),
      expect.objectContaining({
        hostIp: "::",
        hostPort: 5432
      })
    ]);
  });

  test("deduplicates exact repeated Docker host IP bindings", () => {
    const inspect = [
      {
        Id: "abc123",
        Name: "/postgres",
        Config: { Image: "postgres:16", Labels: {} },
        NetworkSettings: {
          Ports: {
            "5432/tcp": [
              { HostIp: "127.0.0.1", HostPort: "5432" },
              { HostIp: "127.0.0.1", HostPort: "5432" }
            ]
          }
        }
      }
    ];

    expect(parseDockerInspectPorts(inspect)).toHaveLength(1);
  });

  test("parses Docker stats JSON lines into CPU and memory bytes", () => {
    const output = [
      JSON.stringify({
        ID: "abc123",
        CPUPerc: "2.34%",
        MemUsage: "120.5MiB / 1GiB"
      }),
      JSON.stringify({
        ID: "def456",
        CPUPerc: "0.00%",
        MemUsage: "42MB / 512MB"
      })
    ].join("\n");

    expect(parseDockerStatsJsonLines(output)).toEqual(
      new Map([
        [
          "abc123",
          {
            cpuPercent: 2.34,
            memoryUsageBytes: 126353408,
            memoryLimitBytes: 1073741824
          }
        ],
        [
          "def456",
          {
            cpuPercent: 0,
            memoryUsageBytes: 42000000,
            memoryLimitBytes: 512000000
          }
        ]
      ])
    );
  });

  test("ignores malformed Docker stats rows without throwing", () => {
    const output = [
      JSON.stringify({ ID: "abc123", CPUPerc: "nope", MemUsage: "120MiB / 1GiB" }),
      JSON.stringify({ ID: "def456", CPUPerc: "2.1%", MemUsage: "bad" }),
      "{not json"
    ].join("\n");

    expect(parseDockerStatsJsonLines(output)).toEqual(new Map());
  });
});
