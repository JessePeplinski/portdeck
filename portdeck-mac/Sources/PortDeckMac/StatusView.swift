import AppKit
import PortDeckCore
import SwiftUI

enum FooterAttribution {
  static let jesseName = "Jesse Peplinski"
  static let studioName = "Pep Tech Studios"
  static let jesseURL = URL(string: "https://jessepeplinski.com")!
  static let studioURL = URL(string: "https://peptechstudios.com")!
  static let xURL = URL(string: "https://x.com/jessepeplinski")!
  static let twitchURL = URL(string: "https://www.twitch.tv/peptechdev")!
  static let xIconSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
      <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z"/>
    </svg>
    """
  static let twitchIconSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
      <path d="M4.265 0 1.02 3.245v17.51h5.84V24l3.245-3.245h4.87L21.47 14.26V0zm15.908 13.61-3.245 3.245h-5.84l-2.596 2.596v-2.596H4.265V1.298h15.908zM15.627 4.543h1.298v6.49h-1.298zm-4.87 0h1.298v6.49h-1.298z"/>
    </svg>
    """
}

struct StatusView: View {
  @ObservedObject var model: StatusModel
  @ObservedObject var vercelModel: VercelStatusModel
  @ObservedObject var convexModel: ConvexStatusModel
  @ObservedObject var githubModel: GitHubStatusModel
  @ObservedObject var supabaseModel: SupabaseStatusModel
  @ObservedObject var cloudflareModel: CloudflareStatusModel
  @ObservedObject var railwayModel: RailwayStatusModel
  @ObservedObject var flyModel: FlyStatusModel
  @ObservedObject var netlifyModel: NetlifyStatusModel
  @ObservedObject var providerConfiguration: ProviderConfigurationModel
  @AppStorage("PortDeck.selectedDashboardTab") private var selectedDashboardTab = PortdeckDashboardSource.local.rawValue
  @State private var localSearchText = ""
  @State private var vercelSearchText = ""
  @State private var convexSearchText = ""
  @State private var githubSearchText = ""
  @State private var supabaseSearchText = ""
  @State private var cloudflareSearchText = ""
  @State private var railwaySearchText = ""
  @State private var flySearchText = ""
  @State private var netlifySearchText = ""
  @State private var collapsedProjectIDs: Set<String> = []
  @State private var expandedUnknownSectionIDs: Set<String> = [
    PortdeckUnknownServiceCategory.unattached.id,
    PortdeckUnknownServiceCategory.needsAttribution.id
  ]
  @State private var pendingStopAction: PendingStopAction?
  @State private var isCommandPalettePresented = false
  @State private var isProviderCustomizationPresented = false
  @State private var commandPaletteQuery = ""
  @State private var selectedCommandPaletteIndex = 0
  @FocusState private var isCommandPaletteSearchFocused: Bool

  var body: some View {
    ZStack {
      VStack(spacing: 0) {
        header
        Divider()
        content
        Divider()
        footer
      }

      if isCommandPalettePresented {
        commandPaletteOverlay
      }

      if isProviderCustomizationPresented {
        ProviderCustomizationOverlay(
          model: providerConfiguration,
          onDismiss: dismissProviderCustomization
        )
      }

      if let action = pendingStopAction {
        StopConfirmationOverlay(
          title: action.confirmationTitle,
          confirmButtonTitle: action.confirmButtonTitle,
          isStopping: model.isStopping,
          onCancel: {
            pendingStopAction = nil
          },
          onConfirm: {
            pendingStopAction = nil
            stop(action)
          }
        )
      }
    }
    .task(id: activeSource) {
      let selectedSource = activeSource

      if selectedSource == .local {
        await model.runAutoRefresh()
      } else if selectedSource == .vercel {
        await vercelModel.runAutoRefresh()
      } else if selectedSource == .convex {
        await convexModel.runAutoRefresh(status: model.status)
      } else if selectedSource == .github {
        await githubModel.runAutoRefresh(status: model.status)
      } else if selectedSource == .supabase {
        await supabaseModel.runAutoRefresh()
      } else if selectedSource == .cloudflare {
        await cloudflareModel.runAutoRefresh(status: model.status)
      } else if selectedSource == .railway {
        await railwayModel.runAutoRefresh()
      } else if selectedSource == .fly {
        await flyModel.runAutoRefresh()
      } else if selectedSource == .netlify {
        await netlifyModel.runAutoRefresh()
      }
    }
    .onChange(of: model.status?.generatedAt) {
      if activeSource == .convex {
        Task { await convexModel.updateCandidates(from: model.status) }
      } else if activeSource == .github {
        Task { await githubModel.updateCandidates(from: model.status) }
      } else if activeSource == .cloudflare {
        cloudflareModel.updateCandidates(from: model.status)
      }
    }
    .onChange(of: activeSource) { oldProvider, newProvider in
      if oldProvider == .fly, newProvider != .fly {
        flyModel.cancelRefresh()
      }
      if oldProvider == .netlify, newProvider != .netlify {
        netlifyModel.cancelRefresh()
      }
    }
    .onAppear(perform: restoreDashboardSelection)
    .onChange(of: providerConfiguration.selectedProvider) { _, provider in
      selectedDashboardTab = provider.rawValue
    }
    .onDisappear {
      flyModel.cancelRefresh()
      netlifyModel.cancelRefresh()
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      PortDeckMarkShape()
        .fill(.primary, style: FillStyle(eoFill: true))
        .frame(width: 28, height: 12)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("PortDeck")
          .font(.headline)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        presentProviderCustomization()
      } label: {
        Image(systemName: "slider.horizontal.3")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 26)
          .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Customize providers")
      .help("Customize provider visibility and order")
      Button {
        presentCommandPalette()
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "command")
          Text("K")
            .font(.caption2.monospaced())
            .fontWeight(.semibold)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
      }
      .buttonStyle(.plain)
      .keyboardShortcut("k", modifiers: .command)
      .help("Open action palette")
      if showsHeaderProgress {
        ProgressView()
          .controlSize(.small)
      }
    }
    .padding(14)
  }

  private var content: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        sourceTabs
        selectedSourceContent
          .id(selectedDashboardTab)
      }
      .padding(.horizontal, 10)
      .padding(.top, 10)
      .padding(.bottom, 12)
    }
  }

  private var selectedSource: PortdeckDashboardSource {
    providerConfiguration.selectedProvider
  }

  private var activeSource: PortdeckDashboardSource {
    selectedSource
  }

  @ViewBuilder
  private var selectedSourceContent: some View {
    providerContent
  }

  @ViewBuilder
  private var providerContent: some View {
    switch selectedSource {
    case .local:
      localContent
    case .vercel:
      if vercelModel.connectionState == .connected {
        searchField(placeholder: "Filter Vercel projects...", text: $vercelSearchText)
      }
      VercelStatusView(model: vercelModel, searchText: vercelSearchText)
    case .convex:
      if !convexModel.candidates.isEmpty {
        searchField(placeholder: "Filter Convex projects...", text: $convexSearchText)
      }
      ConvexStatusView(model: convexModel, searchText: convexSearchText)
    case .github:
      if !githubModel.candidates.isEmpty {
        searchField(placeholder: "Filter GitHub Actions...", text: $githubSearchText)
      }
      GitHubStatusView(
        model: githubModel,
        searchText: githubSearchText,
        onRefresh: { Task { await githubModel.refresh(status: model.status) } }
      )
    case .supabase:
      if !supabaseModel.projects.isEmpty {
        searchField(placeholder: "Filter Supabase projects...", text: $supabaseSearchText)
      }
      SupabaseStatusView(
        model: supabaseModel,
        searchText: supabaseSearchText,
        onRefresh: { Task { await supabaseModel.refresh() } }
      )
    case .cloudflare:
      if cloudflareModel.resourceCount > 0 {
        searchField(placeholder: "Filter Cloudflare resources...", text: $cloudflareSearchText)
      }
      CloudflareStatusView(
        model: cloudflareModel,
        searchText: cloudflareSearchText,
        onRefresh: { Task { await cloudflareModel.refresh(status: model.status) } }
      )
    case .railway:
      if !railwayModel.projects.isEmpty {
        searchField(placeholder: "Filter Railway resources...", text: $railwaySearchText)
      }
      RailwayStatusView(
        model: railwayModel,
        searchText: railwaySearchText,
        onRefresh: { Task { await railwayModel.refresh() } }
      )
    case .fly:
      if !flyModel.apps.isEmpty {
        searchField(placeholder: "Filter Fly resources...", text: $flySearchText)
      }
      FlyStatusView(
        model: flyModel,
        searchText: flySearchText,
        onRefresh: { Task { await flyModel.refresh() } }
      )
    case .netlify:
      if !netlifyModel.sites.isEmpty {
        searchField(placeholder: "Filter Netlify projects...", text: $netlifySearchText)
      }
      NetlifyStatusView(
        model: netlifyModel,
        searchText: netlifySearchText,
        onRefresh: { Task { await netlifyModel.refresh() } }
      )
    }
  }

  @ViewBuilder
  private var localContent: some View {
    if let status = model.status {
      searchField(
        placeholder: "Search projects, services, ports, branches…",
        text: $localSearchText
      )

      LocalOverview(
        status: status,
        lastUpdated: model.lastUpdated,
        hasRefreshError: model.errorMessage != nil,
        showLikelySystemListeners: model.showLikelySystemListeners
      )

      if let error = model.errorMessage, let lastUpdated = model.lastUpdated {
        LocalInlineDegradedState(message: error, lastUpdated: lastUpdated)
      }

      if let stopFailureMessage = model.stopFailureMessage {
        StopFailureMessage(message: stopFailureMessage)
      }

      let problems = visibleProblems(for: status)
      if !problems.isEmpty {
        LocalProblemsSection(problems: problems)
      }

      ForEach(visibleProjects(for: status)) { project in
        ProjectSection(
          project: project,
          preferNamedURLs: false,
          isExpanded: localSectionIsExpanded(
            searchText: localSearchText,
            isCollapsed: collapsedProjectIDs.contains(project.id)
          ),
          isStopping: model.isStopping,
          stoppingServiceID: model.stoppingServiceID,
          stoppingProjectID: model.stoppingProjectID,
          onStop: requestStopConfirmation,
          onStopAll: requestStopAllConfirmation
        ) {
          toggleProject(project.id)
        }
      }

      ForEach(visibleUnknownSections(for: status)) { section in
        UnknownSection(
          section: section,
          preferNamedURLs: false,
          isExpanded: isUnknownSectionExpanded(section.category),
          isStopping: model.isStopping,
          stoppingServiceID: model.stoppingServiceID,
          onStop: requestStopConfirmation
        ) {
          toggleUnknownSection(section.category)
        }
      }

      if isEmptyResult(for: status) {
        EmptyStateView(searchText: localSearchText)
      }
    } else if let error = model.errorMessage {
      VStack(alignment: .leading, spacing: 10) {
        Label("Status unavailable", systemImage: "exclamationmark.triangle")
          .font(.headline)
        Text(error)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(14)
    } else {
      VStack(spacing: 10) {
        ProgressView()
        Text("Loading local ports")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 34)
    }
  }

  private var footer: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        Button {
          refreshSelectedSource()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r")
        .disabled(!selectedSourceSupportsRefresh)

        if selectedSource == .local {
          Menu {
            Button {
              model.copyJSON()
            } label: {
              Label("Copy status JSON", systemImage: "doc.on.doc")
            }
            .disabled(model.rawJSON.isEmpty)

            Button {
              model.showLikelySystemListeners.toggle()
            } label: {
              Label(
                model.showLikelySystemListeners ? "Hide likely system listeners" : "Show likely system listeners",
                systemImage: "desktopcomputer"
              )
            }
          } label: {
            Label("Diagnostics", systemImage: "wrench.and.screwdriver")
          }
        }

#if !APP_STORE
        Button {
          openDonationPage()
        } label: {
          Label("Donate", systemImage: "heart.fill")
        }
        .help("Open Buy Me a Coffee")
#endif

        Spacer()

        Button("Quit") {
          NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
      }

      Divider()

      HStack(spacing: 3) {
        Text("Built by")

        Link(FooterAttribution.jesseName, destination: FooterAttribution.jesseURL)
        Text("/")
        Link(FooterAttribution.studioName, destination: FooterAttribution.studioURL)

        Spacer()

        FooterAttributionLink(
          title: "Jesse Peplinski’s website",
          systemImage: "globe",
          destination: FooterAttribution.jesseURL
        )
        FooterAttributionLink(
          title: "Jesse Peplinski on X",
          iconSVG: FooterAttribution.xIconSVG,
          destination: FooterAttribution.xURL
        )
        FooterAttributionLink(
          title: "Pep Tech on Twitch",
          iconSVG: FooterAttribution.twitchIconSVG,
          destination: FooterAttribution.twitchURL
        )
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .tint(.secondary)
    }
    .padding(12)
  }

  private var subtitle: String {
    switch activeSource {
    case .vercel:
      return vercelSubtitle
    case .convex:
      let count = convexModel.projects.count
      return "\(count) linked Convex \(plural(count, singular: "project", plural: "projects"))"
    case .github:
      return githubSubtitle
    case .supabase:
      return supabaseSubtitle
    case .cloudflare:
      return cloudflareSubtitle
    case .railway:
      return railwaySubtitle
    case .fly:
      return flySubtitle
    case .netlify:
      return netlifySubtitle
    case .local:
      break
    }

    guard let status = model.status else {
      return "CLI-backed local runtime view"
    }

    let groupedServiceCount = status.groups
      .flatMap(\.worktrees)
      .flatMap(\.services)
      .count
    let hiddenSystemCount = model.showLikelySystemListeners ? 0 : status.unknown.filter { $0.unknownServiceCategory == .likelySystem }.count
    let shownServiceCount = groupedServiceCount + status.unknown.count - hiddenSystemCount
    let projectCount = status.groups.filter { !$0.worktrees.flatMap(\.services).isEmpty }.count
    let projectLabel = plural(projectCount, singular: "project", plural: "projects")
    let serviceLabel = plural(shownServiceCount, singular: "service", plural: "services")
    let baseSummary = "\(projectCount) \(projectLabel), \(shownServiceCount) \(serviceLabel)"
    let hiddenSummary = hiddenSystemCount > 0 ? ", \(hiddenSystemCount) system hidden" : ""
    return "\(baseSummary)\(hiddenSummary)"
  }

  private var vercelSubtitle: String {
    switch vercelModel.connectionState {
    case .connected:
      let count = vercelModel.projects.count
      let team = vercelModel.scope?.displayName ?? "active CLI team"
      return "\(count) \(plural(count, singular: "project", plural: "projects")) in \(team)"
    case .connecting:
      return "Connecting through Vercel CLI"
    case .missingCLI:
      return "Vercel CLI required"
    case .outdatedCLI:
      return "Vercel CLI update required"
    case .unauthenticated:
      return "Connect your Vercel account"
    case .checking:
      return "Checking Vercel CLI"
    case .failed:
      return "Vercel status unavailable"
    }
  }

  private var githubSubtitle: String {
    switch githubModel.connectionState {
    case .missingCLI:
      return "GitHub CLI required"
    case .unauthenticated:
      return "GitHub authentication required"
    case .rateLimited:
      return "GitHub API rate limited"
    case .failed:
      return "GitHub Actions unavailable"
    case .checking, .connected:
      let count = githubModel.repositories.count
      return "\(count) active GitHub \(plural(count, singular: "repository", plural: "repositories"))"
    }
  }

  private var supabaseSubtitle: String {
    switch supabaseModel.connectionState {
    case .missingCLI:
      return "Supabase CLI required"
    case .unsupportedCLI:
      return "Supabase CLI update required"
    case .authenticationRequired:
      return "Supabase authentication required"
    case .rateLimited:
      return "Supabase API rate limited"
    case .failed:
      return "Supabase projects unavailable"
    case .checking, .connected:
      let count = supabaseModel.projects.count
      return "\(count) accessible Supabase \(plural(count, singular: "project", plural: "projects"))"
    }
  }

  private var cloudflareSubtitle: String {
    switch cloudflareModel.connectionState {
    case .missingCLI:
      return "Wrangler required"
    case .unsupportedCLI:
      return "Wrangler update required"
    case .authenticationRequired:
      return "Cloudflare authentication required"
    case .rateLimited:
      return "Cloudflare API rate limited"
    case .failed:
      return "Cloudflare resources unavailable"
    case .checking, .connected:
      let count = cloudflareModel.resourceCount
      return "\(count) Cloudflare \(plural(count, singular: "resource", plural: "resources"))"
    }
  }

  private var railwaySubtitle: String {
    switch railwayModel.connectionState {
    case .missingCLI:
      return "Railway CLI required"
    case .unsupportedCLI:
      return "Railway CLI update required"
    case .authenticationRequired:
      return "Railway authentication required"
    case .rateLimited:
      return "Railway API rate limited"
    case .failed:
      return "Railway projects unavailable"
    case .checking, .connected:
      let projectCount = railwayModel.projects.count
      let serviceCount = railwayModel.serviceCount
      return "\(projectCount) Railway \(plural(projectCount, singular: "project", plural: "projects")), \(serviceCount) \(plural(serviceCount, singular: "service", plural: "services"))"
    }
  }

  private var flySubtitle: String {
    switch flyModel.connectionState {
    case .missingCLI:
      return "flyctl required"
    case .unsupportedCLI:
      return "flyctl update required"
    case .authenticationRequired:
      return "Fly authentication required"
    case .rateLimited:
      return "Fly API rate limited"
    case .failed:
      return "Fly apps unavailable"
    case .checking, .connected:
      let appCount = flyModel.apps.count
      let machineCount = flyModel.machineCount
      return "\(appCount) Fly \(plural(appCount, singular: "app", plural: "apps")), \(machineCount) \(plural(machineCount, singular: "Machine", plural: "Machines"))"
    }
  }

  private var netlifySubtitle: String {
    switch netlifyModel.connectionState {
    case .missingCLI:
      return "Netlify CLI required"
    case .unsupportedCLI:
      return "Netlify CLI update required"
    case .authenticationRequired:
      return "Netlify authentication required"
    case .rateLimited:
      return "Netlify API rate limited"
    case .failed:
      return "Netlify projects unavailable"
    case .checking, .connected:
      let count = netlifyModel.sites.count
      return "\(count) accessible Netlify \(plural(count, singular: "project", plural: "projects"))"
    }
  }

  private var showsHeaderProgress: Bool {
    switch activeSource {
    case .vercel:
      return vercelModel.showsHeaderProgress
    case .convex:
      return convexModel.showsHeaderProgress
    case .github:
      return githubModel.showsHeaderProgress
    case .supabase:
      return supabaseModel.showsHeaderProgress
    case .cloudflare:
      return cloudflareModel.showsHeaderProgress
    case .railway:
      return railwayModel.showsHeaderProgress
    case .fly:
      return flyModel.showsHeaderProgress
    case .netlify:
      return netlifyModel.showsHeaderProgress
    case .local:
      return model.showsHeaderProgress
    }
  }

  private var selectedSourceSupportsRefresh: Bool {
    true
  }

  private var sourceTabs: some View {
    ProviderTabRail(
      providers: providerConfiguration.visibleProviders,
      selectedProvider: selectedSource,
      onSelect: selectSource
    )
  }

  private func searchField(placeholder: String, text: Binding<String>) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
      TextField(placeholder, text: text)
        .textFieldStyle(.plain)
      if !text.wrappedValue.isEmpty {
        Button {
          text.wrappedValue = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
        .help("Clear filter")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(.quaternary.opacity(0.85))
    )
  }

  private var commandPaletteOverlay: some View {
    let results = commandPaletteResults

    return ZStack {
      Color.black.opacity(0.22)
        .ignoresSafeArea()
        .onTapGesture {
          dismissCommandPalette()
        }

      VStack(spacing: 0) {
        HStack(spacing: 9) {
          Image(systemName: "command")
            .foregroundStyle(.secondary)
          TextField("Run action...", text: $commandPaletteQuery)
            .textFieldStyle(.plain)
            .focused($isCommandPaletteSearchFocused)
            .onSubmit {
              runSelectedCommandPaletteAction()
            }
          if !commandPaletteQuery.isEmpty {
            Button {
              commandPaletteQuery = ""
              selectedCommandPaletteIndex = 0
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear action search")
            .help("Clear action search")
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

        Divider()

        if results.isEmpty {
          CommandPaletteEmptyState()
            .frame(maxWidth: .infinity)
        } else {
          ScrollView {
            LazyVStack(spacing: 4) {
              ForEach(Array(results.enumerated()), id: \.element.id) { index, action in
                CommandPaletteActionRow(
                  action: action,
                  isSelected: index == selectedCommandPaletteIndex
                ) {
                  runCommandPaletteAction(action)
                }
              }
            }
            .padding(8)
          }
          .frame(maxHeight: 390)
        }
      }
      .frame(width: 420)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(.white.opacity(0.16), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.30), radius: 24, y: 12)
      .padding(.top, 58)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(
        CommandPaletteKeyboardMonitor(
          isActive: isCommandPalettePresented,
          onMoveSelection: moveCommandPaletteSelection,
          onSubmit: runSelectedCommandPaletteAction,
          onCancel: dismissCommandPalette
        )
        .frame(width: 0, height: 0)
      )
      .onAppear {
        selectedCommandPaletteIndex = 0
        isCommandPaletteSearchFocused = true
      }
      .onChange(of: commandPaletteQuery) {
        selectedCommandPaletteIndex = 0
      }
    }
  }

  private var commandPaletteActions: [PortdeckCommandPaletteAction] {
    guard let status = model.status else {
      return PortdeckCommandPalette.dashboardSourceActions(
        dashboardSources: providerConfiguration.visibleProviders
      )
    }

    return PortdeckCommandPalette.collect(
      status: status,
      preferNamedURLs: false,
      showLikelySystemListeners: model.showLikelySystemListeners,
      dashboardSources: providerConfiguration.visibleProviders
    )
  }

  private var commandPaletteResults: [PortdeckCommandPaletteAction] {
    PortdeckCommandPalette.matching(commandPaletteQuery, in: commandPaletteActions)
  }

  private var normalizedSearchText: String {
    localSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func visibleProblems(for status: PortdeckStatus) -> [LocalProblem] {
    LocalStatusPresentation.problems(in: status, matching: localSearchText)
  }

  private func visibleProjects(for status: PortdeckStatus) -> [VisibleProjectGroup] {
    return status.groups.compactMap { group in
      let worktrees = group.worktrees.compactMap { worktree -> VisibleWorktreeGroup? in
        let context = searchContext(group: group, worktree: worktree)
        let services = worktree.services.filter { service in
          service.matchesSearch(localSearchText, preferNamedURLs: false, context: context)
        }

        guard !services.isEmpty else {
          return nil
        }

        return VisibleWorktreeGroup(worktree: worktree, services: services)
      }

      guard !worktrees.isEmpty else { return nil }

      return VisibleProjectGroup(group: group, worktrees: worktrees)
    }
  }

  private func visibleUnknownSections(for status: PortdeckStatus) -> [PortdeckUnknownServiceSection] {
    status.unknown.unknownServiceSections(
      showLikelySystemListeners: model.showLikelySystemListeners,
      searchText: localSearchText,
      preferNamedURLs: false
    )
  }

  private func isEmptyResult(for status: PortdeckStatus) -> Bool {
    return visibleProjects(for: status).isEmpty
      && visibleUnknownSections(for: status).isEmpty
      && visibleProblems(for: status).isEmpty
  }

  private func toggleProject(_ id: String) {
    if collapsedProjectIDs.contains(id) {
      collapsedProjectIDs.remove(id)
    } else {
      collapsedProjectIDs.insert(id)
    }
  }

  private func isUnknownSectionExpanded(_ category: PortdeckUnknownServiceCategory) -> Bool {
    !normalizedSearchText.isEmpty || expandedUnknownSectionIDs.contains(category.id)
  }

  private func toggleUnknownSection(_ category: PortdeckUnknownServiceCategory) {
    if expandedUnknownSectionIDs.contains(category.id) {
      expandedUnknownSectionIDs.remove(category.id)
    } else {
      expandedUnknownSectionIDs.insert(category.id)
    }
  }

  private func presentCommandPalette() {
    isProviderCustomizationPresented = false
    commandPaletteQuery = ""
    selectedCommandPaletteIndex = 0
    isCommandPalettePresented = true
  }

  private func dismissCommandPalette() {
    isCommandPalettePresented = false
    commandPaletteQuery = ""
    selectedCommandPaletteIndex = 0
    isCommandPaletteSearchFocused = false
  }

  private func presentProviderCustomization() {
    dismissCommandPalette()
    isProviderCustomizationPresented = true
  }

  private func selectSource(_ source: PortdeckDashboardSource) {
    providerConfiguration.select(source)
    selectedDashboardTab = source.rawValue
  }

  private func restoreDashboardSelection() {
    if selectedDashboardTab == "projects" {
      selectedDashboardTab = PortdeckDashboardSource.local.rawValue
    }

    if let source = PortdeckDashboardSource(rawValue: selectedDashboardTab),
      providerConfiguration.isVisible(source)
    {
      providerConfiguration.select(source)
    } else {
      selectedDashboardTab = providerConfiguration.selectedProvider.rawValue
    }
  }

  private func dismissProviderCustomization() {
    isProviderCustomizationPresented = false
  }

  private func moveCommandPaletteSelection(_ delta: Int) {
    let count = commandPaletteResults.count
    guard count > 0 else {
      selectedCommandPaletteIndex = 0
      return
    }

    selectedCommandPaletteIndex = (selectedCommandPaletteIndex + delta + count) % count
  }

  private func runSelectedCommandPaletteAction() {
    let results = commandPaletteResults
    guard !results.isEmpty else {
      return
    }

    runCommandPaletteAction(results[min(selectedCommandPaletteIndex, results.count - 1)])
  }

  private func runCommandPaletteAction(_ action: PortdeckCommandPaletteAction) {
    switch action.kind {
    case .openService, .openFolder, .openRepository:
      guard let rawURL = action.openURLString, let url = URL(string: rawURL) else {
        return
      }
      dismissCommandPalette()
      NSWorkspace.shared.open(url)
    case .openInVSCode:
      guard let path = action.filePath else {
        return
      }
      dismissCommandPalette()
      openInVSCode(path)
    case .revealInFinder:
      guard let path = action.filePath else {
        return
      }
      dismissCommandPalette()
      revealInFinder(path)
    case .stopService:
      guard let service = action.service else {
        return
      }
      dismissCommandPalette()
      requestStopConfirmation(service)
    case .stopProject:
      guard let target = action.stopAllTarget else {
        return
      }
      dismissCommandPalette()
      requestStopAllConfirmation(target)
    case .refreshStatus:
      dismissCommandPalette()
      refreshSelectedSource()
    case .copyJSON:
      dismissCommandPalette()
      model.copyJSON()
    case .switchSource(let source):
      selectSource(source)
      dismissCommandPalette()
    case .toggleSystemListeners:
      model.showLikelySystemListeners.toggle()
      dismissCommandPalette()
    }
  }

  private func stopService(_ service: PortdeckService) {
    model.requestStopService(service)
  }

  private func refreshSelectedSource() {
    switch activeSource {
    case .vercel:
      Task { await vercelModel.refresh() }
    case .convex:
      Task { await convexModel.refresh(status: model.status) }
    case .local:
      Task { await model.refresh() }
    case .github:
      Task { await githubModel.refresh(status: model.status) }
    case .supabase:
      Task { await supabaseModel.refresh() }
    case .cloudflare:
      Task { await cloudflareModel.refresh(status: model.status) }
    case .railway:
      Task { await railwayModel.refresh() }
    case .fly:
      Task { await flyModel.refresh() }
    case .netlify:
      Task { await netlifyModel.refresh() }
    }
  }

  private func stopAll(_ target: ProjectStopAllTarget) {
    model.requestStopAll(target)
  }

  private func stop(_ action: PendingStopAction) {
    switch action {
    case .service(let service):
      stopService(service)
    case .project(let target):
      stopAll(target)
    }
  }

  private func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }

  private func openInVSCode(_ path: String) {
    openFolderInVSCode(path)
  }

#if !APP_STORE
  private func openDonationPage() {
    guard let url = URL(string: "https://buymeacoffee.com/jessepeplinski") else {
      return
    }

    NSWorkspace.shared.open(url)
  }
#endif

  private func requestStopConfirmation(_ service: PortdeckService) {
    pendingStopAction = .service(service)
  }

  private func requestStopAllConfirmation(_ target: ProjectStopAllTarget) {
    pendingStopAction = .project(target)
  }

  private func searchContext(group: ProjectGroup, worktree: WorktreeGroup) -> [String] {
    [
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
  }
}

private struct FooterAttributionLink: View {
  let title: String
  var systemImage: String?
  var iconSVG: String?
  let destination: URL

  var body: some View {
    Link(destination: destination) {
      Group {
        if let systemImage {
          Image(systemName: systemImage)
        } else if let iconSVG, let icon = svgImage(iconSVG) {
          Image(nsImage: icon)
            .resizable()
            .scaledToFit()
        }
      }
      .frame(width: 15, height: 15)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(title)
    .accessibilityLabel(title)
  }

  private func svgImage(_ source: String) -> NSImage? {
    guard let image = NSImage(data: Data(source.utf8)) else {
      return nil
    }
    image.isTemplate = true
    return image
  }
}

private struct ProviderTabRail: View {
  let providers: [PortdeckDashboardSource]
  let selectedProvider: PortdeckDashboardSource
  let onSelect: (PortdeckDashboardSource) -> Void

  @State private var scrollPosition: PortdeckDashboardSource?
  @StateObject private var scrollController = ProviderTabRailScrollController()

  var body: some View {
    ViewThatFits(in: .horizontal) {
      providerButtons
      overflowingProviderButtons
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var providerButtons: some View {
    HStack(spacing: 4) {
      ForEach(navigationProviders) { provider in
        providerButton(provider)
          .id(provider)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var navigationProviders: [PortdeckDashboardSource] {
    guard providers.contains(.local) else { return providers }
    return [.local] + providers.filter { $0 != .local }
  }

  private var overflowingProviderButtons: some View {
    HStack(spacing: 4) {
      navigationButton(
        systemImage: "chevron.left",
        accessibilityLabel: "Scroll providers left",
        help: "Scroll the provider tabs left; click and hold to continue",
        isEnabled: scrollController.canScrollBackward
      ) {
        scrollController.scrollPage(.backward)
      }

      ScrollView(.horizontal) {
        providerButtons
          .scrollTargetLayout()
          .background {
            ProviderTabRailScrollViewResolver { scrollView in
              scrollController.attach(scrollView)
            }
          }
      }
      .scrollIndicators(.hidden)
      .scrollPosition(id: $scrollPosition, anchor: .center)
      .frame(maxWidth: .infinity)
      .highPriorityGesture(
        DragGesture(minimumDistance: 6)
          .onChanged { value in
            scrollController.drag(horizontalTranslation: value.translation.width)
          }
          .onEnded { _ in
            scrollController.endDragging()
          }
      )

      navigationButton(
        systemImage: "chevron.right",
        accessibilityLabel: "Scroll providers right",
        help: "Scroll the provider tabs right; click and hold to continue",
        isEnabled: scrollController.canScrollForward
      ) {
        scrollController.scrollPage(.forward)
      }
    }
    .frame(maxWidth: .infinity)
    .onAppear {
      scrollPosition = selectedProvider
    }
    .onChange(of: selectedProvider) { _, provider in
      reveal(provider)
    }
    .onChange(of: providers) {
      reveal(providers.contains(selectedProvider) ? selectedProvider : providers.first)
    }
  }

  private func providerButton(_ provider: PortdeckDashboardSource) -> some View {
    Button {
      onSelect(provider)
    } label: {
      HStack(spacing: 5) {
        Image(systemName: provider.systemImage)
          .imageScale(.small)
        Text(provider.title)
          .font(.caption)
          .fontWeight(.semibold)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .contentShape(RoundedRectangle(cornerRadius: 8))
      .foregroundStyle(selectedProvider == provider ? provider.accentColor : .secondary)
      .background(
        selectedProvider == provider ? provider.accentColor.opacity(0.16) : Color.clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(provider.title)
    .help("\(provider.helpText)\nClick and drag to scroll providers")
  }

  private func navigationButton(
    systemImage: String,
    accessibilityLabel: String,
    help: String,
    isEnabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.caption.weight(.semibold))
        .frame(width: 22, height: 28)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain)
    .buttonRepeatBehavior(.enabled)
    .foregroundStyle(.secondary)
    .disabled(!isEnabled)
    .accessibilityLabel(accessibilityLabel)
    .help(help)
  }

  private func reveal(_ provider: PortdeckDashboardSource?) {
    guard let provider else { return }

    withAnimation(.easeInOut(duration: 0.18)) {
      scrollPosition = provider
    }
  }
}

enum ProviderTabRailScrollDirection {
  case backward
  case forward
}

private struct VisibleProjectGroup: Identifiable {
  let group: ProjectGroup
  let worktrees: [VisibleWorktreeGroup]

  var id: String { group.id }

  var serviceCount: Int {
    worktrees.reduce(0) { $0 + $1.services.count }
  }
}

private struct VisibleWorktreeGroup: Identifiable {
  let worktree: WorktreeGroup
  let services: [PortdeckService]

  var id: String { worktree.id }
}

private enum PendingStopAction {
  case service(PortdeckService)
  case project(ProjectStopAllTarget)

  var confirmationTitle: String {
    switch self {
    case .service(let service):
      return service.stopConfirmationTitle
    case .project(let target):
      return target.confirmationTitle
    }
  }

  var confirmButtonTitle: String {
    switch self {
    case .service:
      return "Stop service"
    case .project:
      return "Stop all"
    }
  }
}

private func sameFilePath(_ left: String, _ right: String) -> Bool {
  URL(fileURLWithPath: left).standardizedFileURL.path == URL(fileURLWithPath: right).standardizedFileURL.path
}

private func openFolderInVSCode(_ path: String) {
  let folderURL = URL(fileURLWithPath: path)
  guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
    NSWorkspace.shared.open(folderURL)
    return
  }

  NSWorkspace.shared.open(
    [folderURL],
    withApplicationAt: appURL,
    configuration: NSWorkspace.OpenConfiguration()
  )
}

private struct ProjectSection: View {
  let project: VisibleProjectGroup
  let preferNamedURLs: Bool
  let isExpanded: Bool
  let isStopping: Bool
  let stoppingServiceID: String?
  let stoppingProjectID: String?
  let onStop: (PortdeckService) -> Void
  let onStopAll: (ProjectStopAllTarget) -> Void
  let onToggle: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Button {
          onToggle()
        } label: {
          HStack(spacing: 9) {
            Image(systemName: projectIconName)
              .font(.title3)
              .foregroundStyle(.secondary)
              .frame(width: 22)
            Text(project.group.projectName)
              .font(.headline)
              .lineLimit(1)
              .layoutPriority(1)
            Text("\(projectSummary.serviceCount) \(plural(projectSummary.serviceCount, singular: "service", plural: "services"))")
              .font(.caption2)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 3)
              .background(.quaternary.opacity(0.65), in: Capsule())
            if let problemLabel = projectSummary.problemLabel {
              Text(problemLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.orange.opacity(0.11), in: Capsule())
            }
            Spacer(minLength: 0)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(isExpanded ? "Collapse \(project.group.projectName)" : "Expand \(project.group.projectName)")
        .accessibilityLabel(localProjectDisclosureAccessibilityLabel(
          projectName: project.group.projectName,
          isExpanded: isExpanded
        ))

        if isProjectStopping {
          ProgressView()
            .controlSize(.small)
            .frame(width: 28)
            .help("Stopping project services")
        } else {
          ProjectHeaderActionsMenu(
            project: project.group,
            stopAllTarget: stopAllTarget,
            isStopDisabled: isStopping,
            onStopAll: onStopAll
          )
        }

        Button {
          onToggle()
        } label: {
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse \(project.group.projectName)" : "Expand \(project.group.projectName)")
        .accessibilityLabel(isExpanded ? "Collapse \(project.group.projectName)" : "Expand \(project.group.projectName)")
      }
      .padding(12)

      if isExpanded {
        VStack(spacing: 4) {
          ForEach(project.worktrees) { worktree in
            WorktreeBlock(
              projectName: project.group.projectName,
              repoRoot: project.group.repoRoot,
              worktree: worktree,
              preferNamedURLs: preferNamedURLs,
              showsHeader: worktree.id == project.worktrees.first?.id,
              projectWorktreeCount: project.group.worktrees.count,
              isStopping: isStopping,
              stoppingProjectTarget: stoppingProjectTarget,
              stoppingServiceID: stoppingServiceID,
              onStop: onStop
            )
          }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
      }
    }
    .background(.background.opacity(0.70), in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(.quaternary)
    )
  }

  private var projectIconName: String {
    if project.group.projectName.contains(".") {
      return "globe"
    }
    return "rectangle.stack"
  }

  private var projectSummary: LocalProjectSummary {
    LocalStatusPresentation.projectSummary(project.group)
  }

  private var stopAllTarget: ProjectStopAllTarget? {
    project.group.stopAllTarget
  }

  private var isProjectStopping: Bool {
    stoppingProjectID == project.group.id
  }

  private var stoppingProjectTarget: ProjectStopAllTarget? {
    isProjectStopping ? stopAllTarget : nil
  }
}

private struct ProjectHeaderActionsMenu: View {
  let project: ProjectGroup
  let stopAllTarget: ProjectStopAllTarget?
  let isStopDisabled: Bool
  let onStopAll: (ProjectStopAllTarget) -> Void

  @State private var isHovered = false

  var body: some View {
    Menu {
      if let repoFolderURLString = project.repoFolderURLString {
        Button {
          openURLString(repoFolderURLString)
        } label: {
          Label("Open \(project.projectName) repo folder", systemImage: "folder")
        }
      }

      if let repoRoot = project.repoRoot {
        Button {
          openInVSCode(repoRoot)
        } label: {
          Label("Open \(project.projectName) repo in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
        }

        Button {
          revealInFinder(repoRoot)
        } label: {
          Label("Reveal \(project.projectName) repo in Finder", systemImage: "finder")
        }
      }

      if let repositoryURLString = project.repositoryOpenURLString {
        Button {
          openURLString(repositoryURLString)
        } label: {
          Label("Open \(project.projectName) repository", systemImage: "globe")
        }
      }

      if project.hasJumpActions, stopAllTarget != nil {
        Divider()
      }

      if let stopAllTarget {
        Button(role: .destructive) {
          onStopAll(stopAllTarget)
        } label: {
          Label(
            "Stop all services in \(project.projectName)...",
            systemImage: PortdeckStopControlPresentation.destructive.systemImage
          )
        }
        .disabled(isStopDisabled)
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 24)
        .contentShape(Rectangle())
        .background(.quaternary.opacity(isHovered ? 0.40 : 0), in: RoundedRectangle(cornerRadius: 7))
    }
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: 0.12), value: isHovered)
    .help("Open \(project.projectName) project actions")
    .accessibilityLabel(localProjectActionsAccessibilityLabel(projectName: project.projectName))
  }

  private func openURLString(_ rawURL: String) {
    guard let url = URL(string: rawURL) else {
      return
    }

    NSWorkspace.shared.open(url)
  }

  private func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }

  private func openInVSCode(_ path: String) {
    openFolderInVSCode(path)
  }
}

private struct WorktreeBlock: View {
  let projectName: String
  let repoRoot: String?
  let worktree: VisibleWorktreeGroup
  let preferNamedURLs: Bool
  let showsHeader: Bool
  let projectWorktreeCount: Int
  let isStopping: Bool
  let stoppingProjectTarget: ProjectStopAllTarget?
  let stoppingServiceID: String?
  let onStop: (PortdeckService) -> Void

  var body: some View {
    VStack(spacing: 0) {
      if !metadataItems.isEmpty || shouldShowWorktreeActions {
        HStack(spacing: 6) {
          ForEach(metadataItems, id: \.text) { item in
            MetadataChip(text: item.text, systemImage: item.systemImage)
          }
          Spacer()
          if shouldShowWorktreeActions {
            WorktreeActionsMenu(worktree: worktree.worktree)
          }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
      }

      if showsHeader && !worktree.services.isEmpty {
        ServiceTableHeader()
      }

      ForEach(worktree.services) { service in
        Divider()
          .padding(.leading, 10)
        ServiceRow(
          service: service,
          preferNamedURLs: preferNamedURLs,
          isStoppingGlobally: isStopping,
          stoppingProjectTarget: stoppingProjectTarget,
          stoppingServiceID: stoppingServiceID,
          onStop: onStop
        )
      }
    }
  }

  private var metadataItems: [LocalMetadataItem] {
    LocalStatusPresentation.worktreeMetadata(
      worktree.worktree,
      projectName: projectName,
      repoRoot: repoRoot,
      projectWorktreeCount: projectWorktreeCount
    )
  }

  private var shouldShowWorktreeActions: Bool {
    worktree.worktree.hasJumpActions && !isSinglePrimaryWorktree
  }

  private var isSinglePrimaryWorktree: Bool {
    guard projectWorktreeCount == 1,
      let repoRoot,
      let worktreePath = worktree.worktree.path
    else {
      return false
    }

    return sameFilePath(repoRoot, worktreePath)
  }
}

private struct WorktreeActionsMenu: View {
  let worktree: WorktreeGroup

  @State private var isHovered = false

  var body: some View {
    Menu {
      if let folderURLString = worktree.folderURLString {
        Button {
          openURLString(folderURLString)
        } label: {
          Label("Open \(worktree.name) worktree folder", systemImage: "folder.badge.gearshape")
        }
      }

      if let path = worktree.path {
        Button {
          openInVSCode(path)
        } label: {
          Label("Open \(worktree.name) in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
        }

        Button {
          revealInFinder(path)
        } label: {
          Label("Reveal \(worktree.name) in Finder", systemImage: "finder")
        }
      }

      if let repositoryURLString = worktree.repositoryOpenURLString {
        Button {
          openURLString(repositoryURLString)
        } label: {
          Label("Open \(worktree.name) repository", systemImage: "globe")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 18)
        .contentShape(Rectangle())
        .background(.quaternary.opacity(isHovered ? 0.40 : 0), in: RoundedRectangle(cornerRadius: 6))
    }
    .menuIndicator(.hidden)
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: 0.12), value: isHovered)
    .help("Open \(worktree.name) worktree actions")
    .accessibilityLabel(localWorktreeActionsAccessibilityLabel(worktreeName: worktree.name))
  }

  private func openURLString(_ rawURL: String) {
    guard let url = URL(string: rawURL) else {
      return
    }

    NSWorkspace.shared.open(url)
  }

  private func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }

  private func openInVSCode(_ path: String) {
    openFolderInVSCode(path)
  }
}

private struct ServiceTableHeader: View {
  var body: some View {
    HStack(spacing: 8) {
      Text("SERVICE")
        .frame(maxWidth: .infinity, alignment: .leading)
      Text("CPU")
        .frame(width: 42, alignment: .trailing)
      Text("MEM")
        .frame(width: 54, alignment: .trailing)
      Text("PORT")
        .frame(width: 48, alignment: .trailing)
      Color.clear
        .frame(width: 28)
      Color.clear
        .frame(width: 28)
    }
    .font(.caption2)
    .fontWeight(.semibold)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
  }
}

private struct ServiceRow: View {
  let service: PortdeckService
  let preferNamedURLs: Bool
  let isStoppingGlobally: Bool
  let stoppingProjectTarget: ProjectStopAllTarget?
  let stoppingServiceID: String?
  let onStop: (PortdeckService) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        HStack(spacing: 7) {
          Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
          Text(service.name)
            .font(.callout)
            .fontWeight(.semibold)
            .lineLimit(1)
            .truncationMode(.tail)
          if let visibleStateLabel {
            Text(visibleStateLabel)
              .font(.caption2.weight(presentation.needsAttention ? .semibold : .regular))
              .foregroundStyle(stateColor)
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(localServiceRowAccessibilityLabel(
          serviceName: service.name,
          source: sourceLabel,
          state: accessibilityStateLabel
        ))

        ActivityMetricText(value: service.activityCPUText, width: 42)
        ActivityMetricText(value: service.activityMemoryText, width: 54)

        if let targetLabel {
          Text(targetLabel)
            .font(.caption.monospacedDigit())
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: 48, alignment: .trailing)
        } else {
          Color.clear
            .frame(width: 48)
        }

        if let openURL {
          Button {
            NSWorkspace.shared.open(openURL)
          } label: {
            Image(systemName: openControlPresentation.systemImage)
              .font(.callout)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.blue)
          .frame(width: 28)
          .accessibilityLabel(localOpenServiceAccessibilityLabel(
            serviceName: service.name,
            destination: openDestinationLabel
          ))
          .help(localOpenServiceAccessibilityLabel(
            serviceName: service.name,
            destination: openDestinationLabel
          ))
        } else {
          Color.clear
            .frame(width: 28)
        }

        if isStopping {
          ProgressView()
            .controlSize(.small)
            .frame(width: 28)
            .help("Stopping service")
        } else if service.canStop {
          Button {
            onStop(service)
          } label: {
            Image(systemName: stopControlPresentation.systemImage)
              .font(.callout)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.red)
          .frame(width: 28)
          .accessibilityLabel(localStopServiceAccessibilityLabel(serviceName: service.name))
          .help(localStopServiceAccessibilityLabel(serviceName: service.name))
          .disabled(isStopDisabled)
        } else {
          Color.clear
            .frame(width: 28)
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 42)

      if let detail = presentation.detail {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: presentation.tone == .critical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(stateColor)
            .padding(.top, 1)
          Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 7)
        .accessibilityElement(children: .combine)
      }

      ForEach(attachedExposures) { exposure in
        HStack(spacing: 6) {
          Image(systemName: "globe")
            .imageScale(.small)
            .foregroundStyle(.blue)
          Text(exposure.serviceDisplayText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 7)
        .help(exposure.serviceDisplayText)
      }
    }
    .overlay(alignment: .leading) {
      if presentation.needsAttention {
        Rectangle()
          .fill(stateColor)
          .frame(width: 2)
          .padding(.vertical, 5)
      }
    }
  }

  private var isStopping: Bool {
    stoppingServiceID == service.id || stoppingProjectTarget?.containsService(service) == true
  }

  private var isStopDisabled: Bool {
    isStoppingGlobally || stoppingServiceID != nil
  }

  private var stopControlPresentation: PortdeckStopControlPresentation {
    .destructive
  }

  private var openControlPresentation: PortdeckOpenControlPresentation {
    .primary
  }

  private var openURL: URL? {
    guard let rawURL = service.openURLString(preferNamedURLs: preferNamedURLs),
      let url = URL(string: rawURL)
    else {
      return nil
    }

    return url
  }

  private var targetLabel: String? {
    if let endpoint = service.primaryEndpointLabel(preferNamedURLs: preferNamedURLs) {
      if let port = service.port, endpoint.hasSuffix(":\(port)") {
        return ":\(port)"
      }
      return endpoint
    }
    if let port = service.port {
      return ":\(port)"
    }
    return nil
  }

  private var presentation: LocalServicePresentation {
    LocalStatusPresentation.service(service)
  }

  private var statusColor: Color {
    switch presentation.tone {
    case .critical:
      return .red
    case .warning:
      return .orange
    case .positive:
      return .green
    case .neutral:
      return service.source == "docker" ? .blue : .green
    }
  }

  private var stateColor: Color {
    switch presentation.tone {
    case .critical:
      return .red
    case .warning:
      return .orange
    case .positive, .neutral:
      return .secondary
    }
  }

  private var visibleStateLabel: String? {
    LocalStatusPresentation.visibleServiceStateLabel(presentation, isStopping: isStopping)
  }

  private var accessibilityStateLabel: String {
    isStopping ? "stopping" : presentation.label.lowercased()
  }

  private var sourceLabel: String {
    switch service.source.lowercased() {
    case "docker":
      return "Docker"
    case "process":
      return "Process"
    default:
      return service.source.capitalized
    }
  }

  private var openDestinationLabel: String {
    service.primaryEndpointLabel(preferNamedURLs: preferNamedURLs)
      ?? openURL?.absoluteString
      ?? "its local endpoint"
  }

  private var attachedExposures: [PortdeckExposure] {
    (service.exposures ?? []).filter { $0.status == "attached" }
  }
}

private struct ActivityMetricText: View {
  let value: String?
  let width: CGFloat

  var body: some View {
    Group {
      if let value {
        Text(value)
          .font(.caption.monospacedDigit())
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
      } else {
        Color.clear
      }
    }
    .frame(width: width, alignment: .trailing)
  }
}

private struct LocalOverview: View {
  let status: PortdeckStatus
  let lastUpdated: Date?
  let hasRefreshError: Bool
  let showLikelySystemListeners: Bool

  var body: some View {
    let overview = LocalStatusPresentation.overview(
      for: status,
      showLikelySystemListeners: showLikelySystemListeners
    )

    VStack(spacing: 8) {
      HStack(spacing: 8) {
        Label("This Mac", systemImage: "laptopcomputer")
          .font(.callout.weight(.semibold))
        Spacer(minLength: 4)
        LocalOverviewMetric(value: overview.projectCount, label: "projects")
        LocalOverviewMetric(value: overview.serviceCount, label: "services")
        LocalOverviewMetric(
          value: overview.problemCount,
          label: "problems",
          tint: overview.problemCount > 0 ? .orange : .secondary
        )
      }

      HStack(spacing: 6) {
        Circle()
          .fill(hasRefreshError ? Color.orange : Color.green)
          .frame(width: 6, height: 6)
        Text("Live every \(StatusModel.refreshIntervalSeconds)s")
          .font(.caption)
          .foregroundStyle(.secondary)
        if overview.hiddenSystemServiceCount > 0 {
          Text("·")
            .foregroundStyle(.tertiary)
          Text("\(overview.hiddenSystemServiceCount) system hidden")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Spacer()
        if let lastUpdated {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(localLastCheckedLabel(
              ageSeconds: localPollingAgeSeconds(lastUpdated: lastUpdated, relativeTo: context.date)
            ))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
          }
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(.quaternary.opacity(0.85))
    )
    .accessibilityElement(children: .combine)
  }
}

private struct LocalOverviewMetric: View {
  let value: Int
  let label: String
  var tint: Color = .secondary

  var body: some View {
    HStack(spacing: 3) {
      Text("\(value)")
        .font(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(tint)
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

private struct LocalInlineDegradedState: View {
  let message: String
  let lastUpdated: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let age = localPollingAgeSeconds(lastUpdated: lastUpdated, relativeTo: context.date)
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        VStack(alignment: .leading, spacing: 2) {
          Text("Showing the last successful Local snapshot from \(age)s ago")
            .font(.caption.weight(.semibold))
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .textSelection(.enabled)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(9)
      .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
      .overlay(alignment: .leading) {
        RoundedRectangle(cornerRadius: 2)
          .fill(.orange)
          .frame(width: 3)
          .padding(.vertical, 7)
      }
      .accessibilityElement(children: .combine)
    }
  }
}

private struct LocalProblemsSection: View {
  let problems: [LocalProblem]

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
        Text("Needs attention")
          .font(.headline)
        Spacer()
        CountBadge(count: problems.count, tint: .orange)
      }
      .padding(11)

      ForEach(Array(problems.enumerated()), id: \.element.id) { index, problem in
        if index > 0 {
          Divider()
            .padding(.leading, 11)
        }
        LocalProblemRow(problem: problem)
      }
    }
    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(.quaternary.opacity(0.85))
    )
  }
}

private struct LocalProblemRow: View {
  let problem: LocalProblem

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: problem.tone == .critical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
        .imageScale(.small)
        .foregroundStyle(tint)
        .frame(width: 16)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(problem.title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
          Text(problem.stateLabel.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.11), in: Capsule())
        }
        Text(problem.message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        ForEach(problem.details, id: \.self) { detail in
          Text(detail)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
  }

  private var tint: Color {
    problem.tone == .critical ? .red : .orange
  }
}

private struct UnknownSection: View {
  let section: PortdeckUnknownServiceSection
  let preferNamedURLs: Bool
  let isExpanded: Bool
  let isStopping: Bool
  let stoppingServiceID: String?
  let onStop: (PortdeckService) -> Void
  let onToggle: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      Button {
        onToggle()
      } label: {
        HStack(spacing: 9) {
          Image(systemName: section.category.systemImage)
            .font(.title3)
            .foregroundStyle(categoryTint)
            .frame(width: 22)
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(section.category.title)
                .font(.headline)
              Text(categoryBadgeLabel)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(categoryTint)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(categoryTint.opacity(0.10), in: Capsule())
            }
            Text(section.category.detail)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer()
          CountBadge(count: section.services.count, tint: categoryTint)
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isExpanded ? "Collapse \(section.category.title)" : "Expand \(section.category.title)")
      .accessibilityLabel(
        "\(isExpanded ? "Collapse" : "Expand") \(section.category.title), \(section.services.count) services"
      )

      if isExpanded {
        VStack(spacing: 0) {
          ServiceTableHeader()
          ForEach(section.services) { service in
            Divider()
              .padding(.leading, 10)
            ServiceRow(
              service: service,
              preferNamedURLs: preferNamedURLs,
              isStoppingGlobally: isStopping,
              stoppingProjectTarget: nil,
              stoppingServiceID: stoppingServiceID,
              onStop: onStop
            )
          }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
      }
    }
    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(.quaternary.opacity(0.85))
    )
  }

  private var categoryBadgeLabel: String {
    switch section.category {
    case .unattached:
      return "UNATTACHED"
    case .needsAttribution:
      return "CLASSIFY"
    case .likelySystem:
      return "SYSTEM"
    }
  }

  private var categoryTint: Color {
    switch section.category {
    case .unattached:
      return .blue
    case .needsAttribution:
      return .orange
    case .likelySystem:
      return .secondary
    }
  }
}

private struct EmptyStateView: View {
  let searchText: String

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: "line.3.horizontal.decrease.circle")
        .font(.title3)
        .foregroundStyle(.secondary)
      Text(emptyTitle)
        .font(.callout)
        .fontWeight(.semibold)
      Text(emptyDetail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
  }

  private var emptyTitle: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "No local services"
      : "No matching Local results"
  }

  private var emptyDetail: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Start a local server and refresh PortDeck."
      : "Try a project, service, port, branch, or status."
  }
}

private struct CommandPaletteActionRow: View {
  let action: PortdeckCommandPaletteAction
  let isSelected: Bool
  let onRun: () -> Void

  var body: some View {
    Button {
      onRun()
    } label: {
      HStack(spacing: 10) {
        Image(systemName: action.systemImage)
          .font(.callout)
          .foregroundStyle(action.role.tintColor)
          .frame(width: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text(action.title)
            .font(.callout)
            .fontWeight(.semibold)
            .lineLimit(1)
          if let subtitle = action.subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        Spacer()
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .contentShape(RoundedRectangle(cornerRadius: 8))
      .background(isSelected ? action.role.tintColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(isSelected ? action.role.tintColor.opacity(0.28) : Color.clear)
      }
    }
    .buttonStyle(.plain)
  }
}

private struct CommandPaletteEmptyState: View {
  var body: some View {
    VStack(spacing: 5) {
      Text("No matching actions")
        .font(.callout)
        .fontWeight(.semibold)
      Text("Try a service, port, docker, or json.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 28)
  }
}

private struct CommandPaletteKeyboardMonitor: NSViewRepresentable {
  let isActive: Bool
  let onMoveSelection: (Int) -> Void
  let onSubmit: () -> Void
  let onCancel: () -> Void

  func makeNSView(context: Context) -> NSView {
    NSView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.onMoveSelection = onMoveSelection
    context.coordinator.onSubmit = onSubmit
    context.coordinator.onCancel = onCancel

    if isActive {
      context.coordinator.installMonitor()
    } else {
      context.coordinator.removeMonitor()
    }
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.removeMonitor()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onMoveSelection: onMoveSelection,
      onSubmit: onSubmit,
      onCancel: onCancel
    )
  }

  final class Coordinator {
    var onMoveSelection: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void
    private var monitor: Any?

    init(
      onMoveSelection: @escaping (Int) -> Void,
      onSubmit: @escaping () -> Void,
      onCancel: @escaping () -> Void
    ) {
      self.onMoveSelection = onMoveSelection
      self.onSubmit = onSubmit
      self.onCancel = onCancel
    }

    func installMonitor() {
      guard monitor == nil else {
        return
      }

      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else {
          return event
        }

        switch event.keyCode {
        case 53:
          onCancel()
          return nil
        case 125:
          onMoveSelection(1)
          return nil
        case 126:
          onMoveSelection(-1)
          return nil
        case 36, 76:
          onSubmit()
          return nil
        default:
          return event
        }
      }
    }

    func removeMonitor() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
      }
      monitor = nil
    }
  }
}

private struct ProviderCustomizationOverlay: View {
  @ObservedObject var model: ProviderConfigurationModel
  let onDismiss: () -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.24)
        .ignoresSafeArea()
        .onTapGesture(perform: onDismiss)

      VStack(spacing: 0) {
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Customize providers")
              .font(.headline)
              .fontWeight(.semibold)
            Text("Local stays first; providers can be reordered.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
              .font(.title3)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .keyboardShortcut(.cancelAction)
          .accessibilityLabel("Close provider customization")
          .help("Close provider customization")
        }
        .padding(14)

        Divider()

        VStack(spacing: 4) {
          ForEach(model.orderedProviders) { provider in
            providerRow(provider)
          }
        }
        .padding(8)
      }
      .frame(width: 390)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(.white.opacity(0.16), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.30), radius: 24, y: 12)
      .padding()
    }
  }

  private func providerRow(_ provider: PortdeckDashboardSource) -> some View {
    HStack(spacing: 10) {
      Toggle(
        isOn: Binding(
          get: { model.isVisible(provider) },
          set: { model.setVisible($0, for: provider) }
        )
      ) {
        HStack(spacing: 8) {
          Image(systemName: provider.systemImage)
            .foregroundStyle(provider.accentColor)
            .frame(width: 18)
          Text(provider.title)
            .font(.callout)
            .fontWeight(.medium)
        }
      }
      .toggleStyle(.switch)
      .controlSize(.small)
      .disabled(model.isVisible(provider) && !model.canHide(provider))
      .accessibilityLabel("Show \(provider.title) provider")
      .help(visibilityHelp(for: provider))

      Spacer(minLength: 8)

      Button {
        model.moveUp(provider)
      } label: {
        Image(systemName: "chevron.up")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.borderless)
      .disabled(provider == .local || !model.canMoveUp(provider))
      .accessibilityLabel("Move \(provider.title) provider up")
      .help("Move \(provider.title) earlier")

      Button {
        model.moveDown(provider)
      } label: {
        Image(systemName: "chevron.down")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.borderless)
      .disabled(provider == .local || !model.canMoveDown(provider))
      .accessibilityLabel("Move \(provider.title) provider down")
      .help("Move \(provider.title) later")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .background(.quaternary.opacity(0.30), in: RoundedRectangle(cornerRadius: 8))
  }

  private func visibilityHelp(for provider: PortdeckDashboardSource) -> String {
    if model.isVisible(provider) && !model.canHide(provider) {
      return "At least one provider must remain visible"
    }
    return model.isVisible(provider)
      ? "Hide the \(provider.title) provider tab"
      : "Show the \(provider.title) provider tab"
  }
}

private struct StopConfirmationOverlay: View {
  let title: String
  let confirmButtonTitle: String
  let isStopping: Bool
  let onCancel: () -> Void
  let onConfirm: () -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.24)
        .ignoresSafeArea()
        .onTapGesture {
          if !isStopping {
            onCancel()
          }
        }

      VStack(spacing: 14) {
        Text(title)
          .font(.headline)
          .fontWeight(.semibold)
          .multilineTextAlignment(.center)
          .lineLimit(2)

        HStack(spacing: 10) {
          Button("Cancel") {
            onCancel()
          }
          .keyboardShortcut(.cancelAction)
          .disabled(isStopping)
          .frame(maxWidth: .infinity)

          Button(confirmButtonTitle, role: .destructive) {
            onConfirm()
          }
          .keyboardShortcut(.defaultAction)
          .disabled(isStopping)
          .tint(.red)
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
      }
      .padding(16)
      .frame(width: 280)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(.white.opacity(0.16), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
      .padding()
    }
  }
}

private struct StopFailureMessage: View {
  let message: String

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "xmark.circle")
        .imageScale(.small)
      Text(message)
        .font(.caption)
        .lineLimit(2)
      Spacer()
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
  }
}

private extension PortdeckCommandPaletteRole {
  var tintColor: Color {
    switch self {
    case .open:
      return .blue
    case .destructive:
      return .red
    case .utility:
      return .secondary
    }
  }
}

private struct CountBadge: View {
  let count: Int
  var tint: Color = .secondary

  var body: some View {
    Text("\(count)")
      .font(.caption.monospacedDigit())
      .fontWeight(.semibold)
      .foregroundStyle(.primary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(tint.opacity(0.20), in: Capsule())
  }
}

private struct MetadataChip: View {
  let text: String
  let systemImage: String

  var body: some View {
    Label(text, systemImage: systemImage)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.middle)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(.quaternary.opacity(0.75), in: Capsule())
  }
}

private func plural(_ count: Int, singular: String, plural: String) -> String {
  count == 1 ? singular : plural
}

private extension PortdeckDashboardSource {
  var title: String {
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

  var systemImage: String {
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

  var accentColor: Color {
    switch self {
    case .local:
      return .blue
    case .vercel:
      return .primary
    case .convex:
      return .orange
    case .github:
      return .purple
    case .supabase:
      return .green
    case .cloudflare:
      return .orange
    case .railway:
      return .purple
    case .fly:
      return .indigo
    case .netlify:
      return .mint
    }
  }

  var helpText: String {
    switch self {
    case .local:
      return "Show running services on this Mac"
    case .vercel:
      return "Show Vercel production deployments"
    case .convex:
      return "Show Convex production health"
    case .github:
      return "Show default-branch GitHub Actions health"
    case .supabase:
      return "Show account-wide Supabase project status"
    case .cloudflare:
      return "Show Cloudflare Workers and Pages deployment status"
    case .railway:
      return "Show Railway production service and deployment status"
    case .fly:
      return "Show Fly app, Machine, check, and release status"
    case .netlify:
      return "Show Netlify production deployment status"
    }
  }
}
