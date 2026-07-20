import AppKit
import PortDeckCore
import SwiftUI

struct GitHubStatusView: View {
  @ObservedObject var model: GitHubStatusModel
  let searchText: String
  let onRefresh: () -> Void

  var body: some View {
    if model.candidates.isEmpty {
      emptyState(
        systemImage: "arrow.triangle.branch",
        title: "No active GitHub repositories",
        detail: "Start a local service from a project with a supported GitHub remote to see its default-branch CI here."
      )
    } else if model.repositories.isEmpty && model.isRefreshing {
      loadingState(title: "Checking GitHub Actions health")
    } else if model.repositories.isEmpty {
      setupOrFailureState
    } else {
      connectedContent
    }
  }

  @ViewBuilder
  private var setupOrFailureState: some View {
    switch model.connectionState {
    case .missingCLI:
      setupState(
        systemImage: "terminal",
        title: "GitHub CLI required",
        detail: "Install GitHub CLI and sign in once. PortDeck reuses that authenticated session without copying its token.",
        primaryTitle: "Open GitHub CLI guide",
        primarySystemImage: "arrow.up.forward.square",
        primaryAction: openGitHubCLIDocumentation
      )
    case .unauthenticated:
      setupState(
        systemImage: "person.crop.circle.badge.exclamationmark",
        title: "GitHub authentication required",
        detail: "Sign in from Terminal. PortDeck does not provide an in-app login or receive your GitHub token.",
        primaryTitle: "Copy login command",
        primarySystemImage: "doc.on.doc",
        primaryAction: { copyCommand(GitHubCLIClient.loginCommand) },
        command: GitHubCLIClient.loginCommand
      )
    case .failed(let message):
      setupState(
        systemImage: "exclamationmark.triangle",
        title: "GitHub Actions unavailable",
        detail: message,
        primaryTitle: "Try again",
        primarySystemImage: "arrow.clockwise",
        primaryAction: onRefresh
      )
    case .rateLimited(_, let message):
      setupState(
        systemImage: "clock.badge.exclamationmark",
        title: "GitHub rate limit reached",
        detail: message,
        primaryTitle: "Try again when ready",
        primarySystemImage: "arrow.clockwise",
        primaryAction: onRefresh
      )
    case .checking, .connected:
      if let message = model.errorMessage {
        setupState(
          systemImage: "exclamationmark.triangle",
          title: "GitHub Actions unavailable",
          detail: message,
          primaryTitle: "Try again",
          primarySystemImage: "arrow.clockwise",
          primaryAction: onRefresh
        )
      } else {
        loadingState(title: "Checking GitHub Actions health")
      }
    }
  }

  @ViewBuilder
  private var connectedContent: some View {
    if let errorMessage = model.errorMessage {
      GitHubInlineWarning(message: errorMessage)
    }

    HStack {
      Label("Default branch CI", systemImage: "checkmark.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      if let lastUpdated = model.lastSuccessfulRefreshAt {
        GitHubPollingStatus(lastUpdated: lastUpdated, hasError: model.errorMessage != nil)
      } else {
        Text("Every \(GitHubStatusModel.refreshIntervalSeconds)s")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 2)

    let filtered = model.filteredRepositories(matching: searchText)
    if filtered.isEmpty {
      emptyState(
        systemImage: "magnifyingglass",
        title: "No matching GitHub repositories",
        detail: "Clear the search to see every active repository."
      )
    } else {
      ForEach(filtered) { repository in
        GitHubRepositoryRow(repository: repository)
      }
    }
  }

  private func loadingState(title: String) -> some View {
    VStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text(title)
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
    primaryTitle: String,
    primarySystemImage: String,
    primaryAction: @escaping () -> Void,
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

      Button(action: primaryAction) {
        Label(primaryTitle, systemImage: primarySystemImage)
      }
      .buttonStyle(.borderedProminent)
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

  private func openGitHubCLIDocumentation() {
    guard let url = URL(string: "https://cli.github.com/") else { return }
    NSWorkspace.shared.open(url)
  }

  private func copyCommand(_ command: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
  }
}

private struct GitHubInlineWarning: View {
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 7) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(9)
    .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct GitHubPollingStatus: View {
  let lastUpdated: Date
  let hasError: Bool

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let age = githubPollingAgeSeconds(lastUpdated: lastUpdated, relativeTo: context.date)
      HStack(spacing: 4) {
        Circle()
          .fill(hasError ? Color.orange : Color.green)
          .frame(width: 6, height: 6)
        Text(githubLastCheckedLabel(ageSeconds: age))
          .font(.caption)
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "GitHub Actions checks every \(GitHubStatusModel.refreshIntervalSeconds) seconds. Last successful check \(age) seconds ago."
      )
      .help("GitHub Actions checks every \(GitHubStatusModel.refreshIntervalSeconds) seconds while this tab is open.")
    }
  }
}

private struct GitHubRepositoryRow: View {
  let repository: GitHubRepositoryStatus

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        Circle()
          .fill(statusColor)
          .frame(width: 7, height: 7)
        Text(repository.candidate.displayProjectName)
          .font(.callout)
          .fontWeight(.semibold)
          .lineLimit(1)
        Spacer()
        Text(repository.healthState.title)
          .font(.caption2)
          .fontWeight(.semibold)
          .foregroundStyle(statusColor)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(statusColor.opacity(0.12), in: Capsule())
      }

      HStack(spacing: 7) {
        Text(repository.candidate.fullName)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        if let defaultBranch = repository.defaultBranch {
          Label(defaultBranch, systemImage: "arrow.triangle.branch")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }

      if let message = repository.message {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }

      if repository.hasWorkflowSnapshot && repository.workflows.isEmpty {
        HStack(spacing: 7) {
          Image(systemName: "checkmark.circle")
            .foregroundStyle(.secondary)
          Text("No default-branch workflow runs")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
      } else if !repository.hasWorkflowSnapshot {
        Text("Workflow health unavailable")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 6) {
          ForEach(repository.displayWorkflows) { workflow in
            GitHubWorkflowRow(workflow: workflow)
          }
        }
      }
    }
    .padding(12)
    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary.opacity(0.9)))
  }

  private var statusColor: Color {
    switch repository.healthState {
    case .failed: return .red
    case .running: return .blue
    case .warning: return .orange
    case .passing: return .green
    case .unknown, .noRuns: return .secondary
    }
  }
}

private struct GitHubWorkflowRow: View {
  let workflow: GitHubWorkflowRun

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(statusColor)
        .frame(width: 6, height: 6)
        .padding(.top, 5)

      VStack(alignment: .leading, spacing: 2) {
        Text(workflow.displayName)
          .font(.caption)
          .fontWeight(.semibold)
          .lineLimit(1)
        if let displayTitle = workflow.displayTitle, !displayTitle.isEmpty {
          Text(displayTitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Text(workflowDetailLabel(workflow))
          .font(.caption2.monospaced())
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }

      Spacer(minLength: 6)

      VStack(alignment: .trailing, spacing: 3) {
        Text(workflow.healthState.title)
          .font(.caption2)
          .fontWeight(.semibold)
          .foregroundStyle(statusColor)
        if let activityDate = workflow.activityDate {
          Text(githubRelativeText(for: activityDate))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }

      if let url = workflow.htmlURL {
        Button {
          NSWorkspace.shared.open(url)
        } label: {
          Image(systemName: "arrow.up.forward.square.fill")
            .foregroundStyle(.purple)
        }
        .buttonStyle(.plain)
        .help("Open workflow run on GitHub")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .background(.quaternary.opacity(0.48), in: RoundedRectangle(cornerRadius: 7))
  }

  private var statusColor: Color {
    switch workflow.healthState {
    case .running: return .blue
    case .failed: return .red
    case .warning: return .orange
    case .passing: return .green
    case .unknown: return .secondary
    }
  }
}

func githubPollingAgeSeconds(lastUpdated: Date, relativeTo now: Date) -> Int {
  max(0, Int(now.timeIntervalSince(lastUpdated)))
}

func githubLastCheckedLabel(ageSeconds: Int) -> String {
  "Checked \(max(0, ageSeconds))s ago · every \(GitHubStatusModel.refreshIntervalSeconds)s"
}

func workflowDetailLabel(_ workflow: GitHubWorkflowRun) -> String {
  var parts: [String] = []
  if let event = workflow.event, !event.isEmpty { parts.append(event) }
  if let runNumber = workflow.runNumber { parts.append("#\(runNumber)") }
  parts.append(workflow.status?.lowercased() ?? "unknown")
  if let conclusion = workflow.conclusion, !conclusion.isEmpty {
    parts.append(conclusion.lowercased())
  }
  return parts.joined(separator: " · ")
}

private func githubRelativeText(for date: Date) -> String {
  let formatter = RelativeDateTimeFormatter()
  formatter.unitsStyle = .abbreviated
  return formatter.localizedString(for: date, relativeTo: Date())
}
