import AppKit
import SwiftUI

enum LocalKeyboardNavigationItemKind {
  case project(id: String)
  case service(id: String)
  case unknownSection(id: String)
}

enum LocalKeyboardNavigationID {
  static func project(_ id: String) -> String { "project:\(id)" }
  static func service(_ id: String) -> String { "service:\(id)" }
  static func unknownSection(_ id: String) -> String { "unknown:\(id)" }
}

struct LocalKeyboardNavigationItem: Identifiable {
  let id: String
  let kind: LocalKeyboardNavigationItemKind
}

enum LocalKeyboardNavigation {
  static func movedSelection(
    from selectedID: String?,
    by delta: Int,
    in itemIDs: [String]
  ) -> String? {
    guard !itemIDs.isEmpty else {
      return nil
    }

    guard let selectedID, let currentIndex = itemIDs.firstIndex(of: selectedID) else {
      return delta < 0 ? itemIDs.last : itemIDs.first
    }

    let nextIndex = min(max(currentIndex + delta, 0), itemIDs.count - 1)
    return itemIDs[nextIndex]
  }
}

struct StatusKeyboardMonitor: NSViewRepresentable {
  let isActive: Bool
  let supportsLocalNavigation: Bool
  let isTextInputFocused: Bool
  let onFocusFilter: () -> Void
  let onMoveSelection: (Int) -> Void
  let onMoveIntoGroup: (Bool) -> Void
  let onRunSelection: () -> Void
  let onClearSelection: () -> Void
  let onCycleProvider: (Int) -> Void
  let onShowHelp: () -> Void

  func makeNSView(context: Context) -> NSView {
    NSView(frame: .zero)
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.isActive = isActive
    context.coordinator.supportsLocalNavigation = supportsLocalNavigation
    context.coordinator.isTextInputFocused = isTextInputFocused
    context.coordinator.onFocusFilter = onFocusFilter
    context.coordinator.onMoveSelection = onMoveSelection
    context.coordinator.onMoveIntoGroup = onMoveIntoGroup
    context.coordinator.onRunSelection = onRunSelection
    context.coordinator.onClearSelection = onClearSelection
    context.coordinator.onCycleProvider = onCycleProvider
    context.coordinator.onShowHelp = onShowHelp
    context.coordinator.installMonitor()
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.removeMonitor()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(
      isActive: isActive,
      supportsLocalNavigation: supportsLocalNavigation,
      isTextInputFocused: isTextInputFocused,
      onFocusFilter: onFocusFilter,
      onMoveSelection: onMoveSelection,
      onMoveIntoGroup: onMoveIntoGroup,
      onRunSelection: onRunSelection,
      onClearSelection: onClearSelection,
      onCycleProvider: onCycleProvider,
      onShowHelp: onShowHelp
    )
  }

  final class Coordinator {
    var isActive: Bool
    var supportsLocalNavigation: Bool
    var isTextInputFocused: Bool
    var onFocusFilter: () -> Void
    var onMoveSelection: (Int) -> Void
    var onMoveIntoGroup: (Bool) -> Void
    var onRunSelection: () -> Void
    var onClearSelection: () -> Void
    var onCycleProvider: (Int) -> Void
    var onShowHelp: () -> Void
    private var monitor: Any?

    init(
      isActive: Bool,
      supportsLocalNavigation: Bool,
      isTextInputFocused: Bool,
      onFocusFilter: @escaping () -> Void,
      onMoveSelection: @escaping (Int) -> Void,
      onMoveIntoGroup: @escaping (Bool) -> Void,
      onRunSelection: @escaping () -> Void,
      onClearSelection: @escaping () -> Void,
      onCycleProvider: @escaping (Int) -> Void,
      onShowHelp: @escaping () -> Void
    ) {
      self.isActive = isActive
      self.supportsLocalNavigation = supportsLocalNavigation
      self.isTextInputFocused = isTextInputFocused
      self.onFocusFilter = onFocusFilter
      self.onMoveSelection = onMoveSelection
      self.onMoveIntoGroup = onMoveIntoGroup
      self.onRunSelection = onRunSelection
      self.onClearSelection = onClearSelection
      self.onCycleProvider = onCycleProvider
      self.onShowHelp = onShowHelp
    }

    func installMonitor() {
      guard monitor == nil else { return }

      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, isActive else {
          return event
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.contains(.control), event.keyCode == 48 {
          onCycleProvider(modifiers.contains(.shift) ? -1 : 1)
          return nil
        }

        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
          onFocusFilter()
          return nil
        }

        guard !isTextInputFocused else {
          return event
        }

        let characters = event.charactersIgnoringModifiers ?? ""
        if modifiers.isEmpty, characters == "/" {
          onFocusFilter()
          return nil
        }
        if modifiers == .shift, (characters == "/" || characters == "?") {
          onShowHelp()
          return nil
        }
        if modifiers.isEmpty, event.keyCode == 53 {
          onClearSelection()
          return nil
        }

        guard supportsLocalNavigation, modifiers.isEmpty else {
          return event
        }

        switch event.keyCode {
        case 125:
          onMoveSelection(1)
          return nil
        case 126:
          onMoveSelection(-1)
          return nil
        case 123:
          onMoveIntoGroup(false)
          return nil
        case 124:
          onMoveIntoGroup(true)
          return nil
        case 36, 76:
          onRunSelection()
          return nil
        default:
          return event
        }
      }
    }

    func removeMonitor() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
      }
      monitor = nil
    }
  }
}
