import Foundation
import Testing
@testable import PortDeckMac

@Test func versionInfoPrefersTheReleaseVersionUsedBySparkle() {
  let version = PortDeckVersionInfo(infoDictionary: [
    "PortDeckReleaseVersion": "0.1.0-beta.14",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "14"
  ])

  #expect(version.displayVersion == "0.1.0-beta.14")
}

@Test func versionInfoFallsBackForSourceAndIncompleteBundles() {
  #expect(PortDeckVersionInfo(infoDictionary: [
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "14"
  ]).displayVersion == "0.1.0")
  #expect(PortDeckVersionInfo(infoDictionary: [
    "CFBundleVersion": "14"
  ]).displayVersion == "14")
  #expect(PortDeckVersionInfo(infoDictionary: [:]).displayVersion == "Unknown")
}

@MainActor
@Test func updaterStartsOnlyForConfiguredProductionReleases() {
  let productionInfo: [String: Any] = [
    "CFBundleIdentifier": "app.portdeck.dev",
    "PortDeckReleaseVersion": "0.1.0-beta.13",
    "SUFeedURL": "https://portdeck.vercel.app/appcast-beta.xml",
    "SUPublicEDKey": "public-key"
  ]

  #expect(PortDeckUpdateConfiguration(infoDictionary: productionInfo) != nil)
  #expect(PortDeckUpdateConfiguration(infoDictionary: [
    "CFBundleIdentifier": "app.portdeck.dev.development",
    "PortDeckReleaseVersion": "0.1.0-beta.13",
    "SUFeedURL": "https://portdeck.vercel.app/appcast-beta.xml",
    "SUPublicEDKey": "public-key"
  ]) == nil)
  #expect(PortDeckUpdateConfiguration(infoDictionary: [
    "CFBundleIdentifier": "app.portdeck.dev"
  ]) == nil)
}

@MainActor
@Test func updaterPublishesAndClearsAvailableVersions() {
  let model = UpdateController(startUpdater: false)

  model.recordAvailableUpdate(version: "0.1.0-beta.14")
  #expect(model.availableVersion == "0.1.0-beta.14")
  #expect(model.isUpdateAvailable)

  model.recordNoAvailableUpdate()
  #expect(model.availableVersion == nil)
  #expect(!model.isUpdateAvailable)
}
