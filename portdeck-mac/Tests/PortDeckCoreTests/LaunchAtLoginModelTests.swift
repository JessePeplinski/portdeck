import Foundation
import Testing
@testable import PortDeckMac

@MainActor
@Test func launchAtLoginReflectsTheCurrentServiceStatus() {
  let enabledService = LaunchAtLoginServiceStub(status: .enabled)
  let enabledModel = LaunchAtLoginModel(service: enabledService)
  #expect(enabledModel.isEnabled)
  #expect(!enabledModel.requiresManualSetup)

  let missingService = LaunchAtLoginServiceStub(status: .notFound)
  let missingModel = LaunchAtLoginModel(service: missingService)
  #expect(!missingModel.isEnabled)
  #expect(missingModel.requiresManualSetup)
}

@MainActor
@Test func launchAtLoginRegistersAndUnregistersTheMainApp() {
  let service = LaunchAtLoginServiceStub(status: .notRegistered)
  let model = LaunchAtLoginModel(service: service)

  model.setEnabled(true)
  #expect(service.registerCallCount == 1)
  #expect(model.isEnabled)

  model.setEnabled(false)
  #expect(service.unregisterCallCount == 1)
  #expect(!model.isEnabled)
}

@MainActor
@Test func launchAtLoginSendsApprovalRequestsToSystemSettings() {
  let service = LaunchAtLoginServiceStub(status: .requiresApproval)
  let model = LaunchAtLoginModel(service: service)

  model.setEnabled(true)
  #expect(service.registerCallCount == 0)
  #expect(service.openSystemSettingsCallCount == 1)
  #expect(model.requiresApproval)
}

@MainActor
@Test func launchAtLoginSendsManualSetupRequestsToSystemSettings() {
  let service = LaunchAtLoginServiceStub(status: .notFound)
  let model = LaunchAtLoginModel(service: service)

  model.setEnabled(true)

  #expect(service.registerCallCount == 0)
  #expect(service.openSystemSettingsCallCount == 1)
  #expect(model.requiresManualSetup)
}

@MainActor
@Test func launchAtLoginSurfacesRegistrationFailures() {
  let service = LaunchAtLoginServiceStub(status: .notRegistered)
  service.registerError = LaunchAtLoginTestError.registrationFailed
  let model = LaunchAtLoginModel(service: service)

  model.setEnabled(true)

  #expect(model.errorMessage == "Registration failed")
  #expect(!model.isEnabled)
}

@MainActor
@Test func settingsWindowPresenterOpensThenActivatesTheApp() {
  var events: [String] = []

  SettingsWindowPresenter.present(
    openSettings: {
      events.append("open")
    },
    activate: {
      events.append("activate")
    }
  )

  #expect(events == ["open", "activate"])
}

private enum LaunchAtLoginTestError: LocalizedError {
  case registrationFailed

  var errorDescription: String? {
    "Registration failed"
  }
}

private final class LaunchAtLoginServiceStub: LaunchAtLoginServicing {
  var status: LaunchAtLoginStatus
  var registerError: Error?
  var unregisterError: Error?
  private(set) var registerCallCount = 0
  private(set) var unregisterCallCount = 0
  private(set) var openSystemSettingsCallCount = 0

  init(status: LaunchAtLoginStatus) {
    self.status = status
  }

  func register() throws {
    registerCallCount += 1
    if let registerError {
      throw registerError
    }
    status = .enabled
  }

  func unregister() throws {
    unregisterCallCount += 1
    if let unregisterError {
      throw unregisterError
    }
    status = .notRegistered
  }

  func openSystemSettings() {
    openSystemSettingsCallCount += 1
  }
}
