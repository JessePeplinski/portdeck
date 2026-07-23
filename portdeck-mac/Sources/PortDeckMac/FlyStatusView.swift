import AppKit
import PortDeckCore
import SwiftUI

struct FlyStatusView: View {
  @ObservedObject var model: FlyStatusModel
  let searchText: String
  let onRefresh: () -> Void

  var body: some View {
    if model.apps.isEmpty && model.isRefreshing {
      loadingState
    } else if model.apps.isEmpty {
      emptyOrSetupState
    } else {
      connectedContent
    }
  }

  @ViewBuilder
  private var emptyOrSetupState: some View {
    switch model.connectionState {
    case .checking:
      loadingState
    case .connected:
      emptyState(
        systemImage: "airplane",
        title: model.organizations.isEmpty ? "No Fly organizations" : "No Fly apps",
        detail: model.organizations.isEmpty
          ? "The current Fly account does not have access to any organizations."
          : "The current Fly account does not have access to any apps."
      )
    case .missingCLI:
      ProviderCLISetupView(
        systemImage: "terminal",
        title: "flyctl required",
        detail: "Install a supported flyctl. PortDeck reuses its local session and never installs or upgrades it automatically.",
        installCommand: FlyRuntimeResolver.installCommand,
        documentationURL: FlyRuntimeResolver.documentationURL,
        onRefresh: onRefresh
      )
    case .unsupportedCLI(let currentVersion):
      ProviderCLISetupView(
        systemImage: "exclamationmark.triangle",
        title: "Update flyctl",
        detail: "PortDeck found \(currentVersion). It supports flyctl \(FlyCLIClient.supportedVersionRange.displayName) for Darwin.",
        installCommand: FlyRuntimeResolver.installCommand,
        documentationURL: FlyRuntimeResolver.documentationURL,
        onRefresh: onRefresh
      )
    case .authenticationRequired:
      setupState(
        systemImage: "person.crop.circle.badge.exclamationmark",
        title: "Fly authentication required",
        detail: "Sign in from Terminal. PortDeck reuses flyctl's own session without receiving or storing its token.",
        actionTitle: "Copy login command",
        actionSystemImage: "doc.on.doc",
        action: { copyCommand(FlyCLIClient.loginCommand) },
        command: FlyCLIClient.loginCommand
      )
    case .rateLimited(let message):
      setupState(
        systemImage: "clock.badge.exclamationmark",
        title: "Fly rate limit reached",
        detail: message,
        actionTitle: "Try again",
        actionSystemImage: "arrow.clockwise",
        action: onRefresh
      )
    case .failed(let message):
      setupState(
        systemImage: "exclamationmark.triangle",
        title: "Fly apps unavailable",
        detail: message,
        actionTitle: "Try again",
        actionSystemImage: "arrow.clockwise",
        action: onRefresh
      )
    }
  }

  private var connectedContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let errorMessage = model.errorMessage {
        inlineWarning(message: errorMessage)
      }

      HStack {
        Label("Fly apps", systemImage: "airplane")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if let lastUpdated = model.lastSuccessfulRefreshAt {
          pollingStatus(lastUpdated: lastUpdated)
        } else {
          Text("Every \(FlyStatusModel.refreshIntervalSeconds)s")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 2)

      let filtered = model.filteredApps(matching: searchText)
      if filtered.isEmpty {
        emptyState(
          systemImage: "magnifyingglass",
          title: "No matching Fly resources",
          detail: "Clear the search to see every app, Machine, check, region, and release."
        )
      } else {
        ForEach(organizationGroups(for: filtered)) { group in
          FlyOrganizationSection(group: group)
        }
      }
    }
  }

  private var loadingState: some View {
    VStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("Loading Fly apps")
        .font(.callout)
        .fontWeight(.semibold)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 34)
  }

  private func inlineWarning(message: String) -> some View {
    HStack(alignment: .top, spacing: 7) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(model.isRetainingSnapshot ? "Refresh degraded · showing retained data" : "Partial Fly refresh")
          .font(.caption)
          .fontWeight(.semibold)
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer(minLength: 0)
    }
    .padding(9)
    .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
  }

  private func pollingStatus(lastUpdated: Date) -> some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let age = max(0, Int(context.date.timeIntervalSince(lastUpdated)))
      HStack(spacing: 4) {
        Circle().fill(model.errorMessage == nil ? Color.green : Color.orange).frame(width: 6, height: 6)
        Text("Checked \(age)s ago").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Fly last successful check \(age) seconds ago.")
    }
  }

  private func setupState(
    systemImage: String,
    title: String,
    detail: String,
    actionTitle: String,
    actionSystemImage: String,
    action: @escaping () -> Void,
    command: String? = nil
  ) -> some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage).font(.title2).foregroundStyle(.secondary)
      Text(title).font(.headline)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      if let command {
        HStack(spacing: 10) {
          Text(command).font(.caption.monospaced()).textSelection(.enabled)
          Spacer(minLength: 8)
          Button { copyCommand(command) } label: { Label("Copy", systemImage: "doc.on.doc") }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
        .frame(maxWidth: 360)
      }

      Button(action: action) { Label(actionTitle, systemImage: actionSystemImage) }
        .buttonStyle(.borderedProminent)
        .tint(.indigo)
    }
    .frame(maxWidth: .infinity)
    .padding(24)
    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
  }

  private func emptyState(systemImage: String, title: String, detail: String) -> some View {
    VStack(spacing: 6) {
      Image(systemName: systemImage).font(.title3).foregroundStyle(.secondary)
      Text(title).font(.callout).fontWeight(.semibold)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 28)
    .padding(.horizontal, 20)
    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
  }

  private func organizationGroups(for apps: [FlyApp]) -> [FlyOrganizationGroup] {
    let grouped = Dictionary(grouping: apps, by: \.organization)
    return grouped.map { FlyOrganizationGroup(organization: $0.key, apps: FlyStatusBuilder.sortedApps($0.value)) }
      .sorted { $0.organization.name.localizedCaseInsensitiveCompare($1.organization.name) == .orderedAscending }
  }

  private func copyCommand(_ command: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
  }
}

private struct FlyOrganizationGroup: Identifiable {
  var id: String { organization.slug }
  let organization: FlyOrganization
  let apps: [FlyApp]
}

private struct FlyOrganizationSection: View {
  let group: FlyOrganizationGroup

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "building.2.fill").foregroundStyle(.indigo)
        Text(group.organization.name).font(.callout).fontWeight(.semibold).lineLimit(1)
        if group.organization.name != group.organization.slug {
          Text(group.organization.slug).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        Text("\(group.apps.count)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      ForEach(group.apps) { app in FlyAppCard(app: app) }
    }
    .padding(11)
    .background(.indigo.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.indigo.opacity(0.24)))
  }
}

private struct FlyAppCard: View {
  let app: FlyApp

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 7) {
        Circle().fill(evidenceColor).frame(width: 7, height: 7)
        Text(app.name).font(.callout).fontWeight(.semibold).lineLimit(1)
        Spacer()
        statusBadge(app.state.title, color: appStatusColor)
        statusBadge(app.evidenceState.title, color: evidenceColor)
      }

      HStack(spacing: 6) {
        if let url = app.productionURL {
          Button { NSWorkspace.shared.open(url) } label: {
            Label(url.host ?? "Open app", systemImage: "globe")
              .font(.caption2)
              .lineLimit(1)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.indigo)
          .help("Open Fly app")
        }
        metadata("\(app.machines.count) \(app.machines.count == 1 ? "Machine" : "Machines")", image: "server.rack")
        if !app.regions.isEmpty { metadata(app.regions.joined(separator: ", "), image: "globe.americas") }
        Spacer(minLength: 0)
        if let dashboardURL = app.dashboardURL {
          Button { NSWorkspace.shared.open(dashboardURL) } label: {
            Image(systemName: "arrow.up.forward.square.fill").foregroundStyle(.indigo)
          }
          .buttonStyle(.plain)
          .help("Open Fly app dashboard")
        }
      }

      if let release = app.latestRelease {
        HStack(spacing: 6) {
          Label("v\(release.version)", systemImage: "shippingbox")
            .font(.caption2.weight(.semibold))
          Text(release.state.title).font(.caption2).foregroundStyle(releaseColor(release.state))
          if let createdAt = release.createdAt {
            Text(createdAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary)
          }
          if app.isReleaseRetained {
            Text("RETAINED").font(.caption2.weight(.bold)).foregroundStyle(.orange)
          }
          Spacer(minLength: 0)
        }
        if let description = release.description, !description.isEmpty {
          Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }

      if app.machines.isEmpty {
        Label("No active Machines", systemImage: "server.rack")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 6) {
          ForEach(app.machines) { machine in FlyMachineRow(machine: machine, isRetained: app.isStatusRetained) }
        }
      }
    }
    .padding(10)
    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
  }

  private func statusBadge(_ title: String, color: Color) -> some View {
    Text(title)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(color.opacity(0.12), in: Capsule())
  }

  private func metadata(_ text: String, image: String) -> some View {
    Label(text, systemImage: image)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(.quaternary.opacity(0.75), in: Capsule())
  }

  private var appStatusColor: Color {
    switch app.state {
    case .deployed: return .green
    case .suspended: return .yellow
    case .unknown: return .secondary
    }
  }

  private var evidenceColor: Color {
    switch app.evidenceState {
    case .unhealthy: return .red
    case .degraded: return .orange
    case .transitioning: return .blue
    case .inactive: return .yellow
    case .healthy: return .green
    case .unknown: return .secondary
    }
  }

  private func releaseColor(_ state: FlyReleaseState) -> Color {
    switch state {
    case .successful: return .green
    case .failed: return .red
    case .inProgress: return .blue
    case .unknown: return .secondary
    }
  }
}

private struct FlyMachineRow: View {
  let machine: FlyMachine
  let isRetained: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Circle().fill(machineColor).frame(width: 6, height: 6)
        Text(machine.displayName).font(.caption).fontWeight(.semibold).lineLimit(1)
        Text(machine.id).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
        Spacer()
        Text(machine.state.title).font(.caption2.weight(.semibold)).foregroundStyle(machineColor)
        if isRetained { Text("RETAINED").font(.caption2.weight(.bold)).foregroundStyle(.orange) }
      }

      HStack(spacing: 6) {
        if let region = machine.region { metadata(region, image: "location") }
        metadata(machine.hostState.title, image: hostImage)
        if let updatedAt = machine.updatedAt {
          metadata(updatedAt.formatted(.relative(presentation: .named)), image: "clock")
        }
        Spacer(minLength: 0)
      }

      if machine.checks.isEmpty {
        Text("No checks").font(.caption2).foregroundStyle(.secondary)
      } else {
        HStack(spacing: 5) {
          Text("Checks").font(.caption2).foregroundStyle(.tertiary)
          ForEach(machine.checks) { check in
            HStack(spacing: 3) {
              Circle().fill(checkColor(check.state)).frame(width: 5, height: 5)
              Text("\(check.name): \(check.state.title)").lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(checkColor(check.state).opacity(0.09), in: Capsule())
          }
          Spacer(minLength: 0)
        }
      }
    }
    .padding(8)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
  }

  private func metadata(_ text: String, image: String) -> some View {
    Label(text, systemImage: image)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }

  private var machineColor: Color {
    if machine.hostState == .unreachable || machine.checks.contains(where: { $0.state == .critical }) { return .red }
    if machine.hostState == .unknown || machine.checks.contains(where: { $0.state == .warning || $0.state == .unknown }) { return .orange }
    switch machine.state {
    case .running: return .green
    case .starting, .removing: return .blue
    case .stopped, .suspended, .removed: return .yellow
    case .unknown: return .secondary
    }
  }

  private var hostImage: String {
    switch machine.hostState {
    case .reachable: return "checkmark.circle"
    case .unreachable: return "wifi.exclamationmark"
    case .unknown: return "questionmark.circle"
    }
  }

  private func checkColor(_ state: FlyCheckState) -> Color {
    switch state {
    case .passing: return .green
    case .warning: return .orange
    case .critical: return .red
    case .unknown: return .secondary
    }
  }
}
