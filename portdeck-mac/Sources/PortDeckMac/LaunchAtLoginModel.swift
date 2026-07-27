import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
  case notRegistered
  case enabled
  case requiresApproval
  case notFound
}

protocol LaunchAtLoginServicing {
  var status: LaunchAtLoginStatus { get }

  func register() throws
  func unregister() throws
  func openSystemSettings()
}

struct MainAppLaunchAtLoginService: LaunchAtLoginServicing {
  var status: LaunchAtLoginStatus {
    switch SMAppService.mainApp.status {
    case .notRegistered:
      .notRegistered
    case .enabled:
      .enabled
    case .requiresApproval:
      .requiresApproval
    case .notFound:
      .notFound
    @unknown default:
      .notFound
    }
  }

  func register() throws {
    try SMAppService.mainApp.register()
  }

  func unregister() throws {
    try SMAppService.mainApp.unregister()
  }

  func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}

@MainActor
final class LaunchAtLoginModel: ObservableObject {
  @Published private(set) var status: LaunchAtLoginStatus
  @Published private(set) var errorMessage: String?

  private let service: any LaunchAtLoginServicing

  init(service: any LaunchAtLoginServicing = MainAppLaunchAtLoginService()) {
    self.service = service
    status = service.status
  }

  var isEnabled: Bool {
    status == .enabled
  }

  var requiresApproval: Bool {
    status == .requiresApproval
  }

  var requiresManualSetup: Bool {
    status == .notFound
  }

  func refresh() {
    status = service.status
  }

  func setEnabled(_ enabled: Bool) {
    errorMessage = nil

    do {
      if enabled {
        if status == .requiresApproval || status == .notFound {
          service.openSystemSettings()
        } else if status != .enabled {
          try service.register()
        }
      } else if status == .enabled {
        try service.unregister()
      }
    } catch {
      errorMessage = error.localizedDescription
    }

    refresh()
  }

  func openSystemSettings() {
    service.openSystemSettings()
  }
}
