import AppKit
import PortDeckCore
import SwiftUI

struct RailwayStatusView: View {
  @ObservedObject var model: RailwayStatusModel
  let searchText: String
  let onRefresh: () -> Void

  var body: some View {
    if model.projects.isEmpty && model.isRefreshing {
      loadingState
    } else if model.projects.isEmpty {
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
        systemImage: "tram.fill",
        title: "No Railway projects",
        detail: "The current Railway account does not have access to any projects."
      )
    case .missingCLI:
      ProviderCLISetupView(
        systemImage: "terminal",
        title: "Railway CLI required",
        detail: "Install a supported Railway CLI. PortDeck reuses its local session and never installs or upgrades it automatically.",
        installCommand: RailwayRuntimeResolver.installCommand,
        documentationURL: RailwayRuntimeResolver.documentationURL,
        onRefresh: onRefresh
      )
    case .unsupportedCLI(let currentVersion):
      ProviderCLISetupView(
        systemImage: "exclamationmark.triangle",
        title: "Update Railway CLI",
        detail: "Version \(currentVersion) is installed. PortDeck supports \(RailwayCLIClient.supportedVersionRange.displayName).",
        installCommand: RailwayRuntimeResolver.installCommand,
        documentationURL: RailwayRuntimeResolver.documentationURL,
        onRefresh: onRefresh
      )
    case .authenticationRequired:
      setupState(
        systemImage: "person.crop.circle.badge.exclamationmark",
        title: "Railway authentication required",
        detail: "Sign in from Terminal. PortDeck reuses Railway CLI's session without receiving or storing its token.",
        actionTitle: "Copy login command",
        actionSystemImage: "doc.on.doc",
        action: { copyCommand(RailwayCLIClient.loginCommand) },
        command: RailwayCLIClient.loginCommand
      )
    case .rateLimited(let message):
      setupState(
        systemImage: "clock.badge.exclamationmark",
        title: "Railway rate limit reached",
        detail: message,
        actionTitle: "Try again",
        actionSystemImage: "arrow.clockwise",
        action: onRefresh
      )
    case .failed(let message):
      setupState(
        systemImage: "exclamationmark.triangle",
        title: "Railway projects unavailable",
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
        Label("Production services", systemImage: "tram.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if let lastUpdated = model.lastSuccessfulRefreshAt {
          pollingStatus(lastUpdated: lastUpdated)
        } else {
          Text("Every \(RailwayStatusModel.refreshIntervalSeconds)s")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 2)

      let filtered = model.filteredProjects(matching: searchText)
      if filtered.isEmpty {
        emptyState(
          systemImage: "magnifyingglass",
          title: "No matching Railway resources",
          detail: "Clear the search to see every project and production service."
        )
      } else {
        ForEach(filtered) { project in
          RailwayProjectSection(project: project)
        }
      }
    }
  }

  private var loadingState: some View {
    VStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("Loading Railway projects")
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
        Text("Refresh degraded · showing retained data")
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
      .accessibilityLabel("Railway last successful check \(age) seconds ago.")
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
        .tint(.purple)
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

  private func copyCommand(_ command: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
  }
}

private struct RailwayProjectSection: View {
  let project: RailwayProject

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 7) {
        Image(systemName: "folder.fill").foregroundStyle(.purple)
        Text(project.name).font(.callout).fontWeight(.semibold).lineLimit(1)
        Text(project.workspace.name)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if project.isArchived {
          Text("ARCHIVED")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let url = project.dashboardURL {
          Button { NSWorkspace.shared.open(url) } label: {
            Image(systemName: "arrow.up.forward.square.fill").foregroundStyle(.purple)
          }
          .buttonStyle(.plain)
          .help("Open Railway project dashboard")
        }
      }

      switch project.productionState {
      case .unavailable:
        projectMessage("Production environment unavailable", image: "questionmark.circle")
      case .failed(let message):
        projectMessage("Production refresh failed · \(message)", image: "exclamationmark.triangle")
        ForEach(project.services) { service in RailwayServiceRow(service: service) }
      case .available where project.services.isEmpty:
        projectMessage("No production services", image: "shippingbox")
      case .available:
        ForEach(project.services) { service in RailwayServiceRow(service: service) }
      }
    }
    .padding(11)
    .background(.purple.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.purple.opacity(0.24)))
  }

  private func projectMessage(_ text: String, image: String) -> some View {
    Label(text, systemImage: image)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

private struct RailwayServiceRow: View {
  let service: RailwayService

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 7) {
        Circle().fill(statusColor).frame(width: 7, height: 7)
        Text(service.name).font(.callout).fontWeight(.semibold).lineLimit(1)
        Spacer()
        Text(service.state.title)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(statusColor)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(statusColor.opacity(0.12), in: Capsule())
      }

      HStack(spacing: 6) {
        if let deployment = service.latestDeployment {
          if let createdAt = deployment.createdAt {
            metadata(createdAt.formatted(.relative(presentation: .named)), image: "clock")
          }
          if let branch = deployment.branch { metadata(branch, image: "arrow.triangle.branch") }
          if let sha = deployment.shortCommitSHA { metadata(sha, image: "number") }
        }
        if let region = service.regions.first {
          metadata(region.location ?? region.name, image: "globe.americas")
        }
        if let replicas = service.replicas {
          metadata("\(replicas.running)/\(replicas.configured) replicas", image: "square.stack.3d.up")
        }
        Spacer(minLength: 0)
        if let url = service.productionURL {
          Button { NSWorkspace.shared.open(url) } label: {
            Image(systemName: "arrow.up.forward.square.fill").foregroundStyle(.purple)
          }
          .buttonStyle(.plain)
          .help("Open Railway production service")
        }
      }

      if let message = service.latestDeployment?.commitMessage, !message.isEmpty {
        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
    }
    .padding(10)
    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
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

  private var statusColor: Color {
    switch service.state {
    case .successful: return .green
    case .failed, .crashed: return .red
    case .deploying: return .orange
    case .queued, .removing, .removed: return .yellow
    case .unknown: return .secondary
    }
  }
}
