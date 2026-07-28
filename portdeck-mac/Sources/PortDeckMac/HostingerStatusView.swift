import AppKit
import PortDeckCore
import SwiftUI

struct HostingerStatusView: View {
  @ObservedObject var model: HostingerStatusModel
  let searchText: String
  let onRefresh: () -> Void

  var body: some View {
    if model.websites.isEmpty && model.isRefreshing {
      loadingState
    } else if model.websites.isEmpty && model.connectionState != .connected {
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
        systemImage: "globe",
        title: "No Hostinger websites",
        detail: "The current Hostinger account does not have access to any hosted websites."
      )
    case .missingCLI:
      ProviderCLISetupView(
        systemImage: "terminal",
        title: "Hostinger CLI required",
        detail: "Install the official Hostinger CLI. PortDeck reuses its existing local authentication and never installs or upgrades it automatically.",
        installCommand: HostingerRuntimeResolver.installCommand,
        documentationURL: HostingerRuntimeResolver.documentationURL,
        onRefresh: onRefresh
      )
    case .unsupportedCLI(let currentVersion):
      ProviderCLISetupView(
        systemImage: "exclamationmark.triangle",
        title: "Update Hostinger CLI",
        detail: "PortDeck found \(currentVersion). It supports Hostinger CLI \(HostingerCLIClient.supportedVersionRange.displayName).",
        installCommand: HostingerRuntimeResolver.installCommand,
        documentationURL: HostingerRuntimeResolver.documentationURL,
        onRefresh: onRefresh
      )
    case .authenticationRequired:
      setupState(
        systemImage: "person.crop.circle.badge.exclamationmark",
        title: "Hostinger authentication required",
        detail: "Run the read-only website command in Terminal to connect the official CLI. PortDeck blocks interactive sign-in during automatic refreshes and never receives or stores your token.",
        actionTitle: "Copy connect command",
        actionSystemImage: "doc.on.doc",
        action: { copyCommand(HostingerCLIClient.connectCommand) },
        command: HostingerCLIClient.connectCommand
      )
    case .rateLimited(let message):
      setupState(
        systemImage: "clock.badge.exclamationmark",
        title: "Hostinger rate limit reached",
        detail: message,
        actionTitle: "Try again",
        actionSystemImage: "arrow.clockwise",
        action: onRefresh
      )
    case .failed(let message):
      setupState(
        systemImage: "exclamationmark.triangle",
        title: "Hostinger websites unavailable",
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
        Label("Hostinger websites", systemImage: "globe")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        RefreshStatusControl(
          sourceName: "Hostinger",
          lastUpdated: model.lastSuccessfulRefreshAt,
          isRefreshing: model.isRefreshing,
          hasError: model.errorMessage != nil,
          onRefresh: onRefresh
        )
      }
      .padding(.horizontal, 2)

      HStack(spacing: 6) {
        Text("Enabled state comes from Hostinger; PortDeck does not probe website uptime.")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
        Button {
          NSWorkspace.shared.open(HostingerSafeLink.websitesDashboardURL)
        } label: {
          Label("Open hPanel", systemImage: "arrow.up.forward.square")
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.indigo)
      }
      .padding(.horizontal, 2)

      let filtered = model.filteredWebsites(matching: searchText)
      if filtered.isEmpty {
        emptyState(
          systemImage: "magnifyingglass",
          title: "No matching Hostinger websites",
          detail: "Clear the search to see every domain, enabled state, website type, and hosting order."
        )
      } else {
        ForEach(filtered) { website in
          HostingerWebsiteCard(website: website)
        }
      }
    }
  }

  private var loadingState: some View {
    VStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Loading Hostinger websites")
        .font(.callout)
        .fontWeight(.semibold)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 34)
  }

  private func inlineWarning(message: String) -> some View {
    HStack(alignment: .top, spacing: 7) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(model.isRetainingSnapshot ? "Refresh degraded · showing retained data" : "Hostinger refresh degraded")
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
      Image(systemName: systemImage)
        .font(.title2)
        .foregroundStyle(.secondary)
      Text(title)
        .font(.headline)
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      if let command {
        HStack(spacing: 10) {
          Text(command)
            .font(.caption.monospaced())
            .textSelection(.enabled)
          Spacer(minLength: 8)
          Button {
            copyCommand(command)
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }
          .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
        .frame(maxWidth: 420)
      }

      Button(action: action) {
        Label(actionTitle, systemImage: actionSystemImage)
      }
      .buttonStyle(.borderedProminent)
      .tint(.indigo)
    }
    .frame(maxWidth: .infinity)
    .padding(24)
    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
  }

  private func emptyState(systemImage: String, title: String, detail: String) -> some View {
    VStack(spacing: 6) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(.secondary)
      Text(title)
        .font(.callout)
        .fontWeight(.semibold)
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

private struct HostingerWebsiteCard: View {
  let website: HostingerWebsite

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 7) {
        Circle()
          .fill(stateColor)
          .frame(width: 7, height: 7)
        Text(website.domain)
          .font(.callout)
          .fontWeight(.semibold)
          .lineLimit(1)
        Spacer()
        Text(website.state.title)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(stateColor)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(stateColor.opacity(0.12), in: Capsule())
      }

      HStack(spacing: 7) {
        if let type = website.vhostType {
          metadata(type, image: "square.stack.3d.up")
        }
        if let orderID = website.orderID {
          metadata("Order \(orderID)", image: "number")
        }
        if let parentDomain = website.parentDomain, parentDomain != website.domain {
          metadata(parentDomain, image: "arrow.turn.down.right")
        }
        Spacer(minLength: 0)
      }

      HStack(spacing: 8) {
        if let publicURL = website.publicURL {
          Button {
            NSWorkspace.shared.open(publicURL)
          } label: {
            Label("Open website", systemImage: "globe")
              .font(.caption2)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.indigo)
        }
        if let createdAt = website.createdAt {
          Text("Created \(createdAt.formatted(.relative(presentation: .named)))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        Spacer(minLength: 0)
      }
    }
    .padding(10)
    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
  }

  private var stateColor: Color {
    switch website.state {
    case .enabled:
      return .green
    case .disabled:
      return .orange
    case .unknown:
      return .secondary
    }
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
