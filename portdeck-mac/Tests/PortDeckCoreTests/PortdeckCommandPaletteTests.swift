import Foundation
import Testing
@testable import PortDeckCore

@Test func commandPaletteCollectsGlobalActionsAcrossProjectsAndUnknownServices() throws {
  let launchWeb = makePaletteService(
    id: "launch-web",
    name: "web",
    source: "process",
    port: 3000,
    url: "http://localhost:3000",
    pid: 3000,
    processName: "node"
  )
  let launchWorker = makePaletteService(
    id: "launch-worker",
    name: "worker",
    source: "process",
    port: 3100,
    url: nil,
    pid: 3100,
    processName: "node"
  )
  let dockerDb = makePaletteService(
    id: "docker-db",
    name: "postgres",
    source: "docker",
    port: 5432,
    url: "http://localhost:5432",
    containerName: "portdeck-db-1",
    containerId: "container-5432"
  )
  let unknownWeb = makePaletteService(
    id: "unknown-web",
    name: "vite",
    source: "process",
    port: 5173,
    url: "http://localhost:5173",
    pid: 5173,
    processName: "node"
  )
  let invalidOpen = makePaletteService(
    id: "invalid-open",
    name: "broken",
    source: "process",
    port: 9999,
    url: "not a url",
    pid: 9999,
    processName: "node"
  )
  let status = makePaletteStatus(
    groups: [
      makePaletteProject(name: "Acme Web", services: [launchWeb, launchWorker]),
      makePaletteProject(name: "PortDeck", services: [dockerDb])
    ],
    unknown: [unknownWeb, invalidOpen]
  )

  let actions = PortdeckCommandPalette.collect(
    status: status,
    preferNamedURLs: false,
    showLikelySystemListeners: false
  )

  #expect(actions.containsAction(.openService, title: "Open web on :3000"))
  #expect(actions.containsAction(.openService, title: "Open postgres on :5432"))
  #expect(actions.containsAction(.openService, title: "Open vite on :5173"))
  #expect(!actions.containsAction(.openService, title: "Open broken on :9999"))
  #expect(actions.containsAction(.stopService, title: "Stop node on :3000"))
  #expect(actions.containsAction(.stopService, title: "Stop node on :3100"))
  #expect(actions.containsAction(.stopService, title: "Stop node on :5173"))
  #expect(actions.containsAction(.stopService, title: "Stop portdeck-db-1 on :5432"))
  #expect(actions.containsAction(.stopProject, title: "Stop all in Acme Web"))
  #expect(actions.containsAction(.stopProject, title: "Stop all in PortDeck"))
  #expect(!actions.containsAction(.stopProject, title: "Stop all in Unknown"))
}

@Test func commandPaletteCollectsUtilityAndDashboardSourceActions() throws {
  let actions = PortdeckCommandPalette.collect(
    status: makePaletteStatus(),
    preferNamedURLs: false,
    showLikelySystemListeners: false
  )
  let systemVisibleActions = PortdeckCommandPalette.collect(
    status: makePaletteStatus(),
    preferNamedURLs: false,
    showLikelySystemListeners: true
  )

  #expect(actions.containsAction(.refreshStatus, title: "Refresh current view"))
  #expect(actions.containsAction(.copyJSON, title: "Copy status JSON"))
  #expect(actions.containsAction(.switchSource(.local), title: "Switch to Local"))
  #expect(actions.containsAction(.switchSource(.vercel), title: "Switch to Vercel"))
  #expect(actions.containsAction(.switchSource(.convex), title: "Switch to Convex"))
  #expect(actions.containsAction(.switchSource(.github), title: "Switch to GitHub"))
  #expect(actions.containsAction(.switchSource(.supabase), title: "Switch to Supabase"))
  #expect(actions.containsAction(.switchSource(.cloudflare), title: "Switch to Cloudflare"))
  #expect(actions.containsAction(.switchSource(.railway), title: "Switch to Railway"))
  #expect(actions.containsAction(.switchSource(.fly), title: "Switch to Fly.io"))
  #expect(actions.containsAction(.switchSource(.netlify), title: "Switch to Netlify"))
  #expect(actions.containsAction(.toggleSystemListeners, title: "Show likely system listeners"))
  #expect(systemVisibleActions.containsAction(.toggleSystemListeners, title: "Hide likely system listeners"))
}

@Test func commandPaletteBuildsSavedProjectLifecycleAndJumpActions() throws {
  let stopped = SavedProjectStatus(
    id: "saved-portdeck",
    state: "stopped",
    port: 3000,
    supportsPortSwitching: true,
    logPath: "/private/logs/portdeck.log",
    lastError: nil,
    previousPort: nil
  )
  let status = makePaletteStatus(groups: [
    makePaletteProject(name: "PortDeck", services: [], savedProject: stopped)
  ])

  let actions = PortdeckCommandPalette.collect(
    status: status,
    preferNamedURLs: false,
    showLikelySystemListeners: false
  )

  #expect(actions.containsAction(.startSavedProject, title: "Start PortDeck"))
  #expect(actions.containsAction(.restartSavedProject, title: "Change PortDeck port"))
  #expect(actions.containsAction(.openSavedProjectLog, title: "View PortDeck log"))
  #expect(actions.containsAction(.openFolder, title: "Open PortDeck repo folder"))
  #expect(actions.containsAction(.revealInFinder, title: "Reveal PortDeck repo in Finder"))
  #expect(!actions.contains { $0.kind == .stopProject })
}

@Test func commandPaletteDistinguishesOwnedAndExternallyRunningSavedProjects() {
  let owned = SavedProjectStatus(
    id: "owned",
    state: "running",
    port: 3000,
    supportsPortSwitching: true,
    logPath: nil,
    lastError: nil,
    previousPort: nil
  )
  let external = SavedProjectStatus(
    id: "external",
    state: "external",
    port: 5173,
    supportsPortSwitching: false,
    logPath: nil,
    lastError: nil,
    previousPort: nil
  )
  let actions = PortdeckCommandPalette.collect(
    status: makePaletteStatus(groups: [
      makePaletteProject(name: "Owned", services: [], savedProject: owned),
      makePaletteProject(name: "External", services: [], savedProject: external)
    ]),
    preferNamedURLs: false,
    showLikelySystemListeners: false
  )

  #expect(actions.containsAction(.stopSavedProject, title: "Stop Owned"))
  #expect(actions.containsAction(.restartSavedProject, title: "Restart External via PortDeck"))
  #expect(!actions.containsAction(.stopSavedProject, title: "Stop External"))
}

@Test func commandPaletteUsesOnlyVisibleDashboardSourcesInConfiguredOrder() {
  let visibleSources: [PortdeckDashboardSource] = [.github, .local, .vercel]
  let directActions = PortdeckCommandPalette.dashboardSourceActions(
    dashboardSources: visibleSources
  )
  let collectedActions = PortdeckCommandPalette.collect(
    status: makePaletteStatus(),
    preferNamedURLs: false,
    showLikelySystemListeners: false,
    dashboardSources: visibleSources
  ).filter { action in
    if case .switchSource = action.kind { return true }
    return false
  }

  #expect(directActions.map(\.kind) == [.switchSource(.github), .switchSource(.local), .switchSource(.vercel)])
  #expect(collectedActions.map(\.kind) == [.switchSource(.github), .switchSource(.local), .switchSource(.vercel)])
  #expect(!directActions.contains { $0.kind == .switchSource(.convex) })
  #expect(!collectedActions.contains { $0.kind == .switchSource(.convex) })
  #expect(!directActions.contains { $0.kind == .switchSource(.supabase) })
  #expect(!collectedActions.contains { $0.kind == .switchSource(.supabase) })
  #expect(!directActions.contains { $0.kind == .switchSource(.netlify) })
  #expect(!collectedActions.contains { $0.kind == .switchSource(.netlify) })
}

@Test func commandPaletteMatchesAliasesAndRanksPowerUserQueries() throws {
  let web = makePaletteService(
    id: "web-3000",
    name: "web",
    source: "process",
    port: 3000,
    url: "http://localhost:3000",
    pid: 3000,
    processName: "node",
    command: "npm run dev"
  )
  let dockerDb = makePaletteService(
    id: "db-5432",
    name: "postgres",
    source: "docker",
    port: 5432,
    url: "http://localhost:5432",
    containerName: "portdeck-db-1",
    containerId: "db-container"
  )
  let status = makePaletteStatus(
    groups: [
      makePaletteProject(name: "Acme Web", services: [web]),
      makePaletteProject(name: "PortDeck", services: [dockerDb])
    ]
  )
  let actions = PortdeckCommandPalette.collect(
    status: status,
    preferNamedURLs: false,
    showLikelySystemListeners: false
  )

  #expect(try #require(PortdeckCommandPalette.matching("kill servers", in: actions).first).kind == .stopProject)
  #expect(try #require(PortdeckCommandPalette.matching("stop servers", in: actions).first).kind == .stopProject)
  #expect(PortdeckCommandPalette.matching("open 3000", in: actions).map(\.title).first == "Open web on :3000")
  #expect(PortdeckCommandPalette.matching("docker", in: actions).map(\.title).contains("Open postgres on :5432"))
  #expect(PortdeckCommandPalette.matching("vercel", in: actions).map(\.title).contains("Switch to Vercel"))
  #expect(PortdeckCommandPalette.matching("json", in: actions).map(\.title).first == "Copy status JSON")
  #expect(PortdeckCommandPalette.matching("system listeners", in: actions).map(\.title).first == "Show likely system listeners")
}

@Test func commandPaletteActionPresentationUsesClearRolesAndIcons() throws {
  let status = makePaletteStatus(
    groups: [
      makePaletteProject(
        name: "PortDeck",
        services: [
          makePaletteService(
            id: "web",
            name: "web",
            source: "process",
            port: 3000,
            url: "http://localhost:3000",
            pid: 3000,
            processName: "node"
          )
        ]
      )
    ]
  )

  let actions = PortdeckCommandPalette.collect(
    status: status,
    preferNamedURLs: false,
    showLikelySystemListeners: false
  )
  let open = try #require(actions.first { $0.title == "Open web on :3000" })
  let stop = try #require(actions.first { $0.title == "Stop node on :3000" })
  let refresh = try #require(actions.first { $0.title == "Refresh current view" })

  #expect(open.role == .open)
  #expect(open.systemImage == "arrow.up.forward.square.fill")
  #expect(stop.role == .destructive)
  #expect(stop.systemImage == "xmark.circle.fill")
  #expect(refresh.role == .utility)
  #expect(refresh.systemImage == "arrow.clockwise")
}

@Test func commandPaletteBuildsProjectFolderRevealAndGitHubActions() throws {
  let status = makePaletteStatus(
    groups: [
      makePaletteProject(
        name: "portdeck",
        remoteUrl: "git@github.com:acme-inc/portdeck.git",
        repositoryUrl: "https://github.com/acme-inc/portdeck",
        services: []
      )
    ]
  )

  let actions = PortdeckCommandPalette.collect(
    status: status,
    preferNamedURLs: false,
    showLikelySystemListeners: false
  )
  let openRepo = try #require(actions.first { $0.title == "Open portdeck repo folder" })
  let openRepoInVSCode = try #require(actions.first { $0.title == "Open portdeck repo in VS Code" })
  let revealRepo = try #require(actions.first { $0.title == "Reveal portdeck repo in Finder" })
  let openGitHub = try #require(actions.first { $0.title == "Open portdeck on GitHub" })

  #expect(openRepo.kind == .openFolder)
  #expect(openRepo.openURLString == "file:///repo/portdeck")
  #expect(openRepo.filePath == "/repo/portdeck")
  #expect(openRepoInVSCode.kind == .openInVSCode)
  #expect(openRepoInVSCode.filePath == "/repo/portdeck")
  #expect(revealRepo.kind == .revealInFinder)
  #expect(revealRepo.filePath == "/repo/portdeck")
  #expect(openGitHub.kind == .openRepository)
  #expect(openGitHub.openURLString == "https://github.com/acme-inc/portdeck")
  #expect(!actions.containsAction(.openFolder, title: "Open main worktree folder"))
  #expect(!actions.containsAction(.openInVSCode, title: "Open main worktree in VS Code"))
}

@Test func commandPaletteBuildsLinkedWorktreeFolderActions() throws {
  let status = makePaletteStatus(
    groups: [
      ProjectGroup(
        projectName: "portdeck",
        repoRoot: "/repo/portdeck",
        remoteUrl: "git@github.com:acme-inc/portdeck.git",
        repositoryUrl: "https://github.com/acme-inc/portdeck",
        worktrees: [
          WorktreeGroup(
            name: "feature/jump",
            path: "/repo/worktrees/portdeck-jump",
            branch: "feature/jump",
            remoteUrl: "git@github.com:acme-inc/portdeck.git",
            repositoryUrl: "https://github.com/acme-inc/portdeck",
            services: []
          )
        ]
      )
    ]
  )

  let actions = PortdeckCommandPalette.collect(
    status: status,
    preferNamedURLs: false,
    showLikelySystemListeners: false
  )
  let openWorktree = try #require(actions.first { $0.title == "Open feature/jump worktree folder" })
  let openWorktreeInVSCode = try #require(actions.first { $0.title == "Open feature/jump worktree in VS Code" })
  let revealWorktree = try #require(actions.first { $0.title == "Reveal feature/jump worktree in Finder" })

  #expect(openWorktree.kind == .openFolder)
  #expect(openWorktree.openURLString == "file:///repo/worktrees/portdeck-jump")
  #expect(openWorktree.filePath == "/repo/worktrees/portdeck-jump")
  #expect(openWorktreeInVSCode.kind == .openInVSCode)
  #expect(openWorktreeInVSCode.filePath == "/repo/worktrees/portdeck-jump")
  #expect(revealWorktree.kind == .revealInFinder)
  #expect(revealWorktree.filePath == "/repo/worktrees/portdeck-jump")
}

@Test func commandPaletteHidesJumpActionsWhenMetadataIsMissingOrInvalid() throws {
  let status = makePaletteStatus(
    groups: [
      ProjectGroup(
        projectName: "scratch",
        repoRoot: nil,
        repositoryUrl: "https://github.com/acme/app/tree/main",
        worktrees: [
          WorktreeGroup(
            name: "main",
            path: nil,
            branch: "main",
            services: []
          )
        ]
      )
    ]
  )

  let actions = PortdeckCommandPalette.collect(
    status: status,
    preferNamedURLs: false,
    showLikelySystemListeners: false
  )

  #expect(!actions.contains { $0.kind == .openFolder })
  #expect(!actions.contains { $0.kind == .openInVSCode })
  #expect(!actions.contains { $0.kind == .revealInFinder })
  #expect(!actions.contains { $0.kind == .openRepository })
}

private extension Array where Element == PortdeckCommandPaletteAction {
  func containsAction(_ kind: PortdeckCommandPaletteActionKind, title: String) -> Bool {
    contains { $0.kind == kind && $0.title == title }
  }
}

private func makePaletteStatus(
  groups: [ProjectGroup] = [],
  unknown: [PortdeckService] = []
) -> PortdeckStatus {
  PortdeckStatus(
    schemaVersion: "0.1",
    generatedAt: "2026-06-09T12:00:00.000Z",
    groups: groups,
    unknown: unknown,
    warnings: []
  )
}

private func makePaletteProject(
  name: String,
  remoteUrl: String? = nil,
  repositoryUrl: String? = nil,
  services: [PortdeckService],
  savedProject: SavedProjectStatus? = nil
) -> ProjectGroup {
  ProjectGroup(
    projectName: name,
    repoRoot: "/repo/\(name)",
    remoteUrl: remoteUrl,
    repositoryUrl: repositoryUrl,
    worktrees: [
      WorktreeGroup(
        name: "main",
        path: "/repo/\(name)",
        branch: "main",
        remoteUrl: remoteUrl,
        repositoryUrl: repositoryUrl,
        services: services
      )
    ],
    savedProject: savedProject
  )
}

private func makePaletteService(
  id: String,
  name: String,
  source: String,
  status: String = "running",
  port: Int?,
  url: String?,
  pid: Int? = nil,
  processName: String? = nil,
  command: String? = nil,
  containerName: String? = nil,
  containerId: String? = nil
) -> PortdeckService {
  PortdeckService(
    id: id,
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
    cwd: "/repo/\(name)",
    hostIp: source == "docker" ? "127.0.0.1" : nil,
    containerName: source == "docker" ? containerName : nil,
    containerId: source == "docker" ? containerId : nil,
    containerPort: source == "docker" ? port : nil,
    image: source == "docker" ? "\(name):latest" : nil,
    confidence: "high"
  )
}
