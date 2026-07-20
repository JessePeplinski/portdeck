import Foundation
import PortDeckCore
import Testing
@testable import PortDeckMac

@MainActor
@Test func providerConfigurationDefaultsToEveryProviderInDefaultOrder() {
  let model = ProviderConfigurationModel(userDefaults: makeProviderDefaults())

  #expect(model.orderedProviders == [.local, .vercel, .convex, .github, .supabase, .cloudflare, .railway, .fly, .netlify])
  #expect(model.visibleProviders == [.local, .vercel, .convex, .github, .supabase, .cloudflare, .railway, .fly, .netlify])
  #expect(model.hiddenProviders.isEmpty)
  #expect(model.selectedProvider == .local)
}

@MainActor
@Test func providerConfigurationPersistsOrderAndVisibilityAcrossReloads() {
  let defaults = makeProviderDefaults()
  let model = ProviderConfigurationModel(userDefaults: defaults)

  #expect(model.moveUp(.github))
  #expect(model.moveUp(.github))
  #expect(model.setVisible(false, for: .convex))

  let reloaded = ProviderConfigurationModel(userDefaults: defaults)
  #expect(reloaded.orderedProviders == [.local, .github, .vercel, .convex, .supabase, .cloudflare, .railway, .fly, .netlify])
  #expect(reloaded.visibleProviders == [.local, .github, .vercel, .supabase, .cloudflare, .railway, .fly, .netlify])
  #expect(reloaded.hiddenProviders == [.convex])
}

@MainActor
@Test func providerConfigurationHidesAndRestoresProviders() {
  let model = ProviderConfigurationModel(userDefaults: makeProviderDefaults())

  #expect(model.setVisible(false, for: .vercel))
  #expect(!model.isVisible(.vercel))
  #expect(model.setVisible(true, for: .vercel))
  #expect(model.isVisible(.vercel))
  #expect(model.visibleProviders == ProviderConfigurationModel.defaultProviders)
}

@MainActor
@Test func providerConfigurationPreventsHidingTheFinalVisibleProvider() {
  let model = ProviderConfigurationModel(userDefaults: makeProviderDefaults())

  #expect(model.setVisible(false, for: .vercel))
  #expect(model.setVisible(false, for: .convex))
  #expect(model.setVisible(false, for: .github))
  #expect(model.setVisible(false, for: .supabase))
  #expect(model.setVisible(false, for: .cloudflare))
  #expect(model.setVisible(false, for: .railway))
  #expect(model.setVisible(false, for: .fly))
  #expect(model.setVisible(false, for: .netlify))
  #expect(!model.canHide(.local))
  #expect(!model.setVisible(false, for: .local))
  #expect(model.visibleProviders == [.local])
}

@MainActor
@Test func providerConfigurationMovesWithinBoundaries() {
  let model = ProviderConfigurationModel(userDefaults: makeProviderDefaults())

  #expect(!model.moveUp(.local))
  #expect(!model.moveDown(.netlify))
  #expect(model.moveDown(.local))
  #expect(model.orderedProviders == [.vercel, .local, .convex, .github, .supabase, .cloudflare, .railway, .fly, .netlify])
  #expect(model.moveUp(.github))
  #expect(model.orderedProviders == [.vercel, .local, .github, .convex, .supabase, .cloudflare, .railway, .fly, .netlify])
}

@MainActor
@Test func providerConfigurationFallsBackWhenSelectedProviderIsHidden() {
  let model = ProviderConfigurationModel(userDefaults: makeProviderDefaults())
  model.select(.github)

  #expect(model.setVisible(false, for: .github))
  #expect(model.selectedProvider == .local)
  #expect(model.pollingProvider == .local)
}

@MainActor
@Test func providerConfigurationRecoversMalformedAndAllHiddenPreferences() {
  let malformedDefaults = makeProviderDefaults()
  malformedDefaults.set(Data("not-json".utf8), forKey: ProviderConfigurationModel.userDefaultsKey)
  let malformed = ProviderConfigurationModel(userDefaults: malformedDefaults)
  #expect(malformed.visibleProviders == ProviderConfigurationModel.defaultProviders)

  let allHiddenDefaults = makeProviderDefaults()
  allHiddenDefaults.set(
    storedProviderData([
      ("local", false),
      ("vercel", false),
      ("convex", false),
      ("github", false),
      ("supabase", false),
      ("cloudflare", false),
      ("railway", false),
      ("fly", false),
      ("netlify", false)
    ]),
    forKey: ProviderConfigurationModel.userDefaultsKey
  )
  let allHidden = ProviderConfigurationModel(userDefaults: allHiddenDefaults)
  #expect(allHidden.visibleProviders == ProviderConfigurationModel.defaultProviders)
}

@MainActor
@Test func providerConfigurationRemovesUnknownAndDuplicateIdentifiers() throws {
  let defaults = makeProviderDefaults()
  defaults.set(
    storedProviderData([
      ("github", true),
      ("removed-provider", false),
      ("github", false),
      ("local", false),
      ("vercel", true),
      ("convex", true)
    ]),
    forKey: ProviderConfigurationModel.userDefaultsKey
  )

  let model = ProviderConfigurationModel(userDefaults: defaults)
  #expect(model.orderedProviders == [.github, .local, .vercel, .convex, .supabase, .cloudflare, .railway, .fly, .netlify])
  #expect(model.hiddenProviders == [.local])

  let canonicalData = try #require(defaults.data(forKey: ProviderConfigurationModel.userDefaultsKey))
  #expect(!String(decoding: canonicalData, as: UTF8.self).contains("removed-provider"))
}

@MainActor
@Test func providerConfigurationAppendsFutureProvidersWithoutResettingChoices() {
  let defaults = makeProviderDefaults()
  defaults.set(
    storedProviderData([
      ("convex", false),
      ("local", true),
      ("vercel", true)
    ]),
    forKey: ProviderConfigurationModel.userDefaultsKey
  )

  let model = ProviderConfigurationModel(userDefaults: defaults)
  #expect(model.orderedProviders == [.convex, .local, .vercel, .github, .supabase, .cloudflare, .railway, .fly, .netlify])
  #expect(model.hiddenProviders == [.convex])
  #expect(model.isVisible(.github))
  #expect(model.isVisible(.supabase))
  #expect(model.isVisible(.cloudflare))
  #expect(model.isVisible(.railway))
  #expect(model.isVisible(.fly))
  #expect(model.isVisible(.netlify))
}

@MainActor
@Test func providerConfigurationOutputsVisibleProvidersInPersistedOrder() {
  let model = ProviderConfigurationModel(userDefaults: makeProviderDefaults())

  #expect(model.moveUp(.github))
  #expect(model.moveUp(.github))
  #expect(model.moveUp(.github))
  #expect(model.setVisible(false, for: .convex))
  #expect(model.visibleProviders == [.github, .local, .vercel, .supabase, .cloudflare, .railway, .fly, .netlify])
}

@MainActor
@Test func hiddenProvidersCannotBecomePollingTargetsAndLocalIsSelectedOnly() {
  let model = ProviderConfigurationModel(userDefaults: makeProviderDefaults())
  #expect(model.shouldPoll(.local))

  #expect(model.setVisible(false, for: .local))
  #expect(!model.shouldPoll(.local))
  #expect(model.shouldPoll(.vercel))

  model.select(.local)
  #expect(model.selectedProvider == .vercel)
  #expect(!model.shouldPoll(.local))

  model.select(.supabase)
  #expect(model.shouldPoll(.supabase))
  #expect(model.setVisible(false, for: .supabase))
  #expect(!model.shouldPoll(.supabase))

  model.select(.cloudflare)
  #expect(model.shouldPoll(.cloudflare))
  #expect(model.setVisible(false, for: .cloudflare))
  #expect(!model.shouldPoll(.cloudflare))

  model.select(.railway)
  #expect(model.shouldPoll(.railway))
  #expect(model.setVisible(false, for: .railway))
  #expect(!model.shouldPoll(.railway))

  model.select(.fly)
  #expect(model.shouldPoll(.fly))
  #expect(model.setVisible(false, for: .fly))
  #expect(!model.shouldPoll(.fly))

  model.select(.netlify)
  #expect(model.shouldPoll(.netlify))
  #expect(model.setVisible(false, for: .netlify))
  #expect(!model.shouldPoll(.netlify))
}

@MainActor
@Test func reorderingPreservesPollingSelectionAndProviderModelIdentity() {
  let configuration = ProviderConfigurationModel(userDefaults: makeProviderDefaults())
  let providerModel = NetlifyStatusModel()
  let providerIdentity = ObjectIdentifier(providerModel)
  let snapshotCount = providerModel.sites.count

  configuration.select(.netlify)
  #expect(configuration.moveDown(.local))

  #expect(configuration.pollingProvider == .netlify)
  #expect(ObjectIdentifier(providerModel) == providerIdentity)
  #expect(providerModel.sites.count == snapshotCount)
}

private func makeProviderDefaults() -> UserDefaults {
  let suiteName = "ProviderConfigurationModelTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defaults.removePersistentDomain(forName: suiteName)
  return defaults
}

private func storedProviderData(_ providers: [(String, Bool)]) -> Data {
  let entries = providers.map { identifier, isVisible in
    "{\"identifier\":\"\(identifier)\",\"isVisible\":\(isVisible)}"
  }
  return Data("{\"providers\":[\(entries.joined(separator: ","))]}".utf8)
}
