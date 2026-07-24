import Foundation
import Testing
@testable import PortDeckCore

@Test func decodesStatusJsonWithProcessAndDockerServices() throws {
  let json = """
  {
    "schemaVersion": "0.2",
    "generatedAt": "2026-06-08T12:00:00.000Z",
    "groups": [
      {
        "projectName": "acme-web",
        "repoRoot": "/repo/acme-web",
        "worktrees": [
          {
            "name": "main",
            "path": "/repo/acme-web",
            "branch": "main",
            "services": [
              {
                "id": "pid-123-port-3000",
                "name": "web",
                "source": "process",
                "status": "running",
                "port": 3000,
                "url": "http://localhost:3000",
                "address": "127.0.0.1",
                "protocol": "TCP",
                "pid": 123,
                "processName": "node",
                "command": "npm run dev",
                "cwd": "/repo/acme-web",
                "confidence": "high"
              },
              {
                "id": "docker-abc-port-54322",
                "name": "db",
                "source": "docker",
                "status": "running",
                "port": 54322,
                "url": "http://localhost:54322",
                "hostIp": "127.0.0.1",
                "protocol": "tcp",
                "containerName": "supabase_db_acme-web",
                "containerId": "abc",
                "containerPort": 5432,
                "image": "postgres:17",
                "processName": "postgres:17",
                "command": "docker container supabase_db_acme-web",
                "confidence": "medium"
              }
            ]
          }
        ]
      }
    ],
    "unknown": [],
    "warnings": []
  }
  """.data(using: .utf8)!

  let status = try JSONDecoder().decode(PortdeckStatus.self, from: json)

  #expect(status.schemaVersion == "0.2")
  #expect(status.groups.count == 1)
  #expect(status.groups[0].worktrees[0].services.map(\.name) == ["web", "db"])
  #expect(status.groups[0].worktrees[0].services[0].subcontext == nil)
  #expect(status.groups[0].worktrees[0].services[1].containerName == "supabase_db_acme-web")
}

@Test func decodesOptionalProjectAndWorktreeRemoteMetadata() throws {
  let json = """
  {
    "schemaVersion": "0.2",
    "generatedAt": "2026-06-08T12:00:00.000Z",
    "groups": [
      {
        "projectName": "portdeck",
        "repoRoot": "/repo/portdeck",
        "remoteUrl": "git@github.com:acme-inc/portdeck.git",
        "repositoryUrl": "https://github.com/acme-inc/portdeck",
        "worktrees": [
          {
            "name": "feature/git-worktree-jump-actions",
            "path": "/repo/worktrees/portdeck-jump-actions",
            "branch": "feature/git-worktree-jump-actions",
            "remoteUrl": "git@github.com:acme-inc/portdeck.git",
            "repositoryUrl": "https://github.com/acme-inc/portdeck",
            "services": []
          }
        ]
      }
    ],
    "unknown": [],
    "warnings": []
  }
  """.data(using: .utf8)!

  let status = try JSONDecoder().decode(PortdeckStatus.self, from: json)
  let group = try #require(status.groups.first)
  let worktree = try #require(group.worktrees.first)

  #expect(group.remoteUrl == "git@github.com:acme-inc/portdeck.git")
  #expect(group.repositoryUrl == "https://github.com/acme-inc/portdeck")
  #expect(group.repoFolderURLString == "file:///repo/portdeck")
  #expect(group.repositoryOpenURLString == "https://github.com/acme-inc/portdeck")
  #expect(worktree.remoteUrl == "git@github.com:acme-inc/portdeck.git")
  #expect(worktree.repositoryUrl == "https://github.com/acme-inc/portdeck")
  #expect(worktree.folderURLString == "file:///repo/worktrees/portdeck-jump-actions")
  #expect(worktree.repositoryOpenURLString == "https://github.com/acme-inc/portdeck")
}

@Test func decodesOptionalServiceSubcontext() throws {
  let json = """
  {
    "schemaVersion": "0.2",
    "generatedAt": "2026-06-08T12:00:00.000Z",
    "groups": [
      {
        "projectName": "monorepo",
        "repoRoot": "/repo/monorepo",
        "worktrees": [
          {
            "name": "main",
            "path": "/repo/monorepo",
            "branch": "main",
            "services": [
              {
                "id": "pid-2345-port-3001",
                "name": "web",
                "source": "process",
                "status": "running",
                "port": 3001,
                "url": "http://localhost:3001",
                "pid": 2345,
                "processName": "node",
                "cwd": "/repo/monorepo/apps/web",
                "confidence": "high",
                "subcontext": {
                  "type": "package",
                  "name": "@acme/web",
                  "displayName": "@acme/web",
                  "path": "/repo/monorepo/apps/web",
                  "relativePath": "apps/web",
                  "manifestPath": "/repo/monorepo/apps/web/package.json"
                }
              }
            ]
          }
        ]
      }
    ],
    "unknown": [],
    "warnings": []
  }
  """.data(using: .utf8)!

  let status = try JSONDecoder().decode(PortdeckStatus.self, from: json)
  let subcontext = try #require(status.groups[0].worktrees[0].services[0].subcontext)

  #expect(subcontext.type == "package")
  #expect(subcontext.name == "@acme/web")
  #expect(subcontext.displayName == "@acme/web")
  #expect(subcontext.relativePath == "apps/web")
}

@Test func decodesOptionalDockerGroupingReason() throws {
  let json = """
  {
    "schemaVersion": "0.2",
    "generatedAt": "2026-06-08T12:00:00.000Z",
    "groups": [],
    "unknown": [
      {
        "id": "docker-abc-port-6379",
        "name": "redis",
        "source": "docker",
        "status": "running",
        "port": 6379,
        "url": "http://127.0.0.1:6379",
        "hostIp": "127.0.0.1",
        "protocol": "tcp",
        "containerName": "acme-web-redis-1",
        "containerId": "abc",
        "containerPort": 6379,
        "image": "redis:7",
        "confidence": "low",
        "groupingReason": "Docker attribution is ambiguous: Compose project acme-web matches multiple Git worktrees"
      }
    ],
    "warnings": []
  }
  """.data(using: .utf8)!

  let status = try JSONDecoder().decode(PortdeckStatus.self, from: json)
  let service = try #require(status.unknown.first)

  #expect(service.groupingReason == "Docker attribution is ambiguous: Compose project acme-web matches multiple Git worktrees")
  #expect(service.matchesSearch("multiple git", preferNamedURLs: false, context: []))
}

@Test func decodesOptionalServiceActivityAndFormatsProcessMetrics() throws {
  let json = """
  {
    "schemaVersion": "0.2",
    "generatedAt": "2026-06-08T12:00:00.000Z",
    "groups": [
      {
        "projectName": "acme-web",
        "repoRoot": "/repo/acme-web",
        "worktrees": [
          {
            "name": "main",
            "path": "/repo/acme-web",
            "branch": "main",
            "services": [
              {
                "id": "pid-123-port-3000",
                "name": "web",
                "source": "process",
                "status": "running",
                "port": 3000,
                "url": "http://localhost:3000",
                "pid": 123,
                "processName": "node",
                "command": "npm run dev",
                "cwd": "/repo/acme-web",
                "confidence": "high",
                "activity": {
                  "cpuPercent": 2.34,
                  "memoryRssBytes": 126353408
                }
              }
            ]
          }
        ]
      }
    ],
    "unknown": [],
    "warnings": []
  }
  """.data(using: .utf8)!

  let status = try JSONDecoder().decode(PortdeckStatus.self, from: json)
  let service = status.groups[0].worktrees[0].services[0]

  #expect(service.activity?.cpuPercent == 2.34)
  #expect(service.activity?.memoryRssBytes == 126353408)
  #expect(service.activityCPUText == "2.3%")
  #expect(service.activityMemoryText == "121MB")
}

@Test func formatsDockerActivityMetrics() throws {
  let service = makeService(
    name: "postgres",
    source: "docker",
    port: 5432,
    url: "http://localhost:5432",
    activity: ServiceActivity(
      cpuPercent: 4,
      memoryRssBytes: nil,
      memoryUsageBytes: 64 * 1024 * 1024,
      memoryLimitBytes: 512 * 1024 * 1024
    )
  )

  #expect(service.activityCPUText == "4%")
  #expect(service.activityMemoryText == "64MB")
}

@Test func missingActivityFormatsQuietUnavailableSummary() throws {
  let service = makeService(
    name: "web",
    source: "process",
    port: 3000,
    url: "http://localhost:3000"
  )

  #expect(service.activityCPUText == nil)
  #expect(service.activityMemoryText == nil)
}

@Test func decodesListenerAndCollisionMetadata() throws {
  let json = """
  {
    "schemaVersion": "0.2",
    "generatedAt": "2026-06-08T12:00:00.000Z",
    "groups": [
      {
        "projectName": "acme-api",
        "repoRoot": "/repo/acme-api",
        "worktrees": [
          {
            "name": "main",
            "path": "/repo/acme-api",
            "branch": "main",
            "services": [
              {
                "id": "pid-4001-port-3000",
                "name": "web",
                "source": "process",
                "status": "running",
                "port": 3000,
                "url": "http://127.0.0.1:3000",
                "address": "127.0.0.1",
                "protocol": "TCP",
                "pid": 4001,
                "processName": "node",
                "cwd": "/repo/acme-api",
                "confidence": "high",
                "listeners": [
                  {
                    "address": "127.0.0.1",
                    "family": "IPv4",
                    "port": 3000,
                    "url": "http://127.0.0.1:3000",
                    "isWildcard": false,
                    "isLoopback": true,
                    "isPreferred": true
                  }
                ],
                "localhostCollision": {
                  "port": 3000,
                  "localhostUrl": "http://localhost:3000",
                  "message": "localhost:3000 may route to a different service than 127.0.0.1:3000",
                  "conflictsWith": [
                    {
                      "serviceId": "pid-4002-port-3000",
                      "name": "web",
                      "projectName": "acme-web",
                      "worktreeName": "main",
                      "url": "http://localhost:3000",
                      "address": "*"
                    }
                  ]
                }
              }
            ]
          }
        ]
      }
    ],
    "unknown": [],
    "warnings": []
  }
  """.data(using: .utf8)!

  let status = try JSONDecoder().decode(PortdeckStatus.self, from: json)
  let service = status.groups[0].worktrees[0].services[0]

  #expect(service.listeners?.count == 1)
  #expect(service.listeners?[0].address == "127.0.0.1")
  #expect(service.listeners?[0].family == "IPv4")
  #expect(service.listeners?[0].isPreferred == true)
  #expect(service.localhostCollision?.conflictsWith[0].projectName == "acme-web")
  #expect(service.preferredEndpointLabel == "127.0.0.1:3000")
  #expect(service.localhostCollisionSummary == "localhost:3000 -> acme-web")
}

@Test func formatsBracketedIPv6EndpointLabels() throws {
  let json = """
  {
    "schemaVersion": "0.2",
    "generatedAt": "2026-06-08T12:00:00.000Z",
    "groups": [
      {
        "projectName": "ipv6-app",
        "repoRoot": "/repo/ipv6-app",
        "worktrees": [
          {
            "name": "main",
            "path": "/repo/ipv6-app",
            "branch": "main",
            "services": [
              {
                "id": "pid-123-port-3000",
                "name": "web",
                "source": "process",
                "status": "running",
                "port": 3000,
                "url": "http://[::1]:3000",
                "address": "::1",
                "protocol": "TCP",
                "pid": 123,
                "processName": "node",
                "cwd": "/repo/ipv6-app",
                "confidence": "high",
                "listeners": [
                  {
                    "address": "::1",
                    "family": "IPv6",
                    "port": 3000,
                    "url": "http://[::1]:3000",
                    "isWildcard": false,
                    "isLoopback": true,
                    "isPreferred": true
                  }
                ]
              }
            ]
          }
        ]
      }
    ],
    "unknown": [],
    "warnings": []
  }
  """.data(using: .utf8)!

  let status = try JSONDecoder().decode(PortdeckStatus.self, from: json)
  let service = status.groups[0].worktrees[0].services[0]

  #expect(service.preferredEndpointLabel == "[::1]:3000")
}

@Test func decodesEndpointHealthAndPortConflictMetadata() throws {
  let json = """
  {
    "schemaVersion": "0.2",
    "generatedAt": "2026-06-08T12:00:00.000Z",
    "groups": [
      {
        "projectName": "acme-web",
        "repoRoot": "/repo/acme-web",
        "worktrees": [
          {
            "name": "main",
            "path": "/repo/acme-web",
            "branch": "main",
            "services": [
              {
                "id": "pid-4302-port-3000",
                "name": "web",
                "source": "process",
                "status": "running",
                "port": 3000,
                "url": "http://localhost:3000",
                "address": "*",
                "protocol": "TCP",
                "pid": 4302,
                "processName": "node",
                "cwd": "/repo/acme-web",
                "confidence": "medium",
                "endpointHealth": {
                  "url": "http://localhost:3000",
                  "status": "http-error",
                  "statusCode": 500,
                  "remoteAddress": "::1",
                  "latencyMs": 12
                }
              }
            ]
          }
        ]
      }
    ],
    "unknown": [],
    "warnings": [
      "Port 3000 conflict: localhost:3000 returns HTTP 500 while 127.0.0.1:3000 returns 200 OK"
    ],
    "portConflicts": [
      {
        "port": 3000,
        "severity": "error",
        "title": "Port 3000 conflict",
        "message": "localhost:3000 returns HTTP 500 while 127.0.0.1:3000 returns 200 OK",
        "endpoints": [
          {
            "serviceId": "pid-4302-port-3000",
            "name": "web",
            "projectName": "acme-web",
            "worktreeName": "main",
            "url": "http://localhost:3000",
            "address": "*",
            "health": {
              "url": "http://localhost:3000",
              "status": "http-error",
              "statusCode": 500,
              "remoteAddress": "::1",
              "latencyMs": 12
            }
          },
          {
            "serviceId": "pid-4301-port-3000",
            "name": "web",
            "projectName": "acme-api",
            "worktreeName": "main",
            "url": "http://127.0.0.1:3000",
            "address": "127.0.0.1",
            "health": {
              "url": "http://127.0.0.1:3000",
              "status": "ok",
              "statusCode": 200,
              "remoteAddress": "127.0.0.1",
              "latencyMs": 8
            }
          }
        ]
      }
    ]
  }
  """.data(using: .utf8)!

  let status = try JSONDecoder().decode(PortdeckStatus.self, from: json)
  let service = status.groups[0].worktrees[0].services[0]
  let conflict = try #require(status.portConflicts?.first)

  #expect(service.endpointHealth?.status == "http-error")
  #expect(service.endpointHealth?.statusCode == 500)
  #expect(service.endpointHealthSummary == "HTTP 500 at localhost:3000")
  #expect(service.endpointHealthSeverity == .error)
  #expect(conflict.title == "Port 3000 conflict")
  #expect(conflict.severity == "error")
  #expect(conflict.displayMessage == "localhost:3000 is failing, but 127.0.0.1:3000 is healthy. These are different services.")
  #expect(conflict.endpoints[0].health?.remoteAddress == "::1")
  #expect(conflict.summaryLines == [
    "localhost:3000 -> acme-web (HTTP 500)",
    "127.0.0.1:3000 -> acme-api (200 OK)"
  ])
}

@Test func decodesNgrokExposuresAndFormatsDisplayText() throws {
  let json = """
  {
    "schemaVersion": "0.2",
    "generatedAt": "2026-06-08T12:00:00.000Z",
    "groups": [
      {
        "projectName": "acme-web",
        "repoRoot": "/repo/acme-web",
        "worktrees": [
          {
            "name": "main",
            "path": "/repo/acme-web",
            "branch": "main",
            "services": [
              {
                "id": "pid-7001-port-3000",
                "name": "web",
                "source": "process",
                "status": "running",
                "port": 3000,
                "url": "http://127.0.0.1:3000",
                "address": "127.0.0.1",
                "pid": 7001,
                "processName": "node",
                "cwd": "/repo/acme-web",
                "confidence": "high",
                "exposures": [
                  {
                    "id": "ngrok-demo-ngrok-app",
                    "kind": "ngrok",
                    "publicUrl": "https://demo.ngrok.app",
                    "targetUrl": "http://localhost:3000",
                    "targetHost": "localhost",
                    "targetPort": 3000,
                    "agentApiUrl": "http://127.0.0.1:4040/api/tunnels",
                    "agentPid": 7100,
                    "agentCwd": "/repo/acme-web",
                    "status": "attached",
                    "attachedServiceId": "pid-7001-port-3000"
                  }
                ]
              }
            ]
          }
        ]
      }
    ],
    "unknown": [],
    "warnings": [
      "ngrok tunnel https://stale.ngrok.app targets localhost:4999, but no local listener is running"
    ],
    "exposures": [
      {
        "id": "ngrok-demo-ngrok-app",
        "kind": "ngrok",
        "publicUrl": "https://demo.ngrok.app",
        "targetUrl": "http://localhost:3000",
        "targetHost": "localhost",
        "targetPort": 3000,
        "agentApiUrl": "http://127.0.0.1:4040/api/tunnels",
        "agentPid": 7100,
        "agentCwd": "/repo/acme-web",
        "status": "attached",
        "attachedServiceId": "pid-7001-port-3000"
      },
      {
        "id": "ngrok-stale-ngrok-app",
        "kind": "ngrok",
        "publicUrl": "https://stale.ngrok.app",
        "targetUrl": "http://localhost:4999",
        "targetHost": "localhost",
        "targetPort": 4999,
        "agentApiUrl": "http://127.0.0.1:4040/api/tunnels",
        "status": "dangling"
      }
    ]
  }
  """.data(using: .utf8)!

  let status = try JSONDecoder().decode(PortdeckStatus.self, from: json)
  let service = status.groups[0].worktrees[0].services[0]
  let attached = try #require(service.exposures?.first)
  let dangling = try #require(status.danglingExposures.first)

  #expect(status.exposures?.count == 2)
  #expect(attached.kind == "ngrok")
  #expect(attached.agentPid == 7100)
  #expect(attached.agentCwd == "/repo/acme-web")
  #expect(attached.targetLabel == "localhost:3000")
  #expect(attached.serviceDisplayText == "ngrok https://demo.ngrok.app -> localhost:3000")
  #expect(dangling.danglingDisplayText == "ngrok -> localhost:4999, target down")
  #expect(service.matchesSearch("demo.ngrok", preferNamedURLs: false, context: []))
  #expect(service.matchesSearch("localhost:3000", preferNamedURLs: false, context: []))
}

@Test func categorizesUnknownServicesAndHidesLikelySystemListenersByDefault() throws {
  let unattached = makeService(
    name: "vite",
    source: "process",
    port: 2000,
    url: "http://localhost:2000",
    processName: "node",
    cwd: "/tmp/demo",
    confidence: "medium"
  )
  let needsAttribution = makeService(
    name: "redis",
    source: "docker",
    port: 6379,
    url: "http://localhost:6379",
    confidence: "low",
    groupingReason: "Docker attribution is ambiguous"
  )
  let likelySystem = makeService(
    name: "ControlCenter",
    source: "process",
    port: 5000,
    url: "http://localhost:5000",
    processName: "ControlCenter",
    cwd: "/",
    confidence: "low"
  )

  #expect(unattached.unknownServiceCategory == .unattached)
  #expect(needsAttribution.unknownServiceCategory == .needsAttribution)
  #expect(likelySystem.unknownServiceCategory == .likelySystem)

  let hidden = [unattached, needsAttribution, likelySystem].unknownServiceSections(
    showLikelySystemListeners: false,
    searchText: "",
    preferNamedURLs: false
  )

  #expect(hidden.map(\.category) == [.unattached, .needsAttribution])
  #expect(hidden.flatMap(\.services).map(\.id) == [unattached.id, needsAttribution.id])

  let searched = [unattached, needsAttribution, likelySystem].unknownServiceSections(
    showLikelySystemListeners: false,
    searchText: "controlcenter",
    preferNamedURLs: false
  )

  #expect(searched.map(\.category) == [.likelySystem])
  #expect(searched.flatMap(\.services).map(\.id) == [likelySystem.id])

  let visible = [unattached, needsAttribution, likelySystem].unknownServiceSections(
    showLikelySystemListeners: true,
    searchText: "",
    preferNamedURLs: false
  )

  #expect(visible.map(\.category) == [.unattached, .needsAttribution, .likelySystem])
}

@Test func includesEveryUnknownServiceWithoutCategoryFilters() throws {
  let openableUnknown = makeService(
    name: "astro",
    source: "process",
    port: 4321,
    url: "http://localhost:4321",
    processName: "node",
    cwd: "/tmp/site",
    confidence: "medium"
  )
  let nonOpenableUnknown = makeService(
    name: "debug-adapter",
    source: "process",
    port: 9229,
    url: nil,
    processName: "node",
    cwd: "/tmp/site",
    confidence: "medium"
  )

  let sections = [openableUnknown, nonOpenableUnknown].unknownServiceSections(
    showLikelySystemListeners: false,
    searchText: "",
    preferNamedURLs: false
  )

  #expect(sections.map(\.category) == [.unattached])
  #expect(sections.flatMap(\.services).map(\.id) == [openableUnknown.id, nonOpenableUnknown.id])
}

@Test func hidesRootProjectPackageFromMainListContextSummary() throws {
  let worktree = makeWorktree(
    name: "main",
    branch: "main",
    services: [
      makeService(
        name: "web",
        source: "process",
        port: 3000,
        url: "http://localhost:3000",
        subcontext: makeSubcontext(
          displayName: "acme-web",
          relativePath: "."
        )
      )
    ]
  )

  #expect(worktree.mainListContextSummary(projectName: "acme-web") == nil)
}

@Test func keepsDistinctWorktreeAndDropsDuplicateRootPackageFromMainListContextSummary() throws {
  let worktree = makeWorktree(
    name: "feature/free-project-billing-gate",
    branch: "feature/free-project-billing-gate",
    services: [
      makeService(
        name: "web",
        source: "process",
        port: 3000,
        url: "http://localhost:3000",
        subcontext: makeSubcontext(
          displayName: "acme-web",
          relativePath: "."
        )
      )
    ]
  )

  #expect(worktree.mainListContextSummary(projectName: "acme-web") == "feature/free-project-billing-gate")
}

@Test func showsPrimaryMainWorktreeLabelWhenProjectHasMultipleWorktrees() throws {
  let worktree = makeWorktree(
    name: "main",
    branch: "main",
    path: "/repo/acme",
    services: [
      makeService(name: "web", source: "process", port: 3000, url: "http://localhost:3000")
    ]
  )

  #expect(
    worktree.mainListContextSummary(
      projectName: "acme",
      repoRoot: "/repo/acme",
      showsPrimaryWorktreeLabel: true
    ) == "main"
  )
}

@Test func addsFolderNameForLinkedMainWorktreeWhenItDisambiguates() throws {
  let worktree = makeWorktree(
    name: "main",
    branch: "main",
    path: "/repo/worktrees/acme-lab",
    services: [
      makeService(name: "web", source: "process", port: 3000, url: "http://localhost:3000")
    ]
  )

  #expect(
    worktree.mainListContextSummary(
      projectName: "acme",
      repoRoot: "/repo/acme",
      showsPrimaryWorktreeLabel: true
    ) == "main · acme-lab"
  )
}

@Test func keepsDistinctPackageInMainListContextSummary() throws {
  let worktree = makeWorktree(
    name: "main",
    branch: "main",
    services: [
      makeService(
        name: "web",
        source: "process",
        port: 3000,
        url: "http://localhost:3000",
        subcontext: makeSubcontext(
          displayName: "@acme/web",
          relativePath: "apps/web"
        )
      )
    ]
  )

  #expect(worktree.mainListContextSummary(projectName: "acme") == "@acme/web")
}

@Test func summarizesMultipleDistinctPackagesInMainListContextSummary() throws {
  let worktree = makeWorktree(
    name: "main",
    branch: "main",
    services: [
      makeService(
        name: "web",
        source: "process",
        port: 3000,
        url: "http://localhost:3000",
        subcontext: makeSubcontext(
          displayName: "@acme/web",
          path: "/repo/acme/apps/web",
          relativePath: "apps/web"
        )
      ),
      makeService(
        name: "api",
        source: "process",
        port: 3001,
        url: "http://localhost:3001",
        subcontext: makeSubcontext(
          displayName: "@acme/api",
          path: "/repo/acme/apps/api",
          relativePath: "apps/api"
        )
      )
    ]
  )

  #expect(worktree.mainListContextSummary(projectName: "acme") == "2 packages")
}

@Test func compactSearchMatchesServiceAndContextFields() throws {
  let service = makeService(
    name: "convex-local-backend",
    source: "process",
    port: 3210,
    url: "http://localhost:3210",
    processName: "node",
    command: "convex dev",
    cwd: "/repo/acme-web/packages/lab-account-settings",
    confidence: "high",
    subcontext: ServiceSubcontext(
      type: "package",
      name: "lab-account-settings",
      displayName: "lab-account-settings",
      path: "/repo/acme-web/packages/lab-account-settings",
      relativePath: "packages/lab-account-settings",
      manifestPath: "/repo/acme-web/packages/lab-account-settings/package.json"
    )
  )

  #expect(service.matchesSearch("convex", preferNamedURLs: false, context: []))
  #expect(service.matchesSearch("3210", preferNamedURLs: false, context: []))
  #expect(service.matchesSearch("acme-web", preferNamedURLs: false, context: ["acme-web", "feature/lab-account-settings"]))
  #expect(service.matchesSearch("lab-account", preferNamedURLs: false, context: []))
  #expect(!service.matchesSearch("postgres", preferNamedURLs: false, context: ["acme-web"]))
}

@Test func identifiesStoppableProcessAndDockerServices() throws {
  let processService = makeService(
    name: "web",
    source: "process",
    port: 3000,
    url: "http://localhost:3000",
    processName: "node"
  )
  let dockerService = makeService(
    name: "db",
    source: "docker",
    port: 5432,
    url: "http://localhost:5432",
    containerName: "portdeck-db-1",
    containerId: "abc123"
  )

  #expect(processService.canStop)
  #expect(dockerService.canStop)
}

@Test func hidesStopForServicesWithoutSafeIdentity() throws {
  let processWithoutPID = makeService(
    name: "web",
    source: "process",
    port: 3000,
    url: "http://localhost:3000",
    pid: nil
  )
  let dockerWithoutContainer = makeService(
    name: "db",
    source: "docker",
    port: 5432,
    url: "http://localhost:5432",
    containerId: nil
  )
  let registeredService = makeService(
    name: "registered",
    source: "registered",
    port: 7000,
    url: "http://localhost:7000"
  )

  #expect(!processWithoutPID.canStop)
  #expect(!dockerWithoutContainer.canStop)
  #expect(!registeredService.canStop)
}

@Test func formatsShortStopConfirmationTitles() throws {
  let processService = makeService(
    name: "web",
    source: "process",
    port: 3000,
    url: "http://localhost:3000",
    processName: "node"
  )
  let dockerService = makeService(
    name: "db",
    source: "docker",
    port: 5432,
    url: "http://localhost:5432",
    containerName: "portdeck-db-1",
    containerId: "abc123"
  )
  let serviceWithoutPort = makeService(
    name: "node",
    source: "process",
    port: nil,
    url: nil,
    processName: "node"
  )

  #expect(processService.stopConfirmationTitle == "Stop node on :3000?")
  #expect(dockerService.stopConfirmationTitle == "Stop portdeck-db-1 on :5432?")
  #expect(serviceWithoutPort.stopConfirmationTitle == "Stop node?")
}

@Test func collectsProjectStopAllTargetFromSafeServicesOnly() throws {
  let processService = makeService(
    name: "web",
    source: "process",
    port: 3000,
    url: "http://localhost:3000",
    pid: 3001,
    processName: "node"
  )
  let dockerService = makeService(
    name: "db",
    source: "docker",
    port: 5432,
    url: "http://localhost:5432",
    containerName: "portdeck-db-1",
    containerId: "abc123"
  )
  let staleProcess = makeService(
    name: "stale-web",
    source: "process",
    status: "stale",
    port: 3002,
    url: "http://localhost:3002",
    pid: 3002
  )
  let processWithoutPID = makeService(
    name: "missing-owner",
    source: "process",
    port: 3003,
    url: "http://localhost:3003",
    pid: nil
  )
  let dockerWithoutContainer = makeService(
    name: "db-no-id",
    source: "docker",
    port: 5433,
    url: "http://localhost:5433",
    containerId: nil
  )
  let registeredService = makeService(
    name: "registered",
    source: "registered",
    port: 7000,
    url: "http://localhost:7000"
  )
  let group = makeProjectGroup(
    name: "PortDeck",
    services: [
      processService,
      staleProcess,
      processWithoutPID,
      registeredService,
      dockerService,
      dockerWithoutContainer
    ]
  )

  #expect(group.stoppableServices.map(\.id) == [processService.id, dockerService.id])

  let target = try #require(group.stopAllTarget)
  #expect(target.projectID == group.id)
  #expect(target.projectName == "PortDeck")
  #expect(target.services.map(\.id) == [processService.id, dockerService.id])
  #expect(target.serviceIDs == [processService.id, dockerService.id])
  #expect(target.stoppableCount == 2)
  #expect(target.containsService(processService))
  #expect(target.containsService(dockerService))
  #expect(!target.containsService(staleProcess))
}

@Test func omitsProjectStopAllTargetWhenNoServicesAreSafeToStop() throws {
  let group = makeProjectGroup(
    name: "PortDeck",
    services: [
      makeService(
        name: "stale-web",
        source: "process",
        status: "stale",
        port: 3000,
        url: "http://localhost:3000",
        pid: 3000
      ),
      makeService(
        name: "missing-owner",
        source: "process",
        port: 3001,
        url: "http://localhost:3001",
        pid: nil
      ),
      makeService(
        name: "registered",
        source: "registered",
        port: 7000,
        url: "http://localhost:7000"
      ),
      makeService(
        name: "db-no-id",
        source: "docker",
        port: 5432,
        url: "http://localhost:5432",
        containerId: nil
      )
    ]
  )

  #expect(group.stoppableServices.isEmpty)
  #expect(group.stopAllTarget == nil)
}

@Test func formatsProjectStopAllConfirmationTitles() throws {
  let single = try #require(
    makeProjectGroup(
      name: "PortDeck",
      services: [
        makeService(
          name: "web",
          source: "process",
          port: 3000,
          url: "http://localhost:3000",
          pid: 3000
        )
      ]
    ).stopAllTarget
  )
  let multiple = try #require(
    makeProjectGroup(
      name: "PortDeck",
      services: [
        makeService(
          name: "web",
          source: "process",
          port: 3000,
          url: "http://localhost:3000",
          pid: 3000
        ),
        makeService(
          name: "db",
          source: "docker",
          port: 5432,
          url: "http://localhost:5432",
          containerId: "abc123"
        ),
        makeService(
          name: "worker",
          source: "process",
          port: 3001,
          url: "http://localhost:3001",
          pid: 3001
        )
      ]
    ).stopAllTarget
  )

  #expect(single.confirmationTitle == "Stop 1 service in PortDeck?")
  #expect(multiple.confirmationTitle == "Stop 3 services in PortDeck?")
}

@Test func formatsStopBatchFailureMessages() throws {
  let success = PortdeckStopBatchSummary(
    projectName: "PortDeck",
    totalCount: 3,
    failureMessages: []
  )
  let singleFailure = PortdeckStopBatchSummary(
    projectName: "PortDeck",
    totalCount: 3,
    failureMessages: ["Docker unavailable"]
  )
  let multipleFailures = PortdeckStopBatchSummary(
    projectName: "PortDeck",
    totalCount: 4,
    failureMessages: ["Docker unavailable", "Service not found"]
  )

  #expect(success.failureMessage == nil)
  #expect(singleFailure.failureMessage == "1 of 3 services failed in PortDeck: Docker unavailable")
  #expect(multipleFailures.failureMessage == "2 of 4 services failed in PortDeck: Docker unavailable; Service not found")
}

@Test func headerProgressIgnoresBackgroundRefreshes() throws {
  #expect(!PortdeckHeaderProgressState(isRefreshing: false, isStopping: false).showsProgress)
  #expect(!PortdeckHeaderProgressState(isRefreshing: true, isStopping: false).showsProgress)
  #expect(PortdeckHeaderProgressState(isRefreshing: false, isStopping: true).showsProgress)
  #expect(PortdeckHeaderProgressState(isRefreshing: true, isStopping: true).showsProgress)
}

@Test func stopControlPresentationUsesDestructiveFilledIcon() throws {
  #expect(PortdeckStopControlPresentation.destructive.systemImage == "xmark.circle.fill")
  #expect(PortdeckStopControlPresentation.destructive.isDestructive)
}

@Test func openControlPresentationUsesPrimaryFilledIcon() throws {
  #expect(PortdeckOpenControlPresentation.primary.systemImage == "arrow.up.forward.square.fill")
  #expect(PortdeckOpenControlPresentation.primary.isPrimary)
}

@Test func decodesStopResultJson() throws {
  let json = """
  {
    "ok": false,
    "serviceId": "missing-service",
    "action": "stop",
    "message": "Service not found"
  }
  """.data(using: .utf8)!

  let result = try JSONDecoder().decode(PortdeckStopResult.self, from: json)

  #expect(result.ok == false)
  #expect(result.serviceId == "missing-service")
  #expect(result.action == "stop")
  #expect(result.message == "Service not found")
}

private func makeService(
  name: String,
  source: String,
  status: String = "running",
  port: Int?,
  url: String?,
  pid: Int? = 123,
  processName: String? = nil,
  command: String? = nil,
  cwd: String? = nil,
  containerName: String? = nil,
  containerId: String? = "abc",
  activity: ServiceActivity? = nil,
  confidence: String = "high",
  subcontext: ServiceSubcontext? = nil,
  groupingReason: String? = nil
) -> PortdeckService {
  PortdeckService(
    id: "\(source)-\(name)-\(port.map(String.init) ?? "none")",
    name: name,
    source: source,
    status: status,
    port: port,
    url: url,
    address: nil,
    protocolName: "TCP",
    pid: source == "process" ? pid : nil,
    processName: processName,
    command: command,
    cwd: cwd,
    hostIp: source == "docker" ? "127.0.0.1" : nil,
    containerName: source == "docker" ? containerName ?? name : nil,
    containerId: source == "docker" ? containerId : nil,
    containerPort: source == "docker" ? port : nil,
    image: source == "docker" ? "\(name):latest" : nil,
    activity: activity,
    confidence: confidence,
    subcontext: subcontext,
    groupingReason: groupingReason
  )
}

private func makeProjectGroup(name: String, services: [PortdeckService]) -> ProjectGroup {
  ProjectGroup(
    projectName: name,
    repoRoot: "/repo/\(name)",
    worktrees: [
      makeWorktree(name: "main", branch: "main", path: "/repo/\(name)", services: services)
    ]
  )
}

private func makeWorktree(
  name: String,
  branch: String?,
  path: String = "/repo/acme",
  services: [PortdeckService]
) -> WorktreeGroup {
  WorktreeGroup(
    name: name,
    path: path,
    branch: branch,
    services: services
  )
}

private func makeSubcontext(
  displayName: String,
  path: String = "/repo/acme",
  relativePath: String
) -> ServiceSubcontext {
  ServiceSubcontext(
    type: "package",
    name: displayName,
    displayName: displayName,
    path: path,
    relativePath: relativePath,
    manifestPath: "\(path)/package.json"
  )
}
