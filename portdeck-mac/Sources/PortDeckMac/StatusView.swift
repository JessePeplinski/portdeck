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
  @Environment(\.openSettings) private var openSettings
  @ObservedObject var model: StatusModel
  @ObservedObject var vercelModel: VercelStatusModel
  @ObservedObject var convexModel: ConvexStatusModel
  @ObservedObject var githubModel: GitHubStatusModel
  @ObservedObject var supabaseModel: SupabaseStatusModel
  @ObservedObject var cloudflareModel: CloudflareStatusModel
  @ObservedObject var railwayModel: RailwayStatusModel
  @ObservedObject var flyModel: FlyStatusModel
  @ObservedObject var netlifyModel: NetlifyStatusModel
  @ObservedObject var hostingerModel: HostingerStatusModel
  @ObservedObject var providerConfiguration: ProviderConfigurationModel
  @ObservedObject var updateController: UpdateController
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
  @State private var hostingerSearchText = ""
  @State private var collapsedProjectIDs: Set<String> = []
  @State private var expandedUnknownSectionIDs: Set<String> = [
    PortdeckUnknownServiceCategory.unattached.id,
    PortdeckUnknownServiceCategory.needsAttribution.id
  ]
  @State private var pendingStopAction: PendingStopAction?
  @State private var isCommandPalettePresented = false
  @State private var isProviderCustomizationPresented = false
  @State private var isAboutPresented = false
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

      if isAboutPresented {
        AboutPortDeckOverlay(
          version: updateController.currentVersion,
          onDismiss: dismissAbout
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
        await vercelModel.refresh()
      } else if selectedSource == .convex {
        await convexModel.refresh(status: model.status)
      } else if selectedSource == .github {
        await githubModel.refresh(status: model.status)
      } else if selectedSource == .supabase {
        await supabaseModel.refresh()
      } else if selectedSource == .cloudflare {
        await cloudflareModel.refresh(status: model.status)
      } else if selectedSource == .railway {
        await railwayModel.refresh()
      } else if selectedSource == .fly {
        await flyModel.refresh()
      } else if selectedSource == .netlify {
        await netlifyModel.refresh()
      } else if selectedSource == .hostinger {
        await hostingerModel.refresh()
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
      if oldProvider == .hostinger, newProvider != .hostinger {
        hostingerModel.cancelRefresh()
      }
    }
    .onAppear(perform: restoreDashboardSelection)
    .onChange(of: providerConfiguration.selectedProvider) { _, provider in
      selectedDashboardTab = provider.rawValue
    }
    .onDisappear {
      flyModel.cancelRefresh()
      netlifyModel.cancelRefresh()
      hostingerModel.cancelRefresh()
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      PortDeckMarkShape()
        .fill(.white, style: FillStyle(eoFill: true))
        .frame(width: 28, height: 12)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text("PortDeck")
          .font(.headline)
        Text("Your command center for the apps you build")
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
      VercelStatusView(
        model: vercelModel,
        searchText: vercelSearchText,
        onRefresh: refreshSelectedSource
      )
    case .convex:
      if !convexModel.candidates.isEmpty {
        searchField(placeholder: "Filter Convex projects...", text: $convexSearchText)
      }
      ConvexStatusView(
        model: convexModel,
        searchText: convexSearchText,
        onRefresh: refreshSelectedSource
      )
    case .github:
      if !githubModel.candidates.isEmpty {
        searchField(placeholder: "Filter GitHub Actions...", text: $githubSearchText)
      }
      GitHubStatusView(
        model: githubModel,
        searchText: githubSearchText,
        onRefresh: refreshSelectedSource
      )
    case .supabase:
      if !supabaseModel.projects.isEmpty {
        searchField(placeholder: "Filter Supabase projects...", text: $supabaseSearchText)
      }
      SupabaseStatusView(
        model: supabaseModel,
        searchText: supabaseSearchText,
        onRefresh: refreshSelectedSource
      )
    case .cloudflare:
      if cloudflareModel.resourceCount > 0 {
        searchField(placeholder: "Filter Cloudflare resources...", text: $cloudflareSearchText)
      }
      CloudflareStatusView(
        model: cloudflareModel,
        searchText: cloudflareSearchText,
        onRefresh: refreshSelectedSource
      )
    case .railway:
      if !railwayModel.projects.isEmpty {
        searchField(placeholder: "Filter Railway resources...", text: $railwaySearchText)
      }
      RailwayStatusView(
        model: railwayModel,
        searchText: railwaySearchText,
        onRefresh: refreshSelectedSource
      )
    case .fly:
      if !flyModel.apps.isEmpty {
        searchField(placeholder: "Filter Fly resources...", text: $flySearchText)
      }
      FlyStatusView(
        model: flyModel,
        searchText: flySearchText,
        onRefresh: refreshSelectedSource
      )
    case .netlify:
      if !netlifyModel.sites.isEmpty {
        searchField(placeholder: "Filter Netlify projects...", text: $netlifySearchText)
      }
      NetlifyStatusView(
        model: netlifyModel,
        searchText: netlifySearchText,
        onRefresh: refreshSelectedSource
      )
    case .hostinger:
      if !hostingerModel.websites.isEmpty {
        searchField(placeholder: "Filter Hostinger websites...", text: $hostingerSearchText)
      }
      HostingerStatusView(
        model: hostingerModel,
        searchText: hostingerSearchText,
        onRefresh: refreshSelectedSource
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
        lastUpdated: model.lastUpdated,
        hasRefreshError: model.errorMessage != nil,
        isRefreshing: model.isRefreshing,
        onRefresh: refreshSelectedSource
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
        Button {
          refreshSelectedSource()
        } label: {
          Label("Try again", systemImage: "arrow.clockwise")
        }
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
    VStack(spacing: 0) {
      if updateController.isUpdateAvailable {
        FooterMenuAction(
          title: "Update ready, restart now?",
          systemImage: "arrow.down.circle"
        ) {
          updateController.checkForUpdates()
        }
        .help(updateButtonHelp)
      }

#if !APP_STORE
      FooterMenuAction(
        title: "Donate",
        systemImage: "heart.fill"
      ) {
        openDonationPage()
      }
      .help("Open Buy Me a Coffee")
#endif

      FooterMenuAction(
        title: "Settings…",
        systemImage: "gearshape",
        shortcut: "⌘ ,"
      ) {
        SettingsWindowPresenter.present(openSettings: {
          openSettings()
        })
      }
      .keyboardShortcut(",", modifiers: .command)

      FooterMenuAction(
        title: "About PortDeck",
        systemImage: "info.circle"
      ) {
        presentAbout()
      }

      FooterMenuAction(
        title: "Quit",
        systemImage: "xmark.rectangle",
        shortcut: "⌘ Q"
      ) {
        NSApplication.shared.terminate(nil)
      }
      .keyboardShortcut("q", modifiers: .command)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
  }

  private var updateButtonHelp: String {
    guard let availableVersion = updateController.availableVersion else {
      return "Download and install the latest PortDeck release"
    }
    return "Download and install PortDeck \(availableVersion)"
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
    case .hostinger:
      return hostingerModel.showsHeaderProgress
    case .local:
      return model.showsHeaderProgress
    }
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
    isAboutPresented = false
    isProviderCustomizationPresented = true
  }

  private func presentAbout() {
    dismissCommandPalette()
    isProviderCustomizationPresented = false
    isAboutPresented = true
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

  private func dismissAbout() {
    isAboutPresented = false
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
    case .hostinger:
      Task { await hostingerModel.refresh() }
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

private struct FooterMenuAction: View {
  let title: String
  let systemImage: String
  var shortcut: String?
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: systemImage)
          .font(.callout)
          .frame(width: 18)

        Text(title)
          .font(.callout)
          .fontWeight(.medium)

        Spacer()

        if let shortcut {
          Text(shortcut)
            .font(.callout.monospaced())
            .foregroundStyle(.tertiary)
        }
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, 8)
      .frame(height: 24)
      .contentShape(Rectangle())
      .background(
        isHovering ? Color.primary.opacity(0.08) : Color.clear,
        in: RoundedRectangle(cornerRadius: 7)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }
}

private struct AboutPortDeckOverlay: View {
  let version: String
  let onDismiss: () -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.24)
        .ignoresSafeArea()
        .onTapGesture(perform: onDismiss)

      VStack(spacing: 0) {
        HStack {
          Text("About PortDeck")
            .font(.headline)
            .fontWeight(.semibold)

          Spacer()

          Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
              .font(.title3)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .keyboardShortcut(.cancelAction)
          .accessibilityLabel("Close About PortDeck")
          .help("Close About PortDeck")
        }
        .padding(14)

        Divider()

        VStack(spacing: 12) {
          PortDeckMarkShape()
            .fill(.white, style: FillStyle(eoFill: true))
            .frame(width: 56, height: 24)
            .accessibilityHidden(true)

          VStack(spacing: 3) {
            Text("PortDeck")
              .font(.title3)
              .fontWeight(.semibold)
            Text("Version \(version)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          VStack(spacing: 4) {
            Text("Built by")
              .font(.caption)
              .foregroundStyle(.secondary)

            HStack(spacing: 4) {
              Link(FooterAttribution.jesseName, destination: FooterAttribution.jesseURL)
              Text("/")
                .foregroundStyle(.secondary)
              Link(FooterAttribution.studioName, destination: FooterAttribution.studioURL)
            }
            .font(.callout)
          }

          HStack(spacing: 12) {
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
          .foregroundStyle(.secondary)
          .tint(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
      }
      .frame(width: 330)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(.white.opacity(0.16), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.30), radius: 24, y: 12)
      .padding()
    }
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
          ProjectHeaderLabel(
            projectName: project.group.projectName,
            branchMetadata: headerBranchMetadata,
            problemLabel: projectSummary.problemLabel
          )
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
              branchDisplayedInProjectHeader: headerBranchMetadata != nil,
              projectWorktreeCount: project.group.worktrees.count,
              isStopping: isStopping,
              stoppingProjectTarget: stoppingProjectTarget,
              stoppingServiceID: stoppingServiceID,
              onStop: onStop
            )
          }
        }
        .padding(.leading, 2)
        .padding(.trailing, 10)
        .padding(.bottom, 10)
      }
    }
    .background(.background.opacity(0.70), in: RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(.quaternary)
    )
  }

  private var headerBranchMetadata: LocalMetadataItem? {
    guard project.group.worktrees.count == 1, let worktree = project.worktrees.first else {
      return nil
    }

    return LocalStatusPresentation.worktreeMetadata(
      worktree.worktree,
      projectName: project.group.projectName,
      repoRoot: project.group.repoRoot,
      projectWorktreeCount: project.group.worktrees.count
    ).first { $0.systemImage == "arrow.triangle.branch" }
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

struct ProjectHeaderLabel: View {
  let projectName: String
  let branchMetadata: LocalMetadataItem?
  let problemLabel: String?

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        projectNameLabel
          .fixedSize(horizontal: true, vertical: false)
        if let branchMetadata {
          MetadataChip(
            text: branchMetadata.text,
            systemImage: branchMetadata.systemImage
          )
          .fixedSize(horizontal: true, vertical: false)
        }
        problemBadge
        Spacer(minLength: 0)
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          projectNameLabel
          problemBadge
          Spacer(minLength: 0)
        }

        if let branchMetadata {
          MetadataChip(
            text: branchMetadata.text,
            systemImage: branchMetadata.systemImage,
            lineLimit: 2
          )
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var projectNameLabel: some View {
    Text(projectName)
      .font(.headline)
      .lineLimit(1)
      .layoutPriority(1)
  }

  @ViewBuilder
  private var problemBadge: some View {
    if let problemLabel {
      Text(problemLabel)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.orange.opacity(0.11), in: Capsule())
    }
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
  let branchDisplayedInProjectHeader: Bool
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
    ).filter { item in
      !branchDisplayedInProjectHeader || item.systemImage != "arrow.triangle.branch"
    }
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
  let lastUpdated: Date?
  let hasRefreshError: Bool
  let isRefreshing: Bool
  let onRefresh: () -> Void

  var body: some View {
    HStack {
      Label("This Mac", systemImage: "laptopcomputer")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      RefreshStatusControl(
        sourceName: "Local",
        lastUpdated: lastUpdated,
        isRefreshing: isRefreshing,
        hasError: hasRefreshError,
        onRefresh: onRefresh
      )
    }
    .padding(.horizontal, 2)
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
  var lineLimit = 1

  var body: some View {
    Label(text, systemImage: systemImage)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(lineLimit)
      .truncationMode(.middle)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(.quaternary.opacity(0.75), in: Capsule())
  }
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
    case .hostinger:
      return "Hostinger"
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
    case .hostinger:
      return "globe"
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
    case .hostinger:
      return .indigo
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
    case .hostinger:
      return "Show Hostinger hosted website enabled state"
    }
  }
}
