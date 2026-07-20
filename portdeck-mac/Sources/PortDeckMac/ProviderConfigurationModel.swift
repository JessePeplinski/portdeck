import Combine
import Foundation
import PortDeckCore

@MainActor
final class ProviderConfigurationModel: ObservableObject {
  static let userDefaultsKey = "providerConfiguration"
  static let defaultProviders = PortdeckDashboardSource.allCases

  @Published private(set) var orderedProviders: [PortdeckDashboardSource]
  @Published private(set) var hiddenProviders: Set<PortdeckDashboardSource>
  @Published private(set) var selectedProvider: PortdeckDashboardSource

  private let userDefaults: UserDefaults

  init(
    userDefaults: UserDefaults = .standard,
    availableProviders: [PortdeckDashboardSource] = ProviderConfigurationModel.defaultProviders,
    selectedProvider: PortdeckDashboardSource = .local
  ) {
    precondition(!availableProviders.isEmpty, "PortDeck requires at least one provider")

    self.userDefaults = userDefaults

    let configuration = Self.loadConfiguration(
      from: userDefaults,
      availableProviders: availableProviders
    )
    orderedProviders = configuration.orderedProviders
    hiddenProviders = configuration.hiddenProviders
    self.selectedProvider = configuration.orderedProviders.contains(selectedProvider)
      && !configuration.hiddenProviders.contains(selectedProvider)
      ? selectedProvider
      : configuration.orderedProviders.first { !configuration.hiddenProviders.contains($0) }!

    persist()
  }

  var visibleProviders: [PortdeckDashboardSource] {
    orderedProviders.filter { !hiddenProviders.contains($0) }
  }

  var pollingProvider: PortdeckDashboardSource? {
    isVisible(selectedProvider) ? selectedProvider : nil
  }

  func isVisible(_ provider: PortdeckDashboardSource) -> Bool {
    orderedProviders.contains(provider) && !hiddenProviders.contains(provider)
  }

  func canHide(_ provider: PortdeckDashboardSource) -> Bool {
    isVisible(provider) && visibleProviders.count > 1
  }

  func canMoveUp(_ provider: PortdeckDashboardSource) -> Bool {
    guard let index = orderedProviders.firstIndex(of: provider) else { return false }
    return index > orderedProviders.startIndex
  }

  func canMoveDown(_ provider: PortdeckDashboardSource) -> Bool {
    guard let index = orderedProviders.firstIndex(of: provider) else { return false }
    return index < orderedProviders.index(before: orderedProviders.endIndex)
  }

  func select(_ provider: PortdeckDashboardSource) {
    guard isVisible(provider) else { return }
    selectedProvider = provider
  }

  @discardableResult
  func setVisible(_ isVisible: Bool, for provider: PortdeckDashboardSource) -> Bool {
    guard orderedProviders.contains(provider) else { return false }

    var updatedHiddenProviders = hiddenProviders
    if isVisible {
      guard updatedHiddenProviders.remove(provider) != nil else { return false }
    } else {
      guard canHide(provider) else { return false }
      updatedHiddenProviders.insert(provider)
    }

    hiddenProviders = updatedHiddenProviders
    if !isVisible && selectedProvider == provider {
      selectedProvider = visibleProviders[0]
    }
    persist()
    return true
  }

  @discardableResult
  func moveUp(_ provider: PortdeckDashboardSource) -> Bool {
    guard let index = orderedProviders.firstIndex(of: provider), index > orderedProviders.startIndex else {
      return false
    }

    var updatedProviders = orderedProviders
    updatedProviders.swapAt(index, updatedProviders.index(before: index))
    orderedProviders = updatedProviders
    persist()
    return true
  }

  @discardableResult
  func moveDown(_ provider: PortdeckDashboardSource) -> Bool {
    guard
      let index = orderedProviders.firstIndex(of: provider),
      index < orderedProviders.index(before: orderedProviders.endIndex)
    else {
      return false
    }

    var updatedProviders = orderedProviders
    updatedProviders.swapAt(index, updatedProviders.index(after: index))
    orderedProviders = updatedProviders
    persist()
    return true
  }

  func shouldPoll(_ provider: PortdeckDashboardSource) -> Bool {
    pollingProvider == provider
  }

  private func persist() {
    let storedConfiguration = StoredConfiguration(
      providers: orderedProviders.map { provider in
        StoredProvider(identifier: provider.rawValue, isVisible: !hiddenProviders.contains(provider))
      }
    )

    guard let data = try? JSONEncoder().encode(storedConfiguration) else { return }
    userDefaults.set(data, forKey: Self.userDefaultsKey)
  }

  private static func loadConfiguration(
    from userDefaults: UserDefaults,
    availableProviders: [PortdeckDashboardSource]
  ) -> Configuration {
    let defaultConfiguration = Configuration(
      orderedProviders: availableProviders,
      hiddenProviders: []
    )

    guard userDefaults.object(forKey: userDefaultsKey) != nil else {
      return defaultConfiguration
    }
    guard
      let data = userDefaults.data(forKey: userDefaultsKey),
      let storedConfiguration = try? JSONDecoder().decode(StoredConfiguration.self, from: data)
    else {
      return defaultConfiguration
    }

    let availableProviderSet = Set(availableProviders)
    var seenProviders: Set<PortdeckDashboardSource> = []
    var orderedProviders: [PortdeckDashboardSource] = []
    var hiddenProviders: Set<PortdeckDashboardSource> = []

    for storedProvider in storedConfiguration.providers {
      guard
        let provider = PortdeckDashboardSource(rawValue: storedProvider.identifier),
        availableProviderSet.contains(provider),
        seenProviders.insert(provider).inserted
      else {
        continue
      }

      orderedProviders.append(provider)
      if !storedProvider.isVisible {
        hiddenProviders.insert(provider)
      }
    }

    for provider in availableProviders where seenProviders.insert(provider).inserted {
      orderedProviders.append(provider)
    }

    guard !orderedProviders.isEmpty, hiddenProviders.count < orderedProviders.count else {
      return defaultConfiguration
    }

    return Configuration(
      orderedProviders: orderedProviders,
      hiddenProviders: hiddenProviders
    )
  }
}

private extension ProviderConfigurationModel {
  struct Configuration {
    let orderedProviders: [PortdeckDashboardSource]
    let hiddenProviders: Set<PortdeckDashboardSource>
  }

  struct StoredConfiguration: Codable {
    let providers: [StoredProvider]
  }

  struct StoredProvider: Codable {
    let identifier: String
    let isVisible: Bool
  }
}
