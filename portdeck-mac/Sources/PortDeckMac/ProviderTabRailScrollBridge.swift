import AppKit
import SwiftUI

@MainActor
final class ProviderTabRailScrollController: NSObject, ObservableObject {
  @Published private(set) var canScrollBackward = false
  @Published private(set) var canScrollForward = false

  private weak var scrollView: NSScrollView?
  private var dragStartOrigin: NSPoint?

  func attach(_ scrollView: NSScrollView?) {
    guard self.scrollView !== scrollView else {
      updateScrollAvailability()
      return
    }

    NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
    self.scrollView = scrollView
    dragStartOrigin = nil

    if let clipView = scrollView?.contentView {
      clipView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(scrollBoundsDidChange),
        name: NSView.boundsDidChangeNotification,
        object: clipView
      )
    }

    updateScrollAvailability()
  }

  func drag(horizontalTranslation: CGFloat) {
    guard let scrollView else { return }

    let clipView = scrollView.contentView
    let startOrigin = dragStartOrigin ?? clipView.bounds.origin
    if dragStartOrigin == nil {
      dragStartOrigin = startOrigin
    }

    var targetBounds = clipView.bounds
    targetBounds.origin = startOrigin
    targetBounds.origin.x -= horizontalTranslation

    let constrainedBounds = clipView.constrainBoundsRect(targetBounds)
    clipView.scroll(to: constrainedBounds.origin)
    scrollView.reflectScrolledClipView(clipView)
    updateScrollAvailability()
  }

  func endDragging() {
    dragStartOrigin = nil
  }

  func scrollPage(_ direction: ProviderTabRailScrollDirection, animated: Bool = true) {
    guard let scrollView else { return }

    let clipView = scrollView.contentView
    let pageDistance = max(1, clipView.bounds.width - 44)
    let offset = direction == .forward ? pageDistance : -pageDistance
    var targetBounds = clipView.bounds
    targetBounds.origin.x += offset
    let targetOrigin = clipView.constrainBoundsRect(targetBounds).origin

    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        clipView.animator().setBoundsOrigin(targetOrigin)
      }
    } else {
      clipView.scroll(to: targetOrigin)
      scrollView.reflectScrolledClipView(clipView)
      updateScrollAvailability()
    }
  }

  @objc private func scrollBoundsDidChange(_ notification: Notification) {
    updateScrollAvailability()
  }

  private func updateScrollAvailability() {
    guard let scrollView, let documentView = scrollView.documentView else {
      canScrollBackward = false
      canScrollForward = false
      return
    }

    let currentX = scrollView.contentView.bounds.minX
    let documentBounds = documentView.bounds
    let minimumX = documentBounds.minX
    let maximumX = max(minimumX, documentBounds.maxX - scrollView.contentView.bounds.width)
    canScrollBackward = currentX > minimumX + 0.5
    canScrollForward = currentX < maximumX - 0.5
  }
}

struct ProviderTabRailScrollViewResolver: NSViewRepresentable {
  let onResolve: (NSScrollView?) -> Void

  func makeNSView(context: Context) -> ResolverView {
    ResolverView(onResolve: onResolve)
  }

  func updateNSView(_ nsView: ResolverView, context: Context) {
    nsView.onResolve = onResolve
    nsView.resolveEnclosingScrollView()
  }

  static func dismantleNSView(_ nsView: ResolverView, coordinator: Void) {
    nsView.invalidate()
  }

  final class ResolverView: NSView {
    var onResolve: (NSScrollView?) -> Void
    private var isActive = true

    init(onResolve: @escaping (NSScrollView?) -> Void) {
      self.onResolve = onResolve
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      resolveEnclosingScrollView()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      resolveEnclosingScrollView()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      nil
    }

    func resolveEnclosingScrollView() {
      DispatchQueue.main.async { [weak self] in
        guard let self, isActive else { return }
        onResolve(enclosingScrollView)
      }
    }

    func invalidate() {
      isActive = false
      onResolve(nil)
      onResolve = { _ in }
    }
  }
}
