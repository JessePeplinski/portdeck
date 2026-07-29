import Combine
import Foundation
@preconcurrency import Sparkle

struct PortDeckUpdateConfiguration: Equatable {
  let releaseVersion: String
  let feedURL: URL
  let publicEDKey: String

  init?(infoDictionary: [String: Any]) {
    guard
      infoDictionary["CFBundleIdentifier"] as? String == "app.portdeck.dev",
      let releaseVersion = infoDictionary["PortDeckReleaseVersion"] as? String,
      !releaseVersion.isEmpty,
      let feedURLString = infoDictionary["SUFeedURL"] as? String,
      let feedURL = URL(string: feedURLString),
      feedURL.scheme == "https",
      let publicEDKey = infoDictionary["SUPublicEDKey"] as? String,
      !publicEDKey.isEmpty
    else {
      return nil
    }

    self.releaseVersion = releaseVersion
    self.feedURL = feedURL
    self.publicEDKey = publicEDKey
  }
}

@MainActor
final class UpdateController: NSObject, ObservableObject {
  @Published private(set) var availableVersion: String?
  @Published private(set) var canCheckForUpdates = false
  @Published private(set) var automaticallyChecksForUpdates = false

  private(set) var isEnabled: Bool
  private var updaterController: SPUStandardUpdaterController?
  private var cancellables: Set<AnyCancellable> = []

  var isUpdateAvailable: Bool {
    availableVersion != nil
  }

  init(bundle: Bundle = .main, startUpdater: Bool = true) {
    let configuration = PortDeckUpdateConfiguration(
      infoDictionary: bundle.infoDictionary ?? [:]
    )
    isEnabled = configuration != nil
    super.init()

#if DEBUG
    if let argumentIndex = ProcessInfo.processInfo.arguments.firstIndex(
      of: "--simulate-update-version"
    ),
      ProcessInfo.processInfo.arguments.indices.contains(argumentIndex + 1)
    {
      let version = ProcessInfo.processInfo.arguments[argumentIndex + 1]
      if !version.isEmpty {
        availableVersion = version
      }
    }
#endif

    guard startUpdater, configuration != nil else {
      return
    }

    let controller = SPUStandardUpdaterController(
      startingUpdater: false,
      updaterDelegate: self,
      userDriverDelegate: self
    )
    updaterController = controller

    controller.updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
      .sink { [weak self] canCheckForUpdates in
        self?.canCheckForUpdates = canCheckForUpdates
      }
      .store(in: &cancellables)

    controller.updater.publisher(for: \.automaticallyChecksForUpdates, options: [.initial, .new])
      .sink { [weak self] automaticallyChecksForUpdates in
        self?.automaticallyChecksForUpdates = automaticallyChecksForUpdates
      }
      .store(in: &cancellables)

    controller.startUpdater()
  }

  func checkForUpdates() {
    updaterController?.checkForUpdates(nil)
  }

  func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    updaterController?.updater.automaticallyChecksForUpdates = enabled
  }

  func recordAvailableUpdate(version: String) {
    availableVersion = version
  }

  func recordNoAvailableUpdate() {
    availableVersion = nil
  }
}

extension UpdateController: SPUUpdaterDelegate {
  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    recordAvailableUpdate(version: item.displayVersionString)
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
    recordNoAvailableUpdate()
  }
}

extension UpdateController: @preconcurrency SPUStandardUserDriverDelegate {
  var supportsGentleScheduledUpdateReminders: Bool {
    true
  }

  func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    false
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    guard !handleShowingUpdate else {
      return
    }
    recordAvailableUpdate(version: update.displayVersionString)
  }
}
