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

  func isVisible(_ provider: PortdeckDashboardSource) -> Bool {
    orderedProviders.contains(provider) && !hiddenProviders.contains(provider)
  }

  func canHide(_ provider: PortdeckDashboardSource) -> Bool {
    isVisible(provider) && visibleProviders.count > 1
  }

  func canMoveUp(_ provider: PortdeckDashboardSource) -> Bool {
    guard
      provider != .local,
      let index = orderedProviders.firstIndex(of: provider)
    else {
      return false
    }
    let firstMovableIndex = orderedProviders.first == .local ? 1 : 0
    return index > firstMovableIndex
  }

  func canMoveDown(_ provider: PortdeckDashboardSource) -> Bool {
    guard
      provider != .local,
      let index = orderedProviders.firstIndex(of: provider)
    else {
      return false
    }
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
    guard canMoveUp(provider), let index = orderedProviders.firstIndex(of: provider) else {
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
      canMoveDown(provider),
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

  @discardableResult
  func move(
    _ provider: PortdeckDashboardSource,
    relativeTo target: PortdeckDashboardSource,
    insertAfter: Bool
  ) -> Bool {
    guard
      provider != .local,
      provider != target,
      orderedProviders.contains(provider),
      orderedProviders.contains(target)
    else {
      return false
    }

    var updatedProviders = orderedProviders
    updatedProviders.removeAll { $0 == provider }
    guard let targetIndex = updatedProviders.firstIndex(of: target) else {
      return false
    }

    let requestedIndex = insertAfter ? targetIndex + 1 : targetIndex
    let firstMovableIndex = updatedProviders.first == .local ? 1 : 0
    let insertionIndex = max(firstMovableIndex, min(requestedIndex, updatedProviders.endIndex))
    updatedProviders.insert(provider, at: insertionIndex)

    guard updatedProviders != orderedProviders else {
      return false
    }

    orderedProviders = updatedProviders
    persist()
    return true
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

    if let localIndex = orderedProviders.firstIndex(of: .local), localIndex != orderedProviders.startIndex {
      orderedProviders.remove(at: localIndex)
      orderedProviders.insert(.local, at: orderedProviders.startIndex)
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
