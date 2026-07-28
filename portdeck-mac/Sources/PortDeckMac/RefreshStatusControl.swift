import SwiftUI

struct RefreshStatusControl: View {
  let sourceName: String
  let lastUpdated: Date?
  let isRefreshing: Bool
  let hasError: Bool
  var showsRefreshButton = true
  let onRefresh: () -> Void

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      HStack(spacing: 6) {
        HStack(spacing: 4) {
          Circle()
            .fill(statusColor)
            .frame(width: 6, height: 6)
          Text(statusLabel(relativeTo: context.date))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(statusAccessibilityLabel(relativeTo: context.date))

        if showsRefreshButton {
          Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise")
              .font(.caption.weight(.semibold))
              .frame(width: 20, height: 20)
              .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
          }
          .buttonStyle(.plain)
          .keyboardShortcut("r", modifiers: [])
          .disabled(isRefreshing)
          .accessibilityLabel("Refresh \(sourceName)")
          .help("Refresh \(sourceName)")
        }
      }
    }
  }

  private var statusColor: Color {
    if hasError {
      return .orange
    }
    return lastUpdated == nil ? .secondary : .green
  }

  private func statusLabel(relativeTo now: Date) -> String {
    guard let lastUpdated else {
      return isRefreshing ? "Checking…" : "Not checked"
    }
    return refreshLastCheckedLabel(
      ageSeconds: refreshAgeSeconds(lastUpdated: lastUpdated, relativeTo: now)
    )
  }

  private func statusAccessibilityLabel(relativeTo now: Date) -> String {
    guard let lastUpdated else {
      return isRefreshing
        ? "\(sourceName) status is being checked."
        : "\(sourceName) status has not been checked."
    }
    let age = refreshAgeSeconds(lastUpdated: lastUpdated, relativeTo: now)
    return "\(sourceName) last successful check was \(age) seconds ago."
  }
}

func refreshAgeSeconds(lastUpdated: Date, relativeTo now: Date) -> Int {
  max(0, Int(now.timeIntervalSince(lastUpdated)))
}

func refreshLastCheckedLabel(ageSeconds: Int) -> String {
  "Checked \(max(0, ageSeconds))s ago"
}
