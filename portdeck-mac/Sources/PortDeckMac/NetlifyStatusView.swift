import AppKit
import PortDeckCore
import SwiftUI

struct NetlifyStatusView: View {
  @ObservedObject var model: NetlifyStatusModel
  let searchText: String
  let onRefresh: () -> Void

  var body: some View {
    if model.sites.isEmpty && model.isRefreshing {
      loadingState
    } else if model.sites.isEmpty {
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
        systemImage: "square.grid.2x2",
        title: "No Netlify projects",
        detail: "The current Netlify account does not have access to any projects."
      )
    case .missingRuntime:
      setupState(
        systemImage: "terminal",
        title: "Netlify runtime unavailable",
        detail: "PortDeck could not find its pinned Netlify CLI runtime. Source builds resolve only the root netlify-cli dependency.",
        actionTitle: "Try again",
        actionSystemImage: "arrow.clockwise",
        action: onRefresh
      )
    case .incompatibleRuntime(let currentVersion):
      setupState(
        systemImage: "exclamationmark.triangle",
        title: "Netlify runtime incompatible",
        detail: "PortDeck found \(currentVersion), but this build requires netlify-cli \(NetlifyCLIClient.pinnedVersion) and Node \(NetlifyCLIClient.minimumNodeVersion) or newer.",
        actionTitle: "Try again",
        actionSystemImage: "arrow.clockwise",
        action: onRefresh
      )
    case .authenticationRequired:
      setupState(
        systemImage: "person.crop.circle.badge.exclamationmark",
        title: "Netlify authentication required",
        detail: "Sign in from Terminal. PortDeck reuses Netlify CLI's own session without receiving, copying, or storing its token.",
        actionTitle: "Copy login command",
        actionSystemImage: "doc.on.doc",
        action: { copyCommand(NetlifyCLIClient.loginCommand) },
        command: NetlifyCLIClient.loginCommand
      )
    case .rateLimited(let message):
      setupState(
        systemImage: "clock.badge.exclamationmark",
        title: "Netlify rate limit reached",
        detail: message,
        actionTitle: "Try again",
        actionSystemImage: "arrow.clockwise",
        action: onRefresh
      )
    case .failed(let message):
      setupState(
        systemImage: "exclamationmark.triangle",
        title: "Netlify projects unavailable",
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
        Label("Netlify projects", systemImage: "square.grid.2x2")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if let lastUpdated = model.lastSuccessfulRefreshAt {
          pollingStatus(lastUpdated: lastUpdated)
        } else {
          Text("Every \(NetlifyStatusModel.refreshIntervalSeconds)s")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 2)

      let filtered = model.filteredSites(matching: searchText)
      if filtered.isEmpty {
        emptyState(
          systemImage: "magnifyingglass",
          title: "No matching Netlify projects",
          detail: "Clear the search to see every account, project, deployment state, branch, and commit."
        )
      } else {
        ForEach(accountGroups(for: filtered)) { group in
          NetlifyAccountSection(group: group)
        }
      }
    }
  }

  private var loadingState: some View {
    VStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("Loading Netlify projects")
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
        Text(model.isRetainingSnapshot ? "Refresh degraded · showing retained data" : "Partial Netlify refresh")
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
      .accessibilityLabel("Netlify last successful check \(age) seconds ago.")
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
        .tint(.mint)
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

  private func accountGroups(for sites: [NetlifySite]) -> [NetlifyAccountGroup] {
    Dictionary(grouping: sites, by: \.account)
      .map { NetlifyAccountGroup(account: $0.key, sites: NetlifyStatusBuilder.sortedSites($0.value)) }
      .sorted { $0.account.name.localizedCaseInsensitiveCompare($1.account.name) == .orderedAscending }
  }

  private func copyCommand(_ command: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
  }
}

private struct NetlifyAccountGroup: Identifiable {
  var id: String { account.id }
  let account: NetlifyAccount
  let sites: [NetlifySite]
}

private struct NetlifyAccountSection: View {
  let group: NetlifyAccountGroup

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "building.2.fill").foregroundStyle(.mint)
        Text(group.account.name).font(.callout).fontWeight(.semibold).lineLimit(1)
        if let slug = group.account.slug, slug != group.account.name {
          Text(slug).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        Text("\(group.sites.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
      }

      ForEach(group.sites) { site in NetlifySiteCard(site: site) }
    }
    .padding(11)
    .background(.mint.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.mint.opacity(0.24)))
  }
}

private struct NetlifySiteCard: View {
  let site: NetlifySite

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 7) {
        Circle().fill(evidenceColor).frame(width: 7, height: 7)
        Text(site.name).font(.callout).fontWeight(.semibold).lineLimit(1)
        Spacer()
        statusBadge(deploymentLabel, color: evidenceColor)
      }

      HStack(spacing: 7) {
        if let url = site.productionURL {
          Button { NSWorkspace.shared.open(url) } label: {
            Label(url.host ?? "Open project", systemImage: "globe").font(.caption2).lineLimit(1)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.mint)
          .help("Open production URL")
        }
        Text(site.id).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
        Spacer(minLength: 0)
        if let dashboardURL = site.dashboardURL {
          Button { NSWorkspace.shared.open(dashboardURL) } label: {
            Image(systemName: "arrow.up.forward.square.fill").foregroundStyle(.mint)
          }
          .buttonStyle(.plain)
          .help("Open Netlify project dashboard")
        }
      }

      if let deployment = site.latestDeployment {
        Divider().opacity(0.45)
        HStack(spacing: 6) {
          Label(deployment.rawState, systemImage: "shippingbox").font(.caption2.weight(.semibold))
          if let timestamp = deployment.bestTimestamp {
            Text(timestamp.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary)
          }
          if site.isDeploymentRetained {
            Text("RETAINED").font(.caption2.weight(.bold)).foregroundStyle(.orange)
          }
          Spacer(minLength: 0)
          if let dashboardURL = deployment.dashboardURL {
            Button { NSWorkspace.shared.open(dashboardURL) } label: {
              Image(systemName: "arrow.up.forward.square").foregroundStyle(.mint)
            }
            .buttonStyle(.plain)
            .help("Open Netlify deployment dashboard")
          }
        }

        HStack(spacing: 6) {
          if let context = deployment.context { metadata(context, image: "scope") }
          if let branch = deployment.branch { metadata(branch, image: "arrow.triangle.branch") }
          if let commit = deployment.shortCommitReference { metadata(commit, image: "number") }
          if let url = deployment.deployURL {
            Button { NSWorkspace.shared.open(url) } label: {
              Label("Preview", systemImage: "globe").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.mint)
          }
          Spacer(minLength: 0)
        }

        if let summary = deployment.errorSummary ?? deployment.title {
          Text(summary).font(.caption).foregroundStyle(deployment.state == .failed ? .red : .secondary).lineLimit(2)
        }
      } else {
        Label(site.hasDeploymentFailure ? "Latest deployment unavailable" : "No production deployment", systemImage: "shippingbox")
          .font(.caption)
          .foregroundStyle(site.hasDeploymentFailure ? .orange : .secondary)
      }
    }
    .padding(10)
    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
  }

  private var deploymentLabel: String {
    if site.hasDeploymentFailure && site.latestDeployment == nil { return "Unavailable" }
    return site.latestDeployment?.state.title ?? "No deployment"
  }

  private var evidenceColor: Color {
    if site.hasDeploymentFailure { return .orange }
    switch site.latestDeployment?.state {
    case .failed: return .red
    case .deploying: return .blue
    case .inactive: return .yellow
    case .healthy: return .green
    case .unknown, .none: return .secondary
    }
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
}
