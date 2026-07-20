import Foundation

public enum PortdeckCommandPaletteRole: Equatable, Sendable {
  case open
  case destructive
  case utility
}

public enum PortdeckCommandPaletteActionKind: Equatable, Sendable {
  case openService
  case openFolder
  case openInVSCode
  case revealInFinder
  case openRepository
  case stopService
  case stopProject
  case startSavedProject
  case stopSavedProject
  case restartSavedProject
  case openSavedProjectLog
  case refreshStatus
  case copyJSON
  case switchSource(PortdeckDashboardSource)
  case toggleSystemListeners
}

public struct PortdeckCommandPaletteAction: Identifiable, Sendable {
  public let id: String
  public let kind: PortdeckCommandPaletteActionKind
  public let title: String
  public let subtitle: String?
  public let systemImage: String
  public let role: PortdeckCommandPaletteRole
  public let service: PortdeckService?
  public let stopAllTarget: ProjectStopAllTarget?
  public let project: ProjectGroup?
  public let openURLString: String?
  public let filePath: String?
  public let aliases: [String]

  let searchTokens: [String]

  public init(
    id: String,
    kind: PortdeckCommandPaletteActionKind,
    title: String,
    subtitle: String?,
    systemImage: String,
    role: PortdeckCommandPaletteRole,
    service: PortdeckService? = nil,
    stopAllTarget: ProjectStopAllTarget? = nil,
    project: ProjectGroup? = nil,
    openURLString: String? = nil,
    filePath: String? = nil,
    aliases: [String] = [],
    searchTokens: [String] = []
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.systemImage = systemImage
    self.role = role
    self.service = service
    self.stopAllTarget = stopAllTarget
    self.project = project
    self.openURLString = openURLString
    self.filePath = filePath
    self.aliases = aliases
    self.searchTokens = searchTokens
  }
}

public enum PortdeckCommandPalette {
  public static func collect(
    status: PortdeckStatus,
    preferNamedURLs: Bool,
    showLikelySystemListeners: Bool,
    dashboardSources: [PortdeckDashboardSource] = PortdeckDashboardSource.allCases
  ) -> [PortdeckCommandPaletteAction] {
    var actions: [PortdeckCommandPaletteAction] = [
      PortdeckCommandPaletteAction(
        id: "refresh-status",
        kind: .refreshStatus,
        title: "Refresh current view",
        subtitle: "Reload the selected service source",
        systemImage: "arrow.clockwise",
        role: .utility,
        aliases: ["refresh", "reload", "status"],
        searchTokens: ["status", "reload", "service source"]
      ),
      PortdeckCommandPaletteAction(
        id: "copy-json",
        kind: .copyJSON,
        title: "Copy status JSON",
        subtitle: "Copy the current status payload",
        systemImage: "doc.on.doc",
        role: .utility,
        aliases: ["json", "copy json", "status json"],
        searchTokens: ["status", "payload", "clipboard"]
      ),
      PortdeckCommandPaletteAction(
        id: "toggle-system-listeners",
        kind: .toggleSystemListeners,
        title: showLikelySystemListeners ? "Hide likely system listeners" : "Show likely system listeners",
        subtitle: "Control macOS background listeners in the main view",
        systemImage: "desktopcomputer",
        role: .utility,
        aliases: ["system listeners", "show system", "hide system", "diagnostics"],
        searchTokens: ["unknown", "macos", "background", "listeners", "diagnostics"]
      )
    ]

    for source in dashboardSources {
      actions.append(sourceAction(source))
    }

    for group in status.groups {
      actions.append(contentsOf: projectActions(group))

      if group.savedProject == nil, let target = group.stopAllTarget {
        actions.append(stopAllAction(target))
      }

      for worktree in group.worktrees {
        actions.append(contentsOf: worktreeActions(worktree, in: group))

        for service in worktree.services {
          actions.append(contentsOf: serviceActions(
            service,
            preferNamedURLs: preferNamedURLs,
            projectName: group.projectName,
            worktreeName: worktree.name
          ))
        }
      }
    }

    for service in status.unknown {
      actions.append(contentsOf: serviceActions(
        service,
        preferNamedURLs: preferNamedURLs,
        projectName: "Unknown",
        worktreeName: nil
      ))
    }

    return actions
  }

  private static func projectActions(_ group: ProjectGroup) -> [PortdeckCommandPaletteAction] {
    var actions: [PortdeckCommandPaletteAction] = []
    let context = [
      group.projectName,
      group.repoRoot,
      group.remoteUrl,
      group.repositoryUrl
    ].compactMap { $0 }

    if let saved = group.savedProject {
      let stateContext = context + [saved.state, saved.port.map(String.init)].compactMap { $0 }
      switch saved.state {
      case "running", "starting":
        actions.append(PortdeckCommandPaletteAction(
          id: "stop-saved-project-\(saved.id)",
          kind: .stopSavedProject,
          title: "Stop \(group.projectName)",
          subtitle: saved.port.map { "PortDeck-owned on :\($0)" } ?? "PortDeck-owned project",
          systemImage: "stop.fill",
          role: .destructive,
          project: group,
          aliases: ["stop project", "stop \(group.projectName)"],
          searchTokens: stateContext
        ))
      case "external":
        actions.append(PortdeckCommandPaletteAction(
          id: "restart-external-project-\(saved.id)",
          kind: .restartSavedProject,
          title: "Restart \(group.projectName) via PortDeck",
          subtitle: "Stop discovered services, then run the saved command",
          systemImage: "arrow.clockwise",
          role: .utility,
          project: group,
          aliases: ["restart project", "take over project", "run via portdeck"],
          searchTokens: stateContext
        ))
      default:
        actions.append(PortdeckCommandPaletteAction(
          id: "start-saved-project-\(saved.id)",
          kind: .startSavedProject,
          title: "Start \(group.projectName)",
          subtitle: saved.port.map { "Start on :\($0)" } ?? "Run the saved command",
          systemImage: "play.fill",
          role: .utility,
          project: group,
          aliases: ["start project", "run project", "start \(group.projectName)"],
          searchTokens: stateContext
        ))
      }

      if saved.supportsPortSwitching {
        actions.append(PortdeckCommandPaletteAction(
          id: "change-saved-project-port-\(saved.id)",
          kind: .restartSavedProject,
          title: "Change \(group.projectName) port",
          subtitle: saved.port.map { "Currently :\($0)" },
          systemImage: "arrow.left.arrow.right",
          role: .utility,
          project: group,
          aliases: ["change port", "switch port", "restart on port"],
          searchTokens: stateContext
        ))
      }

      if let logPath = saved.logPath {
        actions.append(PortdeckCommandPaletteAction(
          id: "open-saved-project-log-\(saved.id)",
          kind: .openSavedProjectLog,
          title: "View \(group.projectName) log",
          subtitle: logPath,
          systemImage: "doc.text",
          role: .open,
          project: group,
          filePath: logPath,
          aliases: ["project log", "view log", "open log"],
          searchTokens: stateContext + [logPath]
        ))
      }
    }

    if let folderURL = group.repoFolderURLString, let repoRoot = group.repoRoot {
      actions.append(
        PortdeckCommandPaletteAction(
          id: "open-project-folder-\(group.id)",
          kind: .openFolder,
          title: "Open \(group.projectName) repo folder",
          subtitle: repoRoot,
          systemImage: "folder",
          role: .open,
          openURLString: folderURL,
          filePath: repoRoot,
          aliases: ["open repo", "open repo folder", "repo folder", "open \(group.projectName)"],
          searchTokens: context + ["folder", "repo", repoRoot]
        )
      )
      actions.append(
        PortdeckCommandPaletteAction(
          id: "open-project-vscode-\(group.id)",
          kind: .openInVSCode,
          title: "Open \(group.projectName) repo in VS Code",
          subtitle: repoRoot,
          systemImage: "chevron.left.forwardslash.chevron.right",
          role: .open,
          filePath: repoRoot,
          aliases: ["vscode", "vs code", "code", "open in vscode", "open repo in vscode"],
          searchTokens: context + ["vscode", "vs code", "code", "repo", repoRoot]
        )
      )
      actions.append(
        PortdeckCommandPaletteAction(
          id: "reveal-project-folder-\(group.id)",
          kind: .revealInFinder,
          title: "Reveal \(group.projectName) repo in Finder",
          subtitle: repoRoot,
          systemImage: "finder",
          role: .open,
          filePath: repoRoot,
          aliases: ["reveal repo", "show repo in finder", "finder", "repo finder"],
          searchTokens: context + ["reveal", "finder", repoRoot]
        )
      )
    }

    if let repositoryURL = group.repositoryOpenURLString {
      actions.append(
        PortdeckCommandPaletteAction(
          id: "open-project-repository-\(group.id)",
          kind: .openRepository,
          title: "Open \(group.projectName) on GitHub",
          subtitle: repositoryURL,
          systemImage: "globe",
          role: .open,
          openURLString: repositoryURL,
          aliases: ["github", "open github", "open remote", "origin", "repository"],
          searchTokens: context + ["github", "remote", "origin", repositoryURL]
        )
      )
    }

    return actions
  }

  private static func worktreeActions(_ worktree: WorktreeGroup, in group: ProjectGroup) -> [PortdeckCommandPaletteAction] {
    var actions: [PortdeckCommandPaletteAction] = []
    let label = worktreeActionLabel(worktree, in: group)
    let context = [
      group.projectName,
      group.repoRoot,
      group.remoteUrl,
      group.repositoryUrl,
      worktree.name,
      worktree.path,
      worktree.branch,
      worktree.remoteUrl,
      worktree.repositoryUrl
    ].compactMap { $0 }

    if !shouldDeduplicateWorktreeFolderActions(worktree, in: group),
      let folderURL = worktree.folderURLString,
      let path = worktree.path
    {
      actions.append(
        PortdeckCommandPaletteAction(
          id: "open-worktree-folder-\(worktree.id)",
          kind: .openFolder,
          title: "Open \(label) worktree folder",
          subtitle: path,
          systemImage: "folder.badge.gearshape",
          role: .open,
          openURLString: folderURL,
          filePath: path,
          aliases: ["open worktree", "open worktree folder", "worktree folder", "open \(label)"],
          searchTokens: context + ["folder", "worktree", path, label]
        )
      )
      actions.append(
        PortdeckCommandPaletteAction(
          id: "open-worktree-vscode-\(worktree.id)",
          kind: .openInVSCode,
          title: "Open \(label) worktree in VS Code",
          subtitle: path,
          systemImage: "chevron.left.forwardslash.chevron.right",
          role: .open,
          filePath: path,
          aliases: ["vscode", "vs code", "code", "open in vscode", "open worktree in vscode"],
          searchTokens: context + ["vscode", "vs code", "code", "worktree", path, label]
        )
      )
      actions.append(
        PortdeckCommandPaletteAction(
          id: "reveal-worktree-folder-\(worktree.id)",
          kind: .revealInFinder,
          title: "Reveal \(label) worktree in Finder",
          subtitle: path,
          systemImage: "finder",
          role: .open,
          filePath: path,
          aliases: ["reveal worktree", "show worktree in finder", "finder", "worktree finder"],
          searchTokens: context + ["reveal", "finder", path, label]
        )
      )
    }

    if let repositoryURL = worktree.repositoryOpenURLString,
      repositoryURL != group.repositoryOpenURLString
    {
      actions.append(
        PortdeckCommandPaletteAction(
          id: "open-worktree-repository-\(worktree.id)",
          kind: .openRepository,
          title: "Open \(label) on GitHub",
          subtitle: repositoryURL,
          systemImage: "globe",
          role: .open,
          openURLString: repositoryURL,
          aliases: ["github", "open github", "open remote", "origin", "repository"],
          searchTokens: context + ["github", "remote", "origin", repositoryURL, label]
        )
      )
    }

    return actions
  }

  public static func matching(
    _ query: String,
    in actions: [PortdeckCommandPaletteAction]
  ) -> [PortdeckCommandPaletteAction] {
    let normalizedQuery = normalize(query)
    guard !normalizedQuery.isEmpty else {
      return actions
    }

    let terms = normalizedQuery.split(separator: " ").map(String.init)
    return actions.enumerated()
      .compactMap { offset, action -> (score: Int, offset: Int, action: PortdeckCommandPaletteAction)? in
        guard let score = matchScore(normalizedQuery: normalizedQuery, terms: terms, action: action) else {
          return nil
        }
        return (score, offset, action)
      }
      .sorted { left, right in
        if left.score == right.score {
          return left.offset < right.offset
        }
        return left.score > right.score
      }
      .map(\.action)
  }

  public static func dashboardSourceActions(
    dashboardSources: [PortdeckDashboardSource] = PortdeckDashboardSource.allCases
  ) -> [PortdeckCommandPaletteAction] {
    dashboardSources.map(sourceAction)
  }

  private static func sourceAction(_ source: PortdeckDashboardSource) -> PortdeckCommandPaletteAction {
    PortdeckCommandPaletteAction(
      id: "source-\(source.rawValue)",
      kind: .switchSource(source),
      title: "Switch to \(source.paletteTitle)",
      subtitle: source.paletteSubtitle,
      systemImage: source.paletteSystemImage,
      role: .utility,
      aliases: [source.rawValue, "\(source.rawValue) services", "show \(source.rawValue)", "switch \(source.rawValue)"],
      searchTokens: [source.paletteTitle, source.paletteSubtitle]
    )
  }

  private static func stopAllAction(_ target: ProjectStopAllTarget) -> PortdeckCommandPaletteAction {
    PortdeckCommandPaletteAction(
      id: "stop-project-\(target.projectID)",
      kind: .stopProject,
      title: "Stop all in \(target.projectName)",
      subtitle: "\(target.stoppableCount) \(target.stoppableCount == 1 ? "service" : "services")",
      systemImage: PortdeckStopControlPresentation.destructive.systemImage,
      role: .destructive,
      stopAllTarget: target,
      aliases: [
        "kill servers",
        "stop servers",
        "stop all",
        "stop \(target.projectName)",
        "kill \(target.projectName)"
      ],
      searchTokens: [target.projectName, target.serviceIDs.joined(separator: " ")]
    )
  }

  private static func shouldDeduplicateWorktreeFolderActions(_ worktree: WorktreeGroup, in group: ProjectGroup) -> Bool {
    guard group.worktrees.count == 1,
      let repoRoot = group.repoRoot,
      let worktreePath = worktree.path
    else {
      return false
    }

    return URL(fileURLWithPath: repoRoot).standardizedFileURL.path == URL(fileURLWithPath: worktreePath).standardizedFileURL.path
  }

  private static func worktreeActionLabel(_ worktree: WorktreeGroup, in group: ProjectGroup) -> String {
    let preferred = worktree.branch ?? worktree.name
    let normalized = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalized.isEmpty {
      return normalized
    }

    return group.projectName
  }

  private static func serviceActions(
    _ service: PortdeckService,
    preferNamedURLs: Bool,
    projectName: String,
    worktreeName: String?
  ) -> [PortdeckCommandPaletteAction] {
    var actions: [PortdeckCommandPaletteAction] = []
    let context = contextTokens(service: service, projectName: projectName, worktreeName: worktreeName, preferNamedURLs: preferNamedURLs)
    let subtitle = [projectName, worktreeName].compactMap { value in
      guard let value, value != "main" else {
        return nil
      }
      return value
    }.joined(separator: " · ")

    if let openURL = service.openURLString(preferNamedURLs: preferNamedURLs) {
      actions.append(
        PortdeckCommandPaletteAction(
          id: "open-service-\(service.id)",
          kind: .openService,
          title: "Open \(service.name)\(targetSuffix(for: service, preferNamedURLs: preferNamedURLs))",
          subtitle: subtitle.isEmpty ? nil : subtitle,
          systemImage: PortdeckOpenControlPresentation.primary.systemImage,
          role: .open,
          service: service,
          openURLString: openURL,
          aliases: openAliases(for: service),
          searchTokens: context + [openURL]
        )
      )
    }

    if service.canStop {
      actions.append(
        PortdeckCommandPaletteAction(
          id: "stop-service-\(service.id)",
          kind: .stopService,
          title: service.stopActionTitle,
          subtitle: subtitle.isEmpty ? nil : subtitle,
          systemImage: PortdeckStopControlPresentation.destructive.systemImage,
          role: .destructive,
          service: service,
          aliases: stopAliases(for: service),
          searchTokens: context
        )
      )
    }

    return actions
  }

  private static func targetSuffix(for service: PortdeckService, preferNamedURLs: Bool) -> String {
    if let port = service.port {
      return " on :\(port)"
    }
    if let label = service.primaryEndpointLabel(preferNamedURLs: preferNamedURLs) {
      return " on \(label)"
    }
    return ""
  }

  private static func contextTokens(
    service: PortdeckService,
    projectName: String,
    worktreeName: String?,
    preferNamedURLs: Bool
  ) -> [String] {
    let serviceTokens: [String?] = [
      projectName,
      worktreeName,
      service.id,
      service.name,
      service.source,
      service.status,
      service.port.map(String.init),
      service.url,
      service.address,
      service.protocolName,
      service.primaryEndpointLabel(preferNamedURLs: preferNamedURLs),
      service.rawEndpointLabel,
      service.pid.map(String.init),
      service.processName,
      service.command,
      service.cwd,
      service.hostIp,
      service.containerName,
      service.containerId,
      service.containerPort.map(String.init),
      service.image,
      service.subcontext?.name,
      service.subcontext?.displayName,
      service.subcontext?.relativePath,
      service.groupingReason
    ]
    let exposureTokens: [String?] = (service.exposures ?? []).flatMap { exposure in
      [
        exposure.kind,
        exposure.publicUrl,
        exposure.targetUrl,
        exposure.targetHost,
        exposure.targetPort.map(String.init),
        exposure.agentCwd,
        exposure.status,
        exposure.targetLabel,
        exposure.serviceDisplayText
      ]
    }

    return (serviceTokens + exposureTokens).compactMap { $0 }
  }

  private static func openAliases(for service: PortdeckService) -> [String] {
    [
      "open",
      "open \(service.name)",
      service.port.map { "open \($0)" },
      service.port.map(String.init)
    ].compactMap { $0 }
  }

  private static func stopAliases(for service: PortdeckService) -> [String] {
    [
      "stop",
      "kill",
      "stop \(service.name)",
      "kill \(service.name)",
      service.port.map { "stop \($0)" },
      service.port.map { "kill \($0)" }
    ].compactMap { $0 }
  }

  private static func matchScore(
    normalizedQuery: String,
    terms: [String],
    action: PortdeckCommandPaletteAction
  ) -> Int? {
    let normalizedAliases = action.aliases.map(normalize)
    if normalizedAliases.contains(normalizedQuery) {
      return 1_000
    }
    if normalizedAliases.contains(where: { $0.hasPrefix(normalizedQuery) || normalizedQuery.hasPrefix($0) }) {
      return 900
    }

    let normalizedTitle = normalize(action.title)
    if normalizedTitle == normalizedQuery {
      return 850
    }
    if normalizedTitle.hasPrefix(normalizedQuery) {
      return 800
    }

    let searchable = ([action.title, action.subtitle] + action.aliases + action.searchTokens)
      .compactMap { $0 }
      .map(normalize)
      .filter { !$0.isEmpty }

    if searchable.contains(where: { $0 == normalizedQuery }) {
      return 700
    }
    if searchable.contains(where: { $0.hasPrefix(normalizedQuery) }) {
      return 650
    }
    if terms.allSatisfy({ term in searchable.contains(where: { $0.contains(term) }) }) {
      return 500
    }

    return nil
  }

  private static func normalize(_ value: String) -> String {
    value
      .lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .joined(separator: " ")
  }
}

private extension PortdeckService {
  var stopActionTitle: String {
    if stopConfirmationTitle.hasSuffix("?") {
      return String(stopConfirmationTitle.dropLast())
    }
    return stopConfirmationTitle
  }
}

private extension PortdeckDashboardSource {
  var paletteTitle: String {
    switch self {
    case .local:
      return "Local"
    case .vercel:
      return "Vercel"
    case .convex:
      return "Convex"
    case .github:
      return "GitHub"
    case .supabase:
      return "Supabase"
    case .cloudflare:
      return "Cloudflare"
    case .railway:
      return "Railway"
    case .fly:
      return "Fly.io"
    case .netlify:
      return "Netlify"
    }
  }

  var paletteSubtitle: String {
    switch self {
    case .local:
      return "Show running services on this Mac"
    case .vercel:
      return "Show Vercel production deployments"
    case .convex:
      return "Show Convex deployments"
    case .github:
      return "Show GitHub Actions"
    case .supabase:
      return "Show Supabase projects"
    case .cloudflare:
      return "Show Cloudflare Workers and Pages"
    case .railway:
      return "Show Railway production services"
    case .fly:
      return "Show Fly apps and Machines"
    case .netlify:
      return "Show Netlify production deployments"
    }
  }

  var paletteSystemImage: String {
    switch self {
    case .local:
      return "desktopcomputer"
    case .vercel:
      return "triangle.fill"
    case .convex:
      return "cube"
    case .github:
      return "arrow.triangle.branch"
    case .supabase:
      return "bolt.fill"
    case .cloudflare:
      return "cloud.fill"
    case .railway:
      return "tram.fill"
    case .fly:
      return "airplane"
    case .netlify:
      return "square.grid.2x2.fill"
    }
  }
}
