import AppKit
import Foundation
import Testing
@testable import PortDeckMac

@Test func footerAttributionUsesTheApprovedCreatorAndSocialDestinations() {
  #expect(FooterAttribution.jesseName == "Jesse Peplinski")
  #expect(FooterAttribution.studioName == "Pep Tech Studios")
  #expect(FooterAttribution.jesseURL.absoluteString == "https://jessepeplinski.com")
  #expect(FooterAttribution.studioURL.absoluteString == "https://peptechstudios.com")
  #expect(FooterAttribution.xURL.absoluteString == "https://x.com/jessepeplinski")
  #expect(FooterAttribution.twitchURL.absoluteString == "https://www.twitch.tv/peptechdev")
  #expect(NSImage(data: Data(FooterAttribution.xIconSVG.utf8)) != nil)
  #expect(NSImage(data: Data(FooterAttribution.twitchIconSVG.utf8)) != nil)
}
