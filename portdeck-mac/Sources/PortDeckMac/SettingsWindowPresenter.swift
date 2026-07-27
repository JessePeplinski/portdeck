import AppKit

@MainActor
enum SettingsWindowPresenter {
  static func present(
    openSettings: () -> Void,
    activate: () -> Void = {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  ) {
    openSettings()
    activate()
  }
}
