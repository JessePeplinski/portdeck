import { describe, expect, test } from "vitest";
import { buildStatus } from "./status.js";
import type {
  DiscoveredDockerPort,
  DiscoveredProcessPort,
  GitInfo,
  PackageSubcontext,
  PortdeckService,
  PortdeckStatus,
  ProcessInfo
} from "./types.js";

function flattenServices(status: PortdeckStatus): PortdeckService[] {
  return [...status.groups.flatMap((group) => group.worktrees.flatMap((worktree) => worktree.services)), ...status.unknown];
}

describe("buildStatus", () => {
  test("groups process services by Git repo and worktree", async () => {
    const processPorts: DiscoveredProcessPort[] = [
      { pid: 1234, processName: "node", port: 3000, protocol: "TCP", address: "127.0.0.1" }
    ];
    const processes = new Map<number, ProcessInfo>([
      [1234, { pid: 1234, processName: "node", command: "npm run dev", cwd: "/repo/acme-web" }]
    ]);
    const gitByCwd = new Map<string, GitInfo>([
      [
        "/repo/acme-web",
        {
          repoRoot: "/repo/acme-web",
          branch: "main",
          worktreePath: "/repo/acme-web",
          worktreeName: "main"
        }
      ]
    ]);

    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts,
      processes,
      dockerPorts: [],
      gitByCwd,
      warnings: []
    });

    expect(status.groups).toEqual([
      {
        projectName: "acme-web",
        repoRoot: "/repo/acme-web",
        worktrees: [
          {
            name: "main",
            path: "/repo/acme-web",
            branch: "main",
            services: [
              {
                id: "pid-1234-port-3000",
                name: "web",
                source: "process",
                status: "running",
                port: 3000,
                url: "http://127.0.0.1:3000",
                address: "127.0.0.1",
                protocol: "TCP",
                listeners: [
                  {
                    address: "127.0.0.1",
                    family: "IPv4",
                    port: 3000,
                    url: "http://127.0.0.1:3000",
                    isWildcard: false,
                    isLoopback: true,
                    isPreferred: true
                  }
                ],
                pid: 1234,
                processName: "node",
                command: "npm run dev",
                cwd: "/repo/acme-web",
                confidence: "high"
              }
            ]
          }
        ]
      }
    ]);
    expect(status.unknown).toEqual([]);
  });

  test("keeps monorepo services under the worktree while adding package subcontext", async () => {
    const processPorts: DiscoveredProcessPort[] = [
      { pid: 2345, processName: "node", port: 3001, protocol: "TCP", address: "127.0.0.1" }
    ];
    const cwd = "/repo/monorepo/apps/web";
    const packageContext: PackageSubcontext = {
      type: "package",
      name: "@acme/web",
      displayName: "@acme/web",
      path: "/repo/monorepo/apps/web",
      relativePath: "apps/web",
      manifestPath: "/repo/monorepo/apps/web/package.json"
    };

    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts,
      processes: new Map([[2345, { pid: 2345, processName: "node", command: "npm run dev", cwd }]]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          cwd,
          {
            repoRoot: "/repo/monorepo",
            branch: "main",
            worktreePath: "/repo/monorepo",
            worktreeName: "main"
          }
        ]
      ]),
      packageByCwd: new Map([[cwd, packageContext]]),
      warnings: []
    });

    expect(status.groups).toEqual([
      {
        projectName: "monorepo",
        repoRoot: "/repo/monorepo",
        worktrees: [
          {
            name: "main",
            path: "/repo/monorepo",
            branch: "main",
            services: [
              expect.objectContaining({
                id: "pid-2345-port-3001",
                source: "process",
                port: 3001,
                cwd,
                subcontext: packageContext
              })
            ]
          }
        ]
      }
    ]);
  });

  test("copies Git remote metadata to project and worktree groups", async () => {
    const cwd = "/repo/portdeck";
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [{ pid: 2350, processName: "node", port: 3000, protocol: "TCP", address: "127.0.0.1" }],
      processes: new Map([[2350, { pid: 2350, processName: "node", command: "npm run dev", cwd }]]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          cwd,
          {
            repoRoot: cwd,
            branch: "main",
            worktreePath: cwd,
            worktreeName: "main",
            remoteUrl: "git@github.com:acme-inc/portdeck.git",
            repositoryUrl: "https://github.com/acme-inc/portdeck"
          }
        ]
      ]),
      warnings: []
    });

    expect(status.groups[0]).toEqual(
      expect.objectContaining({
        projectName: "portdeck",
        repoRoot: cwd,
        remoteUrl: "git@github.com:acme-inc/portdeck.git",
        repositoryUrl: "https://github.com/acme-inc/portdeck"
      })
    );
    expect(status.groups[0]?.worktrees[0]).toEqual(
      expect.objectContaining({
        name: "main",
        path: cwd,
        branch: "main",
        remoteUrl: "git@github.com:acme-inc/portdeck.git",
        repositoryUrl: "https://github.com/acme-inc/portdeck"
      })
    );
  });

  test("builds process service URLs from the listener address when it is specific", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [{ pid: 3456, processName: "node", port: 3000, protocol: "TCP", address: "127.0.0.1" }],
      processes: new Map([[3456, { pid: 3456, processName: "node", command: "next dev -H 127.0.0.1", cwd: "/repo/black-relay" }]]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          "/repo/black-relay",
          {
            repoRoot: "/repo/black-relay",
            branch: "main",
            worktreePath: "/repo/black-relay",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: []
    });

    const service = status.groups[0]?.worktrees[0]?.services[0];
    expect(service?.url).toBe("http://127.0.0.1:3000");
    expect(service?.listeners).toEqual([
      {
        address: "127.0.0.1",
        family: "IPv4",
        port: 3000,
        url: "http://127.0.0.1:3000",
        isWildcard: false,
        isLoopback: true,
        isPreferred: true
      }
    ]);
  });

  test("builds process service URLs from bracketed IPv6 loopback listeners", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [{ pid: 3457, processName: "node", port: 3000, protocol: "TCP", address: "::1" }],
      processes: new Map([[3457, { pid: 3457, processName: "node", command: "next dev -H ::1", cwd: "/repo/ipv6-app" }]]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          "/repo/ipv6-app",
          {
            repoRoot: "/repo/ipv6-app",
            branch: "main",
            worktreePath: "/repo/ipv6-app",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: []
    });

    const service = status.groups[0]?.worktrees[0]?.services[0];
    expect(service?.url).toBe("http://[::1]:3000");
    expect(service?.listeners).toEqual([
      {
        address: "::1",
        family: "IPv6",
        port: 3000,
        url: "http://[::1]:3000",
        isWildcard: false,
        isLoopback: true,
        isPreferred: true
      }
    ]);
  });

  test("falls back to localhost for wildcard process listener URLs", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [{ pid: 4567, processName: "node", port: 3000, protocol: "TCP", address: "*" }],
      processes: new Map([[4567, { pid: 4567, processName: "node", command: "next dev", cwd: "/repo/any-host" }]]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          "/repo/any-host",
          {
            repoRoot: "/repo/any-host",
            branch: "main",
            worktreePath: "/repo/any-host",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: []
    });

    const service = status.groups[0]?.worktrees[0]?.services[0];
    expect(service?.url).toBe("http://localhost:3000");
    expect(service?.listeners).toEqual([
      {
        address: "*",
        family: "unknown",
        port: 3000,
        url: "http://localhost:3000",
        isWildcard: true,
        isLoopback: false,
        isPreferred: true
      }
    ]);
  });

  test("keeps multiple listeners on one process service without reporting a collision", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [
        { pid: 3458, processName: "node", port: 3000, protocol: "TCP", address: "127.0.0.1" },
        { pid: 3458, processName: "node", port: 3000, protocol: "TCP", address: "::1" }
      ],
      processes: new Map([[3458, { pid: 3458, processName: "node", command: "next dev", cwd: "/repo/dual-stack-app" }]]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          "/repo/dual-stack-app",
          {
            repoRoot: "/repo/dual-stack-app",
            branch: "main",
            worktreePath: "/repo/dual-stack-app",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: []
    });

    const services = flattenServices(status);
    expect(services).toHaveLength(1);
    expect(services[0]?.url).toBe("http://127.0.0.1:3000");
    expect(services[0]?.listeners?.map((listener) => listener.url)).toEqual([
      "http://127.0.0.1:3000",
      "http://[::1]:3000"
    ]);
    expect(services[0]?.localhostCollision).toBeUndefined();
    expect(status.warnings).toEqual([]);
  });

  test("reports localhost collision metadata across distinct services on the same numeric port", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [
        { pid: 4001, processName: "node", port: 3000, protocol: "TCP", address: "127.0.0.1" },
        { pid: 4002, processName: "node", port: 3000, protocol: "TCP", address: "*" },
        { pid: 4003, processName: "node", port: 3000, protocol: "TCP", address: "::1" }
      ],
      processes: new Map([
        [4001, { pid: 4001, processName: "node", command: "npm run dev", cwd: "/repo/acme-api" }],
        [4002, { pid: 4002, processName: "node", command: "npm run dev", cwd: "/repo/acme-web" }],
        [4003, { pid: 4003, processName: "node", command: "npm run dev", cwd: "/repo/ipv6-only" }]
      ]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          "/repo/acme-api",
          {
            repoRoot: "/repo/acme-api",
            branch: "main",
            worktreePath: "/repo/acme-api",
            worktreeName: "main"
          }
        ],
        [
          "/repo/acme-web",
          {
            repoRoot: "/repo/acme-web",
            branch: "main",
            worktreePath: "/repo/acme-web",
            worktreeName: "main"
          }
        ],
        [
          "/repo/ipv6-only",
          {
            repoRoot: "/repo/ipv6-only",
            branch: "main",
            worktreePath: "/repo/ipv6-only",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: []
    });

    const servicesByProject = new Map(flattenServices(status).map((service) => [service.cwd?.split("/").at(-1), service]));
    const acmeApi = servicesByProject.get("acme-api");
    const acmeWeb = servicesByProject.get("acme-web");

    expect(acmeApi?.url).toBe("http://127.0.0.1:3000");
    expect(acmeWeb?.url).toBe("http://localhost:3000");
    expect(acmeApi?.localhostCollision).toEqual(
      expect.objectContaining({
        port: 3000,
        localhostUrl: "http://localhost:3000",
        message: "localhost:3000 may route to a different service than 127.0.0.1:3000"
      })
    );
    expect(acmeApi?.localhostCollision?.conflictsWith).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          serviceId: "pid-4002-port-3000",
          name: "web",
          projectName: "acme-web",
          worktreeName: "main",
          url: "http://localhost:3000",
          address: "*"
        })
      ])
    );
    expect(status.warnings).toContain(
      "localhost:3000 is ambiguous across 3 services; localhost may not match 127.0.0.1 or [::1]"
    );
  });

  test("adds endpoint health and port conflict incidents when localhost is unhealthy", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [
        { pid: 4301, processName: "node", port: 3000, protocol: "TCP", address: "127.0.0.1" },
        { pid: 4302, processName: "node", port: 3000, protocol: "TCP", address: "*" }
      ],
      processes: new Map([
        [4301, { pid: 4301, processName: "node", command: "npm run dev", cwd: "/repo/acme-api" }],
        [4302, { pid: 4302, processName: "node", command: "npm run dev", cwd: "/repo/acme-web" }]
      ]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          "/repo/acme-api",
          {
            repoRoot: "/repo/acme-api",
            branch: "main",
            worktreePath: "/repo/acme-api",
            worktreeName: "main"
          }
        ],
        [
          "/repo/acme-web",
          {
            repoRoot: "/repo/acme-web",
            branch: "main",
            worktreePath: "/repo/acme-web",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: [],
      probeEndpoints: async () =>
        new Map([
          [
            "http://localhost:3000",
            {
              url: "http://localhost:3000",
              status: "http-error",
              statusCode: 500,
              remoteAddress: "::1",
              latencyMs: 12
            }
          ],
          [
            "http://127.0.0.1:3000",
            {
              url: "http://127.0.0.1:3000",
              status: "ok",
              statusCode: 200,
              remoteAddress: "127.0.0.1",
              latencyMs: 8
            }
          ],
          [
            "http://[::1]:3000",
            {
              url: "http://[::1]:3000",
              status: "http-error",
              statusCode: 500,
              remoteAddress: "::1",
              latencyMs: 10
            }
          ]
        ])
    });

    const acmeApi = flattenServices(status).find((service) => service.cwd === "/repo/acme-api");
    const acmeWeb = flattenServices(status).find((service) => service.cwd === "/repo/acme-web");

    expect(acmeApi?.endpointHealth).toEqual(
      expect.objectContaining({
        url: "http://127.0.0.1:3000",
        status: "ok",
        statusCode: 200,
        remoteAddress: "127.0.0.1"
      })
    );
    expect(acmeWeb?.endpointHealth).toEqual(
      expect.objectContaining({
        url: "http://localhost:3000",
        status: "http-error",
        statusCode: 500,
        remoteAddress: "::1"
      })
    );
    expect(status.portConflicts).toEqual([
      {
        port: 3000,
        severity: "error",
        title: "Port 3000 conflict",
        message: "localhost:3000 returns HTTP 500 while 127.0.0.1:3000 returns 200 OK",
        endpoints: [
          expect.objectContaining({
            serviceId: "pid-4302-port-3000",
            projectName: "acme-web",
            url: "http://localhost:3000",
            health: expect.objectContaining({ status: "http-error", statusCode: 500 })
          }),
          expect.objectContaining({
            serviceId: "pid-4301-port-3000",
            projectName: "acme-api",
            url: "http://127.0.0.1:3000",
            health: expect.objectContaining({ status: "ok", statusCode: 200 })
          }),
          expect.objectContaining({
            url: "http://[::1]:3000",
            health: expect.objectContaining({ status: "http-error", statusCode: 500 })
          })
        ]
      }
    ]);
    expect(status.warnings).toContain(
      "Port 3000 conflict: localhost:3000 returns HTTP 500 while 127.0.0.1:3000 returns 200 OK"
    );
  });

  test("labels collision peers from cwd when Git grouping is unavailable", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [
        { pid: 4101, processName: "node", port: 3000, protocol: "TCP", address: "127.0.0.1" },
        { pid: 4102, processName: "node", port: 3000, protocol: "TCP", address: "*" }
      ],
      processes: new Map([
        [4101, { pid: 4101, processName: "node", command: "npm run dev", cwd: "/repo/acme-api" }],
        [
          4102,
          {
            pid: 4102,
            processName: "node",
            command: "npm run dev",
            cwd: "/Users/developer/.codex/worktrees/lab-account-settings/acme-web"
          }
        ]
      ]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          "/repo/acme-api",
          {
            repoRoot: "/repo/acme-api",
            branch: "main",
            worktreePath: "/repo/acme-api",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: []
    });

    const acmeApi = flattenServices(status).find((service) => service.cwd === "/repo/acme-api");

    expect(acmeApi?.localhostCollision?.conflictsWith).toEqual([
      expect.objectContaining({
        serviceId: "pid-4102-port-3000",
        projectName: "acme-web",
        url: "http://localhost:3000",
        address: "*"
      })
    ]);
  });

  test("groups process services from Codex worktree cwd when Git metadata is unavailable", async () => {
    const cwd = "/Users/developer/.codex/worktrees/lab-account-settings/acme-web";
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [
        { pid: 4201, processName: "node", port: 3000, protocol: "TCP", address: "*" },
        { pid: 4202, processName: "convex-local-backend", port: 3210, protocol: "TCP", address: "*" },
        { pid: 4202, processName: "convex-local-backend", port: 3211, protocol: "TCP", address: "*" }
      ],
      processes: new Map([
        [4201, { pid: 4201, processName: "node", command: "npm run dev", cwd }],
        [4202, { pid: 4202, processName: "convex-local-backend", command: "convex-local-backend --port 3210", cwd }]
      ]),
      dockerPorts: [],
      gitByCwd: new Map(),
      warnings: []
    });

    expect(status.unknown).toEqual([]);
    expect(status.groups).toEqual([
      expect.objectContaining({
        projectName: "acme-web",
        repoRoot: undefined,
        worktrees: [
          expect.objectContaining({
            name: "codex/lab-account-settings",
            path: cwd,
            branch: undefined,
            services: [
              expect.objectContaining({ id: "pid-4201-port-3000", port: 3000 }),
              expect.objectContaining({ id: "pid-4202-port-3210", port: 3210 }),
              expect.objectContaining({ id: "pid-4202-port-3211", port: 3211 })
            ]
          })
        ]
      })
    ]);
  });

  test("merges Codex fallback and Git worktrees with the same project name", async () => {
    const worktreeCwd = "/Users/developer/.codex/worktrees/lab-account-settings/acme-web";
    const gitCwd = "/Users/developer/git/acme-web";
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [
        { pid: 4401, processName: "node", port: 3000, protocol: "TCP", address: "*" },
        { pid: 4402, processName: "convex-local-backend", port: 3210, protocol: "TCP", address: "*" },
        { pid: 4403, processName: "ngrok", port: 4040, protocol: "TCP", address: "127.0.0.1" },
        { pid: 4404, processName: "node", port: 3001, protocol: "TCP", address: "127.0.0.1" }
      ],
      processes: new Map([
        [4401, { pid: 4401, processName: "node", command: "npm run dev", cwd: worktreeCwd }],
        [4402, { pid: 4402, processName: "convex-local-backend", command: "convex-local-backend --port 3210", cwd: worktreeCwd }],
        [4403, { pid: 4403, processName: "ngrok", command: "ngrok http 3000", cwd: gitCwd }],
        [4404, { pid: 4404, processName: "node", command: "npm run dev", cwd: gitCwd }]
      ]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          gitCwd,
          {
            repoRoot: gitCwd,
            branch: "main",
            worktreePath: gitCwd,
            worktreeName: "main"
          }
        ]
      ]),
      warnings: []
    });

    const acmeWebGroups = status.groups.filter((group) => group.projectName === "acme-web");
    expect(acmeWebGroups).toHaveLength(1);
    expect(acmeWebGroups[0]).toEqual(
      expect.objectContaining({
        projectName: "acme-web",
        repoRoot: gitCwd,
        worktrees: [
          expect.objectContaining({
            name: "codex/lab-account-settings",
            services: [
              expect.objectContaining({ id: "pid-4401-port-3000" }),
              expect.objectContaining({ id: "pid-4402-port-3210" })
            ]
          }),
          expect.objectContaining({
            name: "main",
            services: [expect.objectContaining({ id: "pid-4404-port-3001" })]
          })
        ]
      })
    );
    expect(status.unknown).toEqual([
      expect.objectContaining({
        id: "pid-4403-port-4040",
        name: "ngrok",
        groupingReason: "ngrok agent is machine-level; cwd is provenance only"
      })
    ]);
  });

  test("builds Docker service URLs from the published host IP when it is specific", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [],
      processes: new Map(),
      dockerPorts: [
        {
          containerId: "abc123",
          containerName: "black-relay-db-1",
          image: "postgres:16",
          hostIp: "127.0.0.1",
          hostPort: 5432,
          containerPort: 5432,
          protocol: "tcp",
          labels: { "com.docker.compose.project": "black-relay" }
        }
      ],
      gitByCwd: new Map(),
      warnings: []
    });

    expect(status.groups[0]?.worktrees[0]?.services[0]?.url).toBe("http://127.0.0.1:5432");
  });

  test("attaches process activity metrics by pid", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [{ pid: 1234, processName: "node", port: 3000, protocol: "TCP", address: "127.0.0.1" }],
      processes: new Map([[1234, { pid: 1234, processName: "node", command: "npm run dev", cwd: "/repo/acme-web" }]]),
      processActivityByPid: new Map([[1234, { cpuPercent: 3.7, memoryRssBytes: 123456789 }]]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          "/repo/acme-web",
          {
            repoRoot: "/repo/acme-web",
            branch: "main",
            worktreePath: "/repo/acme-web",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: []
    });

    expect(status.groups[0]?.worktrees[0]?.services[0]?.activity).toEqual({
      cpuPercent: 3.7,
      memoryRssBytes: 123456789
    });
  });

  test("attaches Docker activity metrics by container id", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [],
      processes: new Map(),
      dockerPorts: [
        {
          containerId: "abc123",
          containerName: "portdeck-postgres-1",
          image: "postgres:16",
          hostIp: "127.0.0.1",
          hostPort: 5432,
          containerPort: 5432,
          protocol: "tcp",
          labels: { "com.docker.compose.project": "portdeck" }
        }
      ],
      dockerActivityByContainerId: new Map([
        [
          "abc123",
          {
            cpuPercent: 1.2,
            memoryUsageBytes: 64000000,
            memoryLimitBytes: 512000000
          }
        ]
      ]),
      gitByCwd: new Map(),
      warnings: []
    });

    expect(status.groups[0]?.worktrees[0]?.services[0]?.activity).toEqual({
      cpuPercent: 1.2,
      memoryUsageBytes: 64000000,
      memoryLimitBytes: 512000000
    });
  });

  test("omits service activity when metrics are unavailable", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [{ pid: 1234, processName: "node", port: 3000, protocol: "TCP", address: "127.0.0.1" }],
      processes: new Map([[1234, { pid: 1234, processName: "node", command: "npm run dev", cwd: "/repo/acme-web" }]]),
      processActivityByPid: new Map(),
      dockerPorts: [],
      dockerActivityByContainerId: new Map(),
      gitByCwd: new Map([
        [
          "/repo/acme-web",
          {
            repoRoot: "/repo/acme-web",
            branch: "main",
            worktreePath: "/repo/acme-web",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: []
    });

    expect(status.groups[0]?.worktrees[0]?.services[0]?.activity).toBeUndefined();
    expect(status.warnings).toEqual([]);
  });

  test("places services without cwd in unknown with low confidence", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [{ pid: 5678, processName: "python", port: 8000, protocol: "TCP", address: "127.0.0.1" }],
      processes: new Map([[5678, { pid: 5678, processName: "python", command: "python -m http.server" }]]),
      dockerPorts: [],
      gitByCwd: new Map(),
      warnings: ["cwd unavailable for pid 5678"]
    });

    expect(status.groups).toEqual([]);
    expect(status.unknown).toEqual([
      {
        id: "pid-5678-port-8000",
        name: "python",
        source: "process",
        status: "running",
        port: 8000,
        url: "http://127.0.0.1:8000",
        address: "127.0.0.1",
        protocol: "TCP",
        listeners: [
          {
            address: "127.0.0.1",
            family: "IPv4",
            port: 8000,
            url: "http://127.0.0.1:8000",
            isWildcard: false,
            isLoopback: true,
            isPreferred: true
          }
        ],
        pid: 5678,
        processName: "python",
        command: "python -m http.server",
        confidence: "low"
      }
    ]);
    expect(status.warnings).toEqual(["cwd unavailable for pid 5678"]);
  });

  test("keeps root cwd non-Git process services unknown with an attribution reason", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [{ pid: 635, processName: "ControlCenter", port: 5000, protocol: "TCP", address: "*" }],
      processes: new Map([[635, { pid: 635, processName: "ControlCenter", command: "ControlCenter", cwd: "/" }]]),
      dockerPorts: [],
      gitByCwd: new Map(),
      warnings: []
    });

    expect(status.groups).toEqual([]);
    expect(status.unknown).toEqual([
      expect.objectContaining({
        id: "pid-635-port-5000",
        name: "ControlCenter",
        source: "process",
        port: 5000,
        url: "http://localhost:5000",
        cwd: "/",
        confidence: "low",
        groupingReason: "No Git worktree found for /"
      })
    ]);
  });

  test("redacts secret-looking command arguments before output", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [{ pid: 62061, processName: "convex", port: 3210, protocol: "TCP", address: "127.0.0.1" }],
      processes: new Map([
        [
          62061,
          {
            pid: 62061,
            processName: "convex",
            command: "TOKEN=\"alpha beta\" convex-local-backend --instance-secret abc123 --api-token=def456 --api-key 'gamma delta' --header Authorization: Bearer example-bearer-token --database-url postgres://developer:db-password@localhost:5432/app --port 3210",
            cwd: "/repo/acme-web"
          }
        ]
      ]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          "/repo/acme-web",
          {
            repoRoot: "/repo/acme-web",
            branch: "main",
            worktreePath: "/repo/acme-web",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: []
    });

    expect(status.groups[0]?.worktrees[0]?.services[0]?.command).toBe(
      "TOKEN=[redacted] convex-local-backend --instance-secret [redacted] --api-token=[redacted] --api-key [redacted] --header Authorization: Bearer [redacted] --database-url postgres://developer:[redacted]@localhost:5432/app --port 3210"
    );
  });

  test("names Convex dev processes from their command line", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [{ pid: 62047, processName: "node", port: 6790, protocol: "TCP", address: "127.0.0.1" }],
      processes: new Map([
        [
          62047,
          {
            pid: 62047,
            processName: "node",
            command: "node /repo/acme-web/node_modules/.bin/convex dev",
            cwd: "/repo/acme-web"
          }
        ]
      ]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          "/repo/acme-web",
          {
            repoRoot: "/repo/acme-web",
            branch: "main",
            worktreePath: "/repo/acme-web",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: []
    });

    expect(status.groups[0]?.worktrees[0]?.services[0]?.name).toBe("convex");
  });

  test("groups Docker published ports by Compose project when repo is unknown", async () => {
    const dockerPorts: DiscoveredDockerPort[] = [
      {
        containerId: "abc123",
        containerName: "portdeck-postgres-1",
        image: "postgres:16",
        hostIp: "127.0.0.1",
        hostPort: 5432,
        containerPort: 5432,
        protocol: "tcp",
        labels: { "com.docker.compose.project": "portdeck" }
      }
    ];

    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [],
      processes: new Map(),
      dockerPorts,
      gitByCwd: new Map(),
      warnings: []
    });

    expect(status.groups).toEqual([
      {
        projectName: "portdeck",
        repoRoot: undefined,
        worktrees: [
          {
            name: "docker",
            path: undefined,
            branch: undefined,
            services: [
              {
                id: "docker-abc123-port-5432",
                name: "postgres",
                source: "docker",
                status: "running",
                port: 5432,
                url: "http://127.0.0.1:5432",
                hostIp: "127.0.0.1",
                protocol: "tcp",
                listeners: [
                  {
                    address: "127.0.0.1",
                    family: "IPv4",
                    port: 5432,
                    url: "http://127.0.0.1:5432",
                    isWildcard: false,
                    isLoopback: true,
                    isPreferred: true
                  }
                ],
                containerName: "portdeck-postgres-1",
                containerId: "abc123",
                containerPort: 5432,
                image: "postgres:16",
                processName: "postgres:16",
                command: "docker container portdeck-postgres-1",
                confidence: "medium"
              }
            ]
          }
        ]
      }
    ]);
  });

  test("deduplicates Docker Desktop backend processes when Docker owns the host port", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [
        { pid: 4941, processName: "com.docker.backend", port: 54322, protocol: "TCP", address: "*" },
        { pid: 1234, processName: "node", port: 3000, protocol: "TCP", address: "127.0.0.1" }
      ],
      processes: new Map([
        [
          4941,
          {
            pid: 4941,
            processName: "com.docker.backend",
            command: "/Applications/Docker.app/Contents/MacOS/com.docker.backend services",
            cwd: "/Users/jesse/Library/Containers/com.docker.docker/Data"
          }
        ],
        [1234, { pid: 1234, processName: "node", command: "npm run dev", cwd: "/repo/acme-web" }]
      ]),
      dockerPorts: [
        {
          containerId: "abc123",
          containerName: "supabase_db_acme-web",
          image: "postgres:17",
          hostIp: "127.0.0.1",
          hostPort: 54322,
          containerPort: 5432,
          protocol: "tcp",
          labels: { "com.docker.compose.project": "acme-web" }
        }
      ],
      gitByCwd: new Map([
        [
          "/repo/acme-web",
          {
            repoRoot: "/repo/acme-web",
            branch: "main",
            worktreePath: "/repo/acme-web",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: []
    });

    expect(status.unknown).toEqual([]);
    expect(status.groups).toHaveLength(1);
    expect(status.groups[0]?.projectName).toBe("acme-web");
    expect(status.groups[0]?.worktrees[0]?.services.map((service) => service.source)).toEqual(["process", "docker"]);
  });

  test("merges Docker services into a matching Git project group", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [{ pid: 1234, processName: "node", port: 3000, protocol: "TCP", address: "127.0.0.1" }],
      processes: new Map([[1234, { pid: 1234, processName: "node", command: "npm run dev", cwd: "/repo/acme-web" }]]),
      dockerPorts: [
        {
          containerId: "abc123",
          containerName: "supabase_studio_acme-web",
          image: "supabase/studio",
          hostIp: "0.0.0.0",
          hostPort: 54323,
          containerPort: 3000,
          protocol: "tcp",
          labels: { "com.docker.compose.project": "acme-web" }
        }
      ],
      gitByCwd: new Map([
        [
          "/repo/acme-web",
          {
            repoRoot: "/repo/acme-web",
            branch: "main",
            worktreePath: "/repo/acme-web",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: []
    });

    expect(status.groups).toEqual([
      {
        projectName: "acme-web",
        repoRoot: "/repo/acme-web",
        worktrees: [
          {
            name: "main",
            path: "/repo/acme-web",
            branch: "main",
            services: [
              expect.objectContaining({
                id: "pid-1234-port-3000",
                source: "process",
                port: 3000
              }),
              expect.objectContaining({
                id: "docker-abc123-port-54323",
                name: "studio",
                source: "docker",
                port: 54323,
                containerName: "supabase_studio_acme-web",
                containerId: "abc123",
                containerPort: 3000,
                image: "supabase/studio"
              })
            ]
          }
        ]
      }
    ]);
  });

  test("keeps Docker services standalone when a project match is ambiguous", async () => {
    const gitByCwd = new Map<string, GitInfo>([
      [
        "/repo/app-one",
        {
          repoRoot: "/repo/app-one",
          branch: "main",
          worktreePath: "/repo/app-one",
          worktreeName: "main"
        }
      ],
      [
        "/repo/app-two",
        {
          repoRoot: "/repo/app-two",
          branch: "main",
          worktreePath: "/repo/app-two",
          worktreeName: "main"
        }
      ]
    ]);

    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [
        { pid: 1111, processName: "node", port: 3001, protocol: "TCP", address: "127.0.0.1" },
        { pid: 2222, processName: "node", port: 3002, protocol: "TCP", address: "127.0.0.1" }
      ],
      processes: new Map([
        [1111, { pid: 1111, processName: "node", command: "npm run dev", cwd: "/repo/app-one" }],
        [2222, { pid: 2222, processName: "node", command: "npm run dev", cwd: "/repo/app-two" }]
      ]),
      dockerPorts: [
        {
          containerId: "abc123",
          containerName: "redis-1",
          image: "redis:7",
          hostIp: "127.0.0.1",
          hostPort: 6379,
          containerPort: 6379,
          protocol: "tcp",
          labels: { "com.docker.compose.project": "shared" }
        }
      ],
      gitByCwd,
      warnings: []
    });

    expect(status.groups.map((group) => group.projectName)).toEqual(["app-one", "app-two", "shared"]);
    expect(status.groups[2]?.worktrees).toEqual([
      {
        name: "docker",
        path: undefined,
        branch: undefined,
        services: [expect.objectContaining({ name: "redis", source: "docker", port: 6379 })]
      }
    ]);
  });

  test("groups Docker services by Compose working directory when it maps to one Git worktree", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [],
      processes: new Map(),
      dockerPorts: [
        {
          containerId: "compose123",
          containerName: "supabase-db-1",
          image: "postgres:17",
          hostIp: "127.0.0.1",
          hostPort: 54322,
          containerPort: 5432,
          protocol: "tcp",
          labels: {
            "com.docker.compose.project": "supabase",
            "com.docker.compose.service": "db",
            "com.docker.compose.project.working_dir": "/repo/acme-web"
          },
          composeProjectWorkingDir: "/repo/acme-web"
        }
      ],
      gitByCwd: new Map([
        [
          "/repo/acme-web",
          {
            repoRoot: "/repo/acme-web",
            branch: "main",
            worktreePath: "/repo/acme-web",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: []
    });

    expect(status.unknown).toEqual([]);
    expect(status.groups).toEqual([
      expect.objectContaining({
        projectName: "acme-web",
        repoRoot: "/repo/acme-web",
        worktrees: [
          expect.objectContaining({
            name: "main",
            path: "/repo/acme-web",
            services: [
              expect.objectContaining({
                id: "docker-compose123-port-54322",
                name: "db",
                source: "docker",
                port: 54322,
                confidence: "high"
              })
            ]
          })
        ]
      })
    ]);
  });

  test("groups Docker services by bind-mounted package path in a linked worktree", async () => {
    const packageContext: PackageSubcontext = {
      type: "package",
      name: "@acme/api",
      displayName: "@acme/api",
      path: "/repo/worktrees/lab/apps/api",
      relativePath: "apps/api",
      manifestPath: "/repo/worktrees/lab/apps/api/package.json"
    };

    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [],
      processes: new Map(),
      dockerPorts: [
        {
          containerId: "api123",
          containerName: "acme-api-1",
          image: "node:22",
          hostIp: "127.0.0.1",
          hostPort: 4311,
          containerPort: 4311,
          protocol: "tcp",
          labels: {
            "com.docker.compose.project": "acme",
            "com.docker.compose.service": "api"
          },
          containerWorkingDir: "/workspace/apps/api",
          mounts: [
            {
              type: "bind",
              source: "/repo/worktrees/lab/apps/api",
              destination: "/workspace/apps/api",
              mode: "rw",
              rw: true
            }
          ]
        }
      ],
      gitByCwd: new Map([
        [
          "/repo/worktrees/lab/apps/api",
          {
            repoRoot: "/repo/monorepo",
            branch: "feature/lab",
            worktreePath: "/repo/worktrees/lab",
            worktreeName: "feature/lab"
          }
        ]
      ]),
      packageByCwd: new Map([["/repo/worktrees/lab/apps/api", packageContext]]),
      warnings: []
    });

    const service = status.groups[0]?.worktrees[0]?.services[0];
    expect(status.unknown).toEqual([]);
    expect(status.groups[0]).toEqual(
      expect.objectContaining({
        projectName: "monorepo",
        repoRoot: "/repo/monorepo"
      })
    );
    expect(status.groups[0]?.worktrees[0]).toEqual(
      expect.objectContaining({
        name: "feature/lab",
        path: "/repo/worktrees/lab",
        branch: "feature/lab"
      })
    );
    expect(service).toEqual(
      expect.objectContaining({
        id: "docker-api123-port-4311",
        name: "api",
        source: "docker",
        confidence: "high",
        subcontext: packageContext
      })
    );
  });

  test("keeps Docker services unknown when Compose project matches multiple worktrees", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [],
      processes: new Map(),
      dockerPorts: [
        {
          containerId: "redis123",
          containerName: "acme-web-redis-1",
          image: "redis:7",
          hostIp: "127.0.0.1",
          hostPort: 6379,
          containerPort: 6379,
          protocol: "tcp",
          labels: {
            "com.docker.compose.project": "acme-web",
            "com.docker.compose.service": "redis"
          }
        }
      ],
      gitByCwd: new Map([
        [
          "/repo/acme-web",
          {
            repoRoot: "/repo/acme-web",
            branch: "main",
            worktreePath: "/repo/acme-web",
            worktreeName: "main"
          }
        ],
        [
          "/repo/worktrees/billing/acme-web",
          {
            repoRoot: "/repo/acme-web",
            branch: "feature/billing",
            worktreePath: "/repo/worktrees/billing/acme-web",
            worktreeName: "feature/billing"
          }
        ]
      ]),
      warnings: []
    });

    expect(status.groups).toEqual([]);
    expect(status.unknown).toEqual([
      expect.objectContaining({
        id: "docker-redis123-port-6379",
        name: "redis",
        source: "docker",
        confidence: "low",
        groupingReason: "Docker attribution is ambiguous: Compose project acme-web matches multiple Git worktrees"
      })
    ]);
  });

  test("keeps Docker services unknown when path metadata maps to multiple Git worktrees", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [],
      processes: new Map(),
      dockerPorts: [
        {
          containerId: "conflict123",
          containerName: "shared-worker-1",
          image: "node:22",
          hostIp: "127.0.0.1",
          hostPort: 7099,
          containerPort: 7099,
          protocol: "tcp",
          labels: {
            "com.docker.compose.project": "shared",
            "com.docker.compose.service": "worker",
            "com.docker.compose.project.working_dir": "/repo/app-one"
          },
          composeProjectWorkingDir: "/repo/app-one",
          mounts: [
            {
              type: "bind",
              source: "/repo/app-two",
              destination: "/workspace/app-two"
            }
          ]
        }
      ],
      gitByCwd: new Map([
        [
          "/repo/app-one",
          {
            repoRoot: "/repo/app-one",
            branch: "main",
            worktreePath: "/repo/app-one",
            worktreeName: "main"
          }
        ],
        [
          "/repo/app-two",
          {
            repoRoot: "/repo/app-two",
            branch: "main",
            worktreePath: "/repo/app-two",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: []
    });

    expect(status.groups).toEqual([]);
    expect(status.unknown).toEqual([
      expect.objectContaining({
        id: "docker-conflict123-port-7099",
        name: "worker",
        source: "docker",
        confidence: "low",
        groupingReason: "Docker attribution is ambiguous: path metadata maps to multiple Git worktrees"
      })
    ]);
  });

  test("attaches ngrok exposures to matching local services without replacing localhost", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [
        { pid: 7201, processName: "node", port: 3000, protocol: "TCP", address: "127.0.0.1" },
        { pid: 7202, processName: "node", port: 5173, protocol: "TCP", address: "::1" }
      ],
      processes: new Map([
        [7201, { pid: 7201, processName: "node", command: "next dev", cwd: "/repo/web" }],
        [7202, { pid: 7202, processName: "node", command: "vite dev", cwd: "/repo/ipv6" }]
      ]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          "/repo/web",
          {
            repoRoot: "/repo/web",
            branch: "main",
            worktreePath: "/repo/web",
            worktreeName: "main"
          }
        ],
        [
          "/repo/ipv6",
          {
            repoRoot: "/repo/ipv6",
            branch: "main",
            worktreePath: "/repo/ipv6",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: [],
      exposures: [
        {
          id: "ngrok-demo-ngrok-app",
          kind: "ngrok",
          publicUrl: "https://demo.ngrok.app",
          targetUrl: "http://localhost:3000",
          targetHost: "localhost",
          targetPort: 3000,
          agentApiUrl: "http://127.0.0.1:4040/api/tunnels",
          agentPid: 7301,
          agentCwd: "/repo/web",
          status: "unknown"
        },
        {
          id: "ngrok-ipv6-ngrok-app",
          kind: "ngrok",
          publicUrl: "https://ipv6.ngrok.app",
          targetUrl: "http://[::1]:5173",
          targetHost: "::1",
          targetPort: 5173,
          agentApiUrl: "http://127.0.0.1:4040/api/tunnels",
          agentPid: 7301,
          agentCwd: "/repo/web",
          status: "unknown"
        }
      ]
    });

    const web = flattenServices(status).find((service) => service.port === 3000);
    const ipv6 = flattenServices(status).find((service) => service.port === 5173);

    expect(web?.url).toBe("http://127.0.0.1:3000");
    expect(web?.exposures).toEqual([
      expect.objectContaining({
        publicUrl: "https://demo.ngrok.app",
        targetUrl: "http://localhost:3000",
        status: "attached",
        attachedServiceId: "pid-7201-port-3000"
      })
    ]);
    expect(ipv6?.exposures).toEqual([
      expect.objectContaining({
        publicUrl: "https://ipv6.ngrok.app",
        targetHost: "::1",
        targetPort: 5173,
        status: "attached",
        attachedServiceId: "pid-7202-port-5173"
      })
    ]);
    expect(status.exposures).toEqual([
      expect.objectContaining({ id: "ngrok-demo-ngrok-app", status: "attached", attachedServiceId: "pid-7201-port-3000" }),
      expect.objectContaining({ id: "ngrok-ipv6-ngrok-app", status: "attached", attachedServiceId: "pid-7202-port-5173" })
    ]);
    expect(status.warnings).toEqual([]);
  });

  test("marks ngrok exposures dangling when their local target port is down", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [],
      processes: new Map(),
      dockerPorts: [],
      gitByCwd: new Map(),
      warnings: [],
      exposures: [
        {
          id: "ngrok-stale-ngrok-app",
          kind: "ngrok",
          publicUrl: "https://stale.ngrok.app",
          targetUrl: "http://localhost:3000",
          targetHost: "localhost",
          targetPort: 3000,
          agentApiUrl: "http://127.0.0.1:4040/api/tunnels",
          status: "unknown"
        }
      ]
    });

    expect(status.exposures).toEqual([
      expect.objectContaining({
        publicUrl: "https://stale.ngrok.app",
        targetUrl: "http://localhost:3000",
        targetHost: "localhost",
        targetPort: 3000,
        status: "dangling"
      })
    ]);
    expect(status.warnings).toContain("ngrok tunnel https://stale.ngrok.app targets localhost:3000, but no local listener is running");
  });

  test("marks ngrok exposures unknown for ambiguous or non-loopback targets", async () => {
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [
        { pid: 7401, processName: "node", port: 3000, protocol: "TCP", address: "127.0.0.1" },
        { pid: 7402, processName: "node", port: 3000, protocol: "TCP", address: "*" }
      ],
      processes: new Map([
        [7401, { pid: 7401, processName: "node", command: "next dev", cwd: "/repo/one" }],
        [7402, { pid: 7402, processName: "node", command: "next dev", cwd: "/repo/two" }]
      ]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          "/repo/one",
          {
            repoRoot: "/repo/one",
            branch: "main",
            worktreePath: "/repo/one",
            worktreeName: "main"
          }
        ],
        [
          "/repo/two",
          {
            repoRoot: "/repo/two",
            branch: "main",
            worktreePath: "/repo/two",
            worktreeName: "main"
          }
        ]
      ]),
      warnings: [],
      exposures: [
        {
          id: "ngrok-ambiguous-ngrok-app",
          kind: "ngrok",
          publicUrl: "https://ambiguous.ngrok.app",
          targetUrl: "http://localhost:3000",
          targetHost: "localhost",
          targetPort: 3000,
          agentApiUrl: "http://127.0.0.1:4040/api/tunnels",
          status: "unknown"
        },
        {
          id: "ngrok-lan-ngrok-app",
          kind: "ngrok",
          publicUrl: "https://lan.ngrok.app",
          targetUrl: "http://192.168.1.20:3000",
          targetHost: "192.168.1.20",
          targetPort: 3000,
          agentApiUrl: "http://127.0.0.1:4040/api/tunnels",
          status: "unknown"
        }
      ]
    });

    expect(status.exposures).toEqual([
      expect.objectContaining({
        id: "ngrok-ambiguous-ngrok-app",
        status: "unknown"
      }),
      expect.objectContaining({
        id: "ngrok-lan-ngrok-app",
        status: "unknown"
      })
    ]);
    expect(flattenServices(status).flatMap((service) => service.exposures ?? [])).toEqual([]);
    expect(status.warnings).toContain("ngrok tunnel https://ambiguous.ngrok.app targets localhost:3000, but multiple local listeners match");
    expect(status.warnings).toContain("ngrok tunnel https://lan.ngrok.app targets 192.168.1.20:3000, which is not a supported local loopback target");
  });

  test("keeps the ngrok inspector as machine-level provenance instead of assigning it to a worktree", async () => {
    const gitCwd = "/repo/acme-web";
    const status = await buildStatus({
      generatedAt: "2026-06-05T00:00:00.000Z",
      processPorts: [
        { pid: 7501, processName: "ngrok", port: 4040, protocol: "TCP", address: "127.0.0.1" },
        { pid: 7502, processName: "node", port: 3000, protocol: "TCP", address: "127.0.0.1" }
      ],
      processes: new Map([
        [7501, { pid: 7501, processName: "ngrok", command: "ngrok http 3000 --log=stdout", cwd: gitCwd }],
        [7502, { pid: 7502, processName: "node", command: "next dev", cwd: gitCwd }]
      ]),
      dockerPorts: [],
      gitByCwd: new Map([
        [
          gitCwd,
          {
            repoRoot: gitCwd,
            branch: "main",
            worktreePath: gitCwd,
            worktreeName: "main"
          }
        ]
      ]),
      warnings: [],
      exposures: [
        {
          id: "ngrok-demo-ngrok-app",
          kind: "ngrok",
          publicUrl: "https://demo.ngrok.app",
          targetUrl: "http://localhost:3000",
          targetHost: "localhost",
          targetPort: 3000,
          agentApiUrl: "http://127.0.0.1:4040/api/tunnels",
          agentPid: 7501,
          agentCwd: gitCwd,
          status: "unknown"
        }
      ]
    });

    expect(status.groups[0]?.worktrees[0]?.services.map((service) => service.port)).toEqual([3000]);
    expect(status.unknown).toEqual([
      expect.objectContaining({
        id: "pid-7501-port-4040",
        name: "ngrok",
        cwd: gitCwd,
        groupingReason: "ngrok agent is machine-level; cwd is provenance only"
      })
    ]);
    expect(status.exposures?.[0]).toEqual(
      expect.objectContaining({
        publicUrl: "https://demo.ngrok.app",
        agentPid: 7501,
        agentCwd: gitCwd,
        status: "attached",
        attachedServiceId: "pid-7502-port-3000"
      })
    );
  });
});
