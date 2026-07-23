import AppKit
import PortDeckCore
import SwiftUI

struct SupabaseStatusView: View {
  @ObservedObject var model: SupabaseStatusModel
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
        systemImage: "bolt.fill",
        title: "No accessible Supabase projects",
        detail: "The current Supabase CLI account does not have access to any projects."
      )
    case .missingCLI:
      ProviderCLISetupView(
        systemImage: "terminal",
        title: "Supabase CLI required",
        detail: "Install a supported Supabase CLI. PortDeck reuses its local session and never installs or upgrades it automatically.",
        installCommand: SupabaseRuntimeResolver.installCommand,
        documentationURL: SupabaseRuntimeResolver.documentationURL,
        onRefresh: onRefresh
      )
    case .unsupportedCLI(let currentVersion):
      ProviderCLISetupView(
        systemImage: "exclamationmark.triangle",
        title: "Update Supabase CLI",
        detail: "Version \(currentVersion) is installed. PortDeck supports \(SupabaseCLIClient.supportedVersionRange.displayName).",
        installCommand: SupabaseRuntimeResolver.installCommand,
        documentationURL: SupabaseRuntimeResolver.documentationURL,
        onRefresh: onRefresh
      )
    case .authenticationRequired:
      setupState(
        systemImage: "person.crop.circle.badge.exclamationmark",
        title: "Supabase authentication required",
        detail: "Sign in from Terminal. PortDeck reuses the Supabase CLI session without receiving or storing its token.",
        actionTitle: "Copy login command",
        actionSystemImage: "doc.on.doc",
        action: { copyCommand(SupabaseCLIClient.loginCommand) },
        command: SupabaseCLIClient.loginCommand
      )
    case .rateLimited(let message):
      setupState(
        systemImage: "clock.badge.exclamationmark",
        title: "Supabase rate limit reached",
        detail: message,
        actionTitle: "Try again",
        actionSystemImage: "arrow.clockwise",
        action: onRefresh
      )
    case .failed(let message):
      setupState(
        systemImage: "exclamationmark.triangle",
        title: "Supabase projects unavailable",
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
        SupabaseInlineWarning(message: errorMessage)
      }

      HStack {
        Label("Account projects", systemImage: "bolt.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if let lastUpdated = model.lastSuccessfulRefreshAt {
          SupabasePollingStatus(lastUpdated: lastUpdated, hasError: model.errorMessage != nil)
        } else {
          Text("Every \(SupabaseStatusModel.refreshIntervalSeconds)s")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 2)

      let filtered = model.filteredProjects(matching: searchText)
      if filtered.isEmpty {
        emptyState(
          systemImage: "magnifyingglass",
          title: "No matching Supabase projects",
          detail: "Clear the search to see every accessible project."
        )
      } else {
        ForEach(filtered) { project in
          SupabaseProjectRow(project: project)
        }
      }
    }
  }

  private var loadingState: some View {
    VStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Loading Supabase projects")
        .font(.callout)
        .fontWeight(.semibold)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 34)
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
        .frame(maxWidth: 360)
      }

      Button(action: action) {
        Label(actionTitle, systemImage: actionSystemImage)
      }
      .buttonStyle(.borderedProminent)
      .tint(.green)
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

private struct SupabaseInlineWarning: View {
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 7) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text("Refresh failed · showing the last successful snapshot")
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
}

private struct SupabasePollingStatus: View {
  let lastUpdated: Date
  let hasError: Bool

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let age = max(0, Int(context.date.timeIntervalSince(lastUpdated)))
      HStack(spacing: 4) {
        Circle()
          .fill(hasError ? Color.orange : Color.green)
          .frame(width: 6, height: 6)
        Text("Checked \(age)s ago")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "Supabase projects refresh every \(SupabaseStatusModel.refreshIntervalSeconds) seconds. Last successful check \(age) seconds ago."
      )
      .help("Supabase projects refresh every \(SupabaseStatusModel.refreshIntervalSeconds) seconds while this tab is open.")
    }
  }
}

private struct SupabaseProjectRow: View {
  let project: SupabaseProject

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        Circle()
          .fill(statusColor)
          .frame(width: 7, height: 7)
        Text(project.name)
          .font(.callout)
          .fontWeight(.semibold)
          .lineLimit(1)
        Spacer()
        Text(project.platformState.title)
          .font(.caption2)
          .fontWeight(.semibold)
          .foregroundStyle(statusColor)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(statusColor.opacity(0.12), in: Capsule())
      }

      HStack(spacing: 8) {
        Text(project.reference)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        if let dashboardURL = project.dashboardURL {
          Button {
            NSWorkspace.shared.open(dashboardURL)
          } label: {
            Image(systemName: "arrow.up.forward.square.fill")
              .foregroundStyle(.green)
          }
          .buttonStyle(.plain)
          .help("Open Supabase project dashboard")
        }
      }

      HStack(spacing: 6) {
        if let organization = project.organizationSlug ?? project.organizationID {
          SupabaseMetadataChip(text: organization, systemImage: "building.2")
        }
        if let region = project.region {
          SupabaseMetadataChip(text: region, systemImage: "globe.americas")
        }
        if let createdAt = project.createdAt {
          SupabaseMetadataChip(
            text: createdAt.formatted(.dateTime.year().month(.abbreviated).day()),
            systemImage: "calendar"
          )
        }
      }
    }
    .padding(12)
    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary.opacity(0.9)))
  }

  private var statusColor: Color {
    switch project.platformState {
    case .healthy: return .green
    case .degraded: return .red
    case .updating: return .orange
    case .paused: return .yellow
    case .unknown: return .secondary
    }
  }
}

private struct SupabaseMetadataChip: View {
  let text: String
  let systemImage: String

  var body: some View {
    Label(text, systemImage: systemImage)
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(.quaternary.opacity(0.75), in: Capsule())
  }
}
