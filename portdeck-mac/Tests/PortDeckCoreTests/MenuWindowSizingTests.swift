import Testing
@testable import PortDeckMac

@Test func menuWindowSizingCapsLargeDisplaysAtThePreferredHeight() {
  #expect(MenuWindowSizing.height(availableHeight: 2_160) == 700)
}

@Test func menuWindowSizingLeavesRoomOnSmallerDisplays() {
  #expect(MenuWindowSizing.height(availableHeight: 650) == 626)
}

@Test func menuWindowSizingUsesTheEstablishedFallbackWithoutScreenInformation() {
  #expect(MenuWindowSizing.height(availableHeight: nil) == 560)
}
