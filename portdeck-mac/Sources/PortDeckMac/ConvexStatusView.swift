import AppKit
import PortDeckCore
import SwiftUI

struct ConvexStatusView: View {
  @ObservedObject var model: ConvexStatusModel
  let searchText: String

  var body: some View {
    if model.candidates.isEmpty {
      emptyState(
        systemImage: "cube",
        title: "No linked Convex projects",
        detail: "Start a local service from a package that declares Convex to see its production health here."
      )
    } else if model.projects.isEmpty && model.isRefreshing {
      VStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Checking Convex production health")
          .font(.callout)
          .fontWeight(.semibold)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 34)
    } else if let project = model.projects.first,
      model.projects.allSatisfy({ $0.availability == project.availability }),
      project.availability == .missingCLI
    {
      ProviderCLISetupView(
        systemImage: "terminal",
        title: "Convex CLI required",
        detail: "Install a supported Convex CLI. PortDeck reuses its local session and never installs or upgrades it automatically.",
        installCommand: ConvexRuntimeResolver.installCommand,
        documentationURL: ConvexRuntimeResolver.documentationURL,
        onRefresh: { Task { await model.refresh() } }
      )
    } else if let project = model.projects.first,
      model.projects.allSatisfy({ $0.availability == project.availability }),
      project.availability == .unsupportedCLI
    {
      ProviderCLISetupView(
        systemImage: "exclamationmark.triangle",
        title: "Update Convex CLI",
        detail: project.message ?? "PortDeck supports \(ConvexCLIClient.supportedVersionRange.displayName).",
        installCommand: ConvexRuntimeResolver.installCommand,
        documentationURL: ConvexRuntimeResolver.documentationURL,
        onRefresh: { Task { await model.refresh() } }
      )
    } else {
      connectedContent
    }
  }

  @ViewBuilder
  private var connectedContent: some View {
    HStack {
      Label("Production health · last 72 hours", systemImage: "waveform.path.ecg")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      if let lastUpdated = model.lastUpdated {
        ConvexLastCheckedStatus(lastUpdated: lastUpdated)
      }
    }
    .padding(.horizontal, 2)

    let projects = model.filteredProjects(matching: searchText)
    if projects.isEmpty {
      emptyState(
        systemImage: "magnifyingglass",
        title: "No matching Convex projects",
        detail: "Clear the search to see every linked project."
      )
    } else {
      ForEach(projects) { project in
        ConvexProjectRow(
          project: project,
          isConnecting: model.isConnecting,
          onConnect: { Task { await model.connect(using: project.candidate) } }
        )
      }
    }
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
}

private struct ConvexLastCheckedStatus: View {
  let lastUpdated: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let age = convexPollingAgeSeconds(lastUpdated: lastUpdated, relativeTo: context.date)
      HStack(spacing: 4) {
        Circle()
          .fill(.green)
          .frame(width: 6, height: 6)
        Text(convexLastCheckedLabel(ageSeconds: age))
          .font(.caption)
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "Convex health checks every \(ConvexStatusModel.refreshIntervalSeconds) seconds. Last successful check \(age) seconds ago."
      )
      .help("Convex production health checks every \(ConvexStatusModel.refreshIntervalSeconds) seconds while this tab is open.")
    }
  }
}

private struct ConvexProjectRow: View {
  let project: ConvexProjectStatus
  let isConnecting: Bool
  let onConnect: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        Circle()
          .fill(statusColor)
          .frame(width: 7, height: 7)
        Text(project.displayName)
          .font(.callout)
          .fontWeight(.semibold)
          .lineLimit(1)
        Spacer()
        Text(statusTitle)
          .font(.caption2)
          .fontWeight(.semibold)
          .foregroundStyle(statusColor)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(statusColor.opacity(0.12), in: Capsule())
      }

      HStack(spacing: 8) {
        if let deploymentName = project.deploymentName {
          Text(deploymentName)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
          Text(project.packagePath)
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        Spacer()
        if let lastChecked = project.lastChecked {
          Text(relativeText(for: lastChecked))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        if let dashboardURL = project.dashboardURL {
          Button {
            NSWorkspace.shared.open(dashboardURL)
          } label: {
            Image(systemName: "arrow.up.forward.square.fill")
              .foregroundStyle(.orange)
          }
          .buttonStyle(.plain)
          .help("Open Convex production insights")
        }
      }

      if let message = project.message {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: project.availability == .ready ? "exclamationmark.triangle.fill" : "info.circle.fill")
            .foregroundStyle(project.availability == .ready ? .orange : .secondary)
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
      }

      setupAction
    }
    .padding(12)
    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary.opacity(0.9)))
  }

  @ViewBuilder
  private var setupAction: some View {
    switch project.availability {
    case .unauthenticated:
      Button(action: onConnect) {
        if isConnecting {
          ProgressView()
            .controlSize(.small)
        } else {
          Label("Connect Convex", systemImage: "person.crop.circle.badge.checkmark")
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(isConnecting)
    case .ready, .missingCLI, .unsupportedCLI, .unconfigured, .unavailable:
      EmptyView()
    }
  }

  private var statusTitle: String {
    switch project.healthState {
    case .healthy:
      return "Healthy"
    case .warning:
      return project.warningCount == 1 ? "1 warning" : "\(project.warningCount) warnings"
    case .error:
      return project.errorCount == 1 ? "1 error" : "\(project.errorCount) errors"
    case .unavailable:
      return "Health unavailable"
    }
  }

  private var statusColor: Color {
    switch project.healthState {
    case .healthy: return .green
    case .warning: return .orange
    case .error: return .red
    case .unavailable: return .secondary
    }
  }
}

private func relativeText(for date: Date) -> String {
  let formatter = RelativeDateTimeFormatter()
  formatter.unitsStyle = .abbreviated
  return formatter.localizedString(for: date, relativeTo: Date())
}

func convexPollingAgeSeconds(lastUpdated: Date, relativeTo now: Date) -> Int {
  max(0, Int(now.timeIntervalSince(lastUpdated)))
}

func convexLastCheckedLabel(ageSeconds: Int) -> String {
  "Checked \(max(0, ageSeconds))s ago"
}
