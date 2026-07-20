import AppKit
import PortDeckCore
import SwiftUI

struct CloudflareStatusView: View {
  @ObservedObject var model: CloudflareStatusModel
  let searchText: String
  let onRefresh: () -> Void

  var body: some View {
    if model.resourceCount == 0 && model.isRefreshing {
      loadingState
    } else if model.resourceCount == 0 {
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
        systemImage: "cloud.fill",
        title: "No Cloudflare resources",
        detail: model.candidates.isEmpty
          ? "No Pages projects were returned and no active local Wrangler configuration was found."
          : "No Pages projects or Worker deployments were returned for the current Wrangler accounts."
      )
    case .missingRuntime:
      setupState(
        systemImage: "terminal",
        title: "Wrangler runtime unavailable",
        detail: "PortDeck could not find its managed Wrangler runtime. Reinstall dependencies or rebuild PortDeck.",
        actionTitle: "Try again",
        actionSystemImage: "arrow.clockwise",
        action: onRefresh
      )
    case .incompatibleRuntime(let currentVersion):
      setupState(
        systemImage: "exclamationmark.triangle",
        title: "Wrangler runtime incompatible",
        detail: "PortDeck found Wrangler \(currentVersion), but this build requires exactly \(CloudflareCLIClient.pinnedVersion).",
        actionTitle: "Try again",
        actionSystemImage: "arrow.clockwise",
        action: onRefresh
      )
    case .authenticationRequired:
      setupState(
        systemImage: "person.crop.circle.badge.exclamationmark",
        title: "Cloudflare authentication required",
        detail: "Sign in from Terminal. PortDeck reuses Wrangler's session without receiving or storing its token.",
        actionTitle: "Copy login command",
        actionSystemImage: "doc.on.doc",
        action: { copyCommand(CloudflareCLIClient.loginCommand) },
        command: CloudflareCLIClient.loginCommand
      )
    case .rateLimited(let message):
      setupState(
        systemImage: "clock.badge.exclamationmark",
        title: "Cloudflare rate limit reached",
        detail: message,
        actionTitle: "Try again",
        actionSystemImage: "arrow.clockwise",
        action: onRefresh
      )
    case .failed(let message):
      setupState(
        systemImage: "exclamationmark.triangle",
        title: "Cloudflare resources unavailable",
        detail: message,
        actionTitle: "Try again",
        actionSystemImage: "arrow.clockwise",
        action: onRefresh
      )
    }
  }

  private var connectedContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let pagesError = model.pagesErrorMessage {
        inlineWarning(title: "Pages refresh degraded", message: pagesError)
      }
      if let workersError = model.workersErrorMessage {
        inlineWarning(title: "Workers refresh degraded", message: workersError)
      }

      let pages = model.filteredPages(matching: searchText)
      let workers = model.filteredWorkers(matching: searchText)
      if pages.isEmpty && workers.isEmpty {
        emptyState(
          systemImage: "magnifyingglass",
          title: "No matching Cloudflare resources",
          detail: "Clear the search to see every Pages project and linked Worker."
        )
      } else {
        if !pages.isEmpty {
          sectionHeader(
            title: "Pages",
            count: pages.count,
            lastUpdated: model.lastSuccessfulPagesRefreshAt,
            hasError: model.pagesErrorMessage != nil
          )
          ForEach(pages) { project in CloudflarePagesRow(project: project) }
        }
        if !workers.isEmpty {
          sectionHeader(
            title: "Workers",
            count: workers.count,
            lastUpdated: model.lastSuccessfulWorkersRefreshAt,
            hasError: model.workersErrorMessage != nil
          )
          ForEach(workers) { worker in CloudflareWorkerRow(worker: worker) }
        }
      }
    }
  }

  private var loadingState: some View {
    VStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("Loading Cloudflare resources")
        .font(.callout)
        .fontWeight(.semibold)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 34)
  }

  private func sectionHeader(title: String, count: Int, lastUpdated: Date?, hasError: Bool) -> some View {
    HStack {
      Label("\(title) · \(count)", systemImage: title == "Pages" ? "doc.on.globe" : "cloud.fill")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      if let lastUpdated {
        CloudflarePollingStatus(lastUpdated: lastUpdated, hasError: hasError, title: title)
      } else {
        Text("Every \(CloudflareStatusModel.refreshIntervalSeconds)s")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 2)
  }

  private func inlineWarning(title: String, message: String) -> some View {
    HStack(alignment: .top, spacing: 7) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text("\(title) · showing retained data")
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
        .tint(.orange)
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

private struct CloudflarePagesRow: View {
  let project: CloudflarePagesProject

  var body: some View {
    CloudflareResourceCard(kind: .pages, title: project.name, state: project.state) {
      HStack(spacing: 6) {
        metadata(project.account.name, image: "building.2")
        if let deployment = project.deployment {
          metadata(deployment.branch, image: "arrow.triangle.branch")
          metadata(deployment.rawStatus, image: "clock")
        } else if !project.lastModified.isEmpty {
          metadata(project.lastModified, image: "clock")
        }
      }

      HStack(spacing: 8) {
        if let domain = project.domains.first {
          Text(domain).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        } else {
          Text("No production domain returned").font(.caption).foregroundStyle(.tertiary)
        }
        Spacer()
        if let deployment = project.deployment, let url = deployment.deploymentURL {
          linkButton(url, help: "Open Pages deployment")
        }
        if let deployment = project.deployment, let url = deployment.dashboardURL {
          linkButton(url, help: "Open Pages deployment dashboard")
        }
      }
    }
  }
}

private struct CloudflareWorkerRow: View {
  let worker: CloudflareWorkerResource

  var body: some View {
    CloudflareResourceCard(kind: .worker, title: worker.candidate.name, state: worker.state) {
      HStack(spacing: 6) {
        if let account = worker.account { metadata(account.name, image: "building.2") }
        else { metadata("Ambiguous account", image: "questionmark.circle") }
        if let deployment = worker.deployment {
          metadata(deployment.createdAt.formatted(.relative(presentation: .named)), image: "clock")
          if deployment.state == .gradualRollout {
            metadata(trafficSummary(deployment), image: "chart.pie")
          }
        }
      }

      HStack(spacing: 8) {
        Text(worker.candidate.associatedProjectNames.joined(separator: ", "))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        if let dashboardURL = worker.dashboardURL {
          linkButton(dashboardURL, help: "Open Cloudflare Workers dashboard")
        }
      }

      if let message = worker.deployment?.annotations?.message, !message.isEmpty {
        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
    }
  }

  private func trafficSummary(_ deployment: CloudflareWorkerDeployment) -> String {
    deployment.versions.map { "\(Int($0.percentage))%" }.joined(separator: " / ")
  }
}

private struct CloudflareResourceCard<Content: View>: View {
  let kind: CloudflareResourceKind
  let title: String
  let state: CloudflareResourceState
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        Circle().fill(statusColor).frame(width: 7, height: 7)
        Text(title).font(.callout).fontWeight(.semibold).lineLimit(1)
        Text(kind.title.uppercased())
          .font(.caption2.weight(.bold))
          .foregroundStyle(.orange)
        Spacer()
        Text(state.title)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(statusColor)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(statusColor.opacity(0.12), in: Capsule())
      }
      content()
    }
    .padding(12)
    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.orange.opacity(0.22)))
  }

  private var statusColor: Color {
    switch state {
    case .successful, .active: return .green
    case .deploying, .gradualRollout: return .orange
    case .failed: return .red
    case .canceled: return .yellow
    case .unknown: return .secondary
    }
  }
}

private struct CloudflarePollingStatus: View {
  let lastUpdated: Date
  let hasError: Bool
  let title: String

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let age = max(0, Int(context.date.timeIntervalSince(lastUpdated)))
      HStack(spacing: 4) {
        Circle().fill(hasError ? Color.orange : Color.green).frame(width: 6, height: 6)
        Text("Checked \(age)s ago").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Cloudflare \(title) last successful check \(age) seconds ago.")
    }
  }
}

@MainActor
private func metadata(_ text: String, image: String) -> some View {
  Label(text, systemImage: image)
    .font(.caption2)
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(.quaternary.opacity(0.75), in: Capsule())
}

@MainActor
private func linkButton(_ url: URL, help: String) -> some View {
  Button { NSWorkspace.shared.open(url) } label: {
    Image(systemName: "arrow.up.forward.square.fill").foregroundStyle(.orange)
  }
  .buttonStyle(.plain)
  .help(help)
}
