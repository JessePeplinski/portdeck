import AppKit
import PortDeckCore
import SwiftUI

struct VercelStatusView: View {
  @ObservedObject var model: VercelStatusModel
  let searchText: String

  var body: some View {
    switch model.connectionState {
    case .checking:
      loadingState(title: "Checking Vercel CLI")
    case .missingCLI:
      setupState(
        systemImage: "terminal",
        title: "Vercel CLI required",
        detail: "PortDeck reuses Vercel's local device login. Install Vercel CLI \(VercelCLIClient.minimumVersion) or newer to connect.",
        primaryTitle: "Open install guide",
        primarySystemImage: "arrow.up.forward.square",
        primaryAction: openVercelCLIDocumentation,
        command: VercelCLIClient.installCommand
      )
    case .outdatedCLI(let currentVersion):
      setupState(
        systemImage: "arrow.down.circle",
        title: "Update Vercel CLI",
        detail: "Version \(currentVersion) is installed. PortDeck requires \(VercelCLIClient.minimumVersion) or newer for authenticated API access.",
        primaryTitle: "Open update guide",
        primarySystemImage: "arrow.up.forward.square",
        primaryAction: openVercelCLIDocumentation,
        command: VercelCLIClient.installCommand
      )
    case .unauthenticated:
      setupState(
        systemImage: "triangle.fill",
        title: "Connect Vercel",
        detail: "Sign in through Vercel's device flow. PortDeck never receives or stores your account token.",
        primaryTitle: "Connect Vercel",
        primarySystemImage: "person.crop.circle.badge.checkmark",
        primaryAction: model.connect,
        secondaryTitle: "Copy manual login command",
        secondaryAction: { copyCommand("vercel login") }
      )
    case .connecting:
      loadingState(title: "Finish signing in with Vercel", detail: "Complete the device login in your browser. You can close and reopen PortDeck while it finishes.")
    case .connected:
      connectedContent
    case .failed(let message):
      setupState(
        systemImage: "exclamationmark.triangle",
        title: "Vercel status unavailable",
        detail: message,
        primaryTitle: "Try again",
        primarySystemImage: "arrow.clockwise",
        primaryAction: { Task { await model.refresh() } },
        secondaryTitle: "Copy manual login command",
        secondaryAction: { copyCommand("vercel login") }
      )
    }
  }

  @ViewBuilder
  private var connectedContent: some View {
    if let errorMessage = model.errorMessage {
      VercelInlineError(message: errorMessage)
    }

    HStack {
      Label(vercelScopeLabel(model.scope), systemImage: "person.2")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      if let lastUpdated = model.lastUpdated {
        VercelLivePollingStatus(
          lastUpdated: lastUpdated,
          hasError: model.errorMessage != nil
        )
      }
    }
    .padding(.horizontal, 2)

    let projects = model.filteredProjects(matching: searchText)
    if projects.isEmpty {
      VercelEmptyState(hasProjects: !model.projects.isEmpty, hasSearch: !normalizedSearch.isEmpty)
    } else {
      ForEach(projects) { project in
        VercelProjectRow(project: project, scope: model.scope)
      }
    }
  }

  private var normalizedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func loadingState(title: String, detail: String? = nil) -> some View {
    VStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text(title)
        .font(.callout)
        .fontWeight(.semibold)
      if let detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 34)
  }

  private func setupState(
    systemImage: String,
    title: String,
    detail: String,
    primaryTitle: String,
    primarySystemImage: String,
    primaryAction: @escaping () -> Void,
    command: String? = nil,
    secondaryTitle: String? = nil,
    secondaryAction: (() -> Void)? = nil
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
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .lineLimit(1)

          Spacer(minLength: 8)

          Button {
            copyCommand(command)
          } label: {
            Label("Copy", systemImage: "doc.on.doc")
          }
          .buttonStyle(.borderless)
          .help("Copy install command")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
          RoundedRectangle(cornerRadius: 7)
            .stroke(.quaternary)
        )
        .frame(maxWidth: 360)
      }

      HStack(spacing: 8) {
        Button(action: primaryAction) {
          Label(primaryTitle, systemImage: primarySystemImage)
        }
        .buttonStyle(.borderedProminent)

        if let secondaryTitle, let secondaryAction {
          Button(secondaryTitle, action: secondaryAction)
            .buttonStyle(.bordered)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(24)
    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
  }

  private func openVercelCLIDocumentation() {
    guard let url = URL(string: "https://vercel.com/docs/cli") else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func copyCommand(_ command: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
  }
}

private struct VercelLivePollingStatus: View {
  let lastUpdated: Date
  let hasError: Bool

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let age = vercelPollingAgeSeconds(lastUpdated: lastUpdated, relativeTo: context.date)

      HStack(spacing: 4) {
        Circle()
          .fill(hasError ? Color.orange : Color.green)
          .frame(width: 6, height: 6)
        Text(vercelLastCheckedLabel(ageSeconds: age))
          .font(.caption)
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "Live Vercel polling every \(VercelStatusModel.deploymentRefreshIntervalSeconds) seconds. Last successful check \(age) seconds ago."
      )
      .help(
        "Vercel deployment activity checks every \(VercelStatusModel.deploymentRefreshIntervalSeconds) seconds while this tab is open."
      )
    }
  }
}

private struct VercelProjectRow: View {
  let project: VercelProjectStatus
  let scope: VercelScope?

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
        Text(project.healthState.title)
          .font(.caption2)
          .fontWeight(.semibold)
          .foregroundStyle(statusColor)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(statusColor.opacity(0.12), in: Capsule())
      }

      HStack(spacing: 7) {
        if let label = project.productionURLLabel {
          Text(label)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        } else {
          Text("No production URL")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        Spacer()
        if let createdAt = project.deploymentCreatedAt {
          Text(relativeText(for: createdAt))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        if let url = project.productionURL {
          Button {
            NSWorkspace.shared.open(url)
          } label: {
            Image(systemName: "globe")
              .foregroundStyle(.blue)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(vercelProductionSiteAccessibilityLabel(projectName: project.name))
          .help("Open production site")
        }
        if let dashboardURL {
          Button {
            NSWorkspace.shared.open(dashboardURL)
          } label: {
            Image(systemName: "triangle.fill")
              .foregroundStyle(.blue)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(vercelDashboardAccessibilityLabel(
            projectName: project.name,
            opensDeployment: project.inspectorURL != nil
          ))
          .help(project.inspectorURL == nil ? "Open Vercel project" : "Open Vercel deployment")
        }
      }

      if showsMetadata {
        HStack(spacing: 6) {
          if let branch = project.deployedBranch ?? project.productionBranch {
            VercelMetadataChip(systemImage: "arrow.triangle.branch", text: branch)
          }
          if let sha = project.shortCommitSHA {
            VercelMetadataChip(systemImage: "number", text: sha, isMonospaced: true)
          }
          if let framework = project.framework {
            VercelMetadataChip(systemImage: "shippingbox", text: vercelFrameworkLabel(framework))
          }
          if let duration = project.completedBuildDuration {
            VercelMetadataChip(systemImage: "hammer", text: vercelBuildDurationLabel(duration))
          }
          if project.deployedBranch == nil,
            project.shortCommitSHA == nil,
            let source = project.deploymentSource
          {
            VercelMetadataChip(systemImage: "bolt", text: vercelSourceLabel(source))
          }
        }
      }

      if let detailText {
        Text(detailText)
          .font(.caption)
          .foregroundStyle(showsFailureDetail ? Color.red : Color.secondary)
          .lineLimit(showsFailureDetail ? 2 : 1)
          .truncationMode(.tail)
          .accessibilityLabel(showsFailureDetail ? "Deployment failure: \(detailText)" : "Deployed commit: \(detailText)")
      }
    }
    .padding(12)
    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    .overlay(
      RoundedRectangle(cornerRadius: 9)
        .stroke(.quaternary.opacity(0.9))
    )
  }

  private var statusColor: Color {
    switch project.healthState {
    case .ready:
      return .green
    case .inProgress:
      return .orange
    case .failed:
      return .red
    case .blocked:
      return .red
    case .noDeployment, .unknown:
      return .secondary
    }
  }

  private var dashboardURL: URL? {
    project.inspectorURL ?? project.dashboardURL(scope: scope)
  }

  private var showsMetadata: Bool {
    project.deployedBranch != nil
      || project.productionBranch != nil
      || project.shortCommitSHA != nil
      || project.framework != nil
      || project.completedBuildDuration != nil
      || project.deploymentSource != nil
  }

  private var showsFailureDetail: Bool {
    project.healthState == .failed || project.healthState == .blocked
  }

  private var detailText: String? {
    showsFailureDetail ? project.failureDetail : project.commitMessage
  }
}

private struct VercelMetadataChip: View {
  let systemImage: String
  let text: String
  var isMonospaced = false

  var body: some View {
    Label {
      Text(text)
        .font(isMonospaced ? .caption2.monospaced() : .caption2)
        .lineLimit(1)
        .truncationMode(.middle)
    } icon: {
      Image(systemName: systemImage)
        .font(.system(size: 9, weight: .semibold))
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(.quaternary.opacity(0.55), in: Capsule())
  }
}

private struct VercelInlineError: View {
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text("Showing last known Vercel status")
          .font(.caption)
          .fontWeight(.semibold)
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct VercelEmptyState: View {
  let hasProjects: Bool
  let hasSearch: Bool

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: hasSearch ? "magnifyingglass" : "triangle")
        .font(.title3)
        .foregroundStyle(.secondary)
      Text(hasSearch && hasProjects ? "No matching Vercel projects" : "No Vercel projects found")
        .font(.callout)
        .fontWeight(.semibold)
      Text(hasSearch && hasProjects ? "Clear the search to see every project." : "PortDeck is using the active Vercel CLI team.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 28)
    .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
  }
}

private func relativeText(for date: Date) -> String {
  let formatter = RelativeDateTimeFormatter()
  formatter.unitsStyle = .abbreviated
  return formatter.localizedString(for: date, relativeTo: Date())
}

func vercelPollingAgeSeconds(lastUpdated: Date, relativeTo now: Date) -> Int {
  max(0, Int(now.timeIntervalSince(lastUpdated)))
}

func vercelLastCheckedLabel(ageSeconds: Int) -> String {
  "Checked \(max(0, ageSeconds))s ago"
}

func vercelScopeLabel(_ scope: VercelScope?) -> String {
  scope?.displayName ?? "Active Vercel CLI team"
}

func vercelProductionSiteAccessibilityLabel(projectName: String) -> String {
  "Open \(projectName) production site"
}

func vercelDashboardAccessibilityLabel(projectName: String, opensDeployment: Bool) -> String {
  opensDeployment
    ? "Open \(projectName) Vercel deployment"
    : "Open \(projectName) Vercel project"
}

func vercelBuildDurationLabel(_ duration: TimeInterval) -> String {
  let seconds = max(0, Int(duration.rounded()))
  guard seconds >= 60 else {
    return "\(seconds)s"
  }
  return "\(seconds / 60)m \(seconds % 60)s"
}

private func vercelFrameworkLabel(_ framework: String) -> String {
  switch framework.lowercased() {
  case "nextjs":
    return "Next.js"
  case "nuxtjs":
    return "Nuxt"
  case "sveltekit":
    return "SvelteKit"
  default:
    return framework
  }
}

private func vercelSourceLabel(_ source: String) -> String {
  switch source.lowercased() {
  case "cli":
    return "CLI"
  case "api-trigger-git-deploy", "git":
    return "Git"
  default:
    return source.capitalized
  }
}
