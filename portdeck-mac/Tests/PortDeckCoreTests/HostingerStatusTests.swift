import Foundation
import Testing
@testable import PortDeckCore

@Test func mapsHostingerWebsiteStateWithoutClaimingRuntimeHealth() {
  #expect(hostingerWebsite(domain: "enabled.example", isEnabled: true).state == .enabled)
  #expect(hostingerWebsite(domain: "disabled.example", isEnabled: false).state == .disabled)
  #expect(hostingerWebsite(domain: "unknown.example", isEnabled: nil).state == .unknown)
  #expect(HostingerWebsiteState.enabled.title == "Enabled")
}

@Test func sortsHostingerProblemsFirstAndSearchesRenderedFields() {
  let websites = HostingerStatusBuilder.sortedWebsites([
    hostingerWebsite(domain: "healthy.example", isEnabled: true, orderID: 30),
    hostingerWebsite(domain: "unknown.example", isEnabled: nil, orderID: 20, vhostType: "addon"),
    hostingerWebsite(domain: "disabled.example", isEnabled: false, orderID: 10)
  ])

  #expect(websites.map(\.domain) == ["disabled.example", "unknown.example", "healthy.example"])
  #expect(websites.filter { $0.matchesSearch("addon") }.map(\.domain) == ["unknown.example"])
  #expect(websites.filter { $0.matchesSearch("10") }.map(\.domain) == ["disabled.example"])
  #expect(websites.allSatisfy { $0.matchesSearch("") })
}

@Test func permitsOnlySafeHTTPSHostingerWebsiteLinks() {
  #expect(HostingerSafeLink.publicWebsiteURL(domain: "example.com")?.absoluteString == "https://example.com")
  #expect(HostingerSafeLink.publicWebsiteURL(domain: "sub.example.com")?.absoluteString == "https://sub.example.com")
  #expect(HostingerSafeLink.publicWebsiteURL(domain: "https://evil.example") == nil)
  #expect(HostingerSafeLink.publicWebsiteURL(domain: "user@example.com") == nil)
  #expect(HostingerSafeLink.publicWebsiteURL(domain: "example.com/path") == nil)
  #expect(HostingerSafeLink.publicWebsiteURL(domain: "example.com\n.evil") == nil)
  #expect(HostingerSafeLink.websitesDashboardURL.absoluteString == "https://hpanel.hostinger.com/websites")
}

private func hostingerWebsite(
  domain: String,
  isEnabled: Bool?,
  orderID: Int = 1,
  vhostType: String? = nil
) -> HostingerWebsite {
  HostingerWebsite(
    domain: domain,
    isEnabled: isEnabled,
    orderID: orderID,
    parentDomain: "example.com",
    vhostType: vhostType
  )
}
