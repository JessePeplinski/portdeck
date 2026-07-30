import SwiftUI

struct PortDeckKeyboardShortcut: Identifiable, Equatable {
  let id: String
  let keys: String
  let title: String
  let detail: String

  init(keys: String, title: String, detail: String) {
    self.id = "\(keys)-\(title)"
    self.keys = keys
    self.title = title
    self.detail = detail
  }
}

struct PortDeckKeyboardShortcutSection: Identifiable, Equatable {
  let title: String
  let shortcuts: [PortDeckKeyboardShortcut]

  var id: String { title }
}

enum PortDeckKeyboardShortcuts {
  static let sections = [
    PortDeckKeyboardShortcutSection(
      title: "Find and navigate",
      shortcuts: [
        PortDeckKeyboardShortcut(
          keys: "/ or ⌘ F",
          title: "Filter the current view",
          detail: "Move directly to the visible provider’s filter."
        ),
        PortDeckKeyboardShortcut(
          keys: "↑  ↓",
          title: "Move through Local",
          detail: "Select the previous or next visible project, section, or service."
        ),
        PortDeckKeyboardShortcut(
          keys: "←  →",
          title: "Collapse or expand",
          detail: "Close or open the selected Local project or unknown-services section."
        ),
        PortDeckKeyboardShortcut(
          keys: "Return",
          title: "Use the selection",
          detail: "Toggle a selected group or open a selected service’s local endpoint."
        ),
        PortDeckKeyboardShortcut(
          keys: "Escape",
          title: "Leave keyboard navigation",
          detail: "Leave the filter first, or clear the current Local selection."
        )
      ]
    ),
    PortDeckKeyboardShortcutSection(
      title: "Commands and providers",
      shortcuts: [
        PortDeckKeyboardShortcut(
          keys: "⌘ K",
          title: "Open the action palette",
          detail: "Find service, project, provider, refresh, and diagnostic actions."
        ),
        PortDeckKeyboardShortcut(
          keys: "⌘ R",
          title: "Refresh the current view",
          detail: "Reload Local or the selected deployment provider."
        ),
        PortDeckKeyboardShortcut(
          keys: "⌘ 1–9",
          title: "Jump to a provider",
          detail: "Select a visible provider by its position in the provider rail."
        ),
        PortDeckKeyboardShortcut(
          keys: "⌃ Tab",
          title: "Cycle providers",
          detail: "Move to the next provider. Add Shift to move to the previous provider."
        ),
        PortDeckKeyboardShortcut(
          keys: "?",
          title: "Show keyboard shortcuts",
          detail: "Open this reference whenever a text field is not active."
        )
      ]
    )
  ]
}

struct KeyboardShortcutsOverlay: View {
  let onDismiss: () -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.24)
        .ignoresSafeArea()
        .onTapGesture(perform: onDismiss)

      VStack(spacing: 0) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Keyboard Shortcuts")
              .font(.headline)
            Text("Navigate PortDeck without leaving the keyboard.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer()

          Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
              .font(.title3)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .keyboardShortcut(.cancelAction)
          .accessibilityLabel("Close keyboard shortcuts")
          .help("Close keyboard shortcuts")
        }
        .padding(14)

        Divider()

        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            ForEach(PortDeckKeyboardShortcuts.sections) { section in
              VStack(alignment: .leading, spacing: 7) {
                Text(section.title.uppercased())
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                  ForEach(Array(section.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                    if index > 0 {
                      Divider()
                    }
                    KeyboardShortcutHelpRow(shortcut: shortcut)
                  }
                }
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                  RoundedRectangle(cornerRadius: 9)
                    .stroke(.quaternary.opacity(0.85))
                }
              }
            }
          }
          .padding(14)
        }
        .frame(maxHeight: 430)
      }
      .frame(width: 430)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(.white.opacity(0.16), lineWidth: 1)
      }
      .shadow(color: .black.opacity(0.30), radius: 24, y: 12)
      .padding()
    }
  }
}

private struct KeyboardShortcutHelpRow: View {
  let shortcut: PortDeckKeyboardShortcut

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Text(shortcut.keys)
        .font(.caption.monospaced().weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 72, alignment: .trailing)

      VStack(alignment: .leading, spacing: 2) {
        Text(shortcut.title)
          .font(.callout.weight(.semibold))
        Text(shortcut.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(shortcut.keys), \(shortcut.title). \(shortcut.detail)")
  }
}

struct LocalKeyboardShortcutStrip: View {
  var body: some View {
    HStack(spacing: 12) {
      shortcut("↑↓", "Navigate")
      shortcut("←→", "Expand")
      shortcut("↩", "Open")
      shortcut("⌘K", "Actions")
      shortcut("/", "Filter")
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Keyboard navigation active. Arrow keys navigate and expand. Return opens. Command K shows actions. Slash filters.")
  }

  private func shortcut(_ keys: String, _ title: String) -> some View {
    HStack(spacing: 3) {
      Text(keys)
        .font(.caption2.monospaced().weight(.semibold))
      Text(title)
    }
  }
}
