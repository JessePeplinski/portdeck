import AppKit
import PortDeckCore
import Testing
@testable import PortDeckMac

@Test @MainActor
func providerTabRailDragScrollsContinuouslyAndRespectsBoundaries() {
  let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
  scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 30))
  let controller = ProviderTabRailScrollController()
  controller.attach(scrollView)

  controller.drag(horizontalTranslation: -73.5)
  #expect(abs(scrollView.contentView.bounds.origin.x - 73.5) < 0.01)
  #expect(controller.canScrollBackward)
  #expect(controller.canScrollForward)

  controller.drag(horizontalTranslation: -1_000)
  #expect(abs(scrollView.contentView.bounds.origin.x - 400) < 0.01)
  #expect(controller.canScrollBackward)
  #expect(!controller.canScrollForward)

  controller.endDragging()
  controller.drag(horizontalTranslation: 50.25)
  #expect(abs(scrollView.contentView.bounds.origin.x - 349.75) < 0.01)
}

@Test @MainActor
func providerTabRailArrowsScrollByOverlappingViewportPages() {
  let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
  scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 30))
  let controller = ProviderTabRailScrollController()
  controller.attach(scrollView)

  #expect(!controller.canScrollBackward)
  #expect(controller.canScrollForward)

  controller.scrollPage(.forward, animated: false)
  #expect(abs(scrollView.contentView.bounds.origin.x - 56) < 0.01)

  controller.scrollPage(.backward, animated: false)
  #expect(abs(scrollView.contentView.bounds.origin.x) < 0.01)
  #expect(!controller.canScrollBackward)
}
