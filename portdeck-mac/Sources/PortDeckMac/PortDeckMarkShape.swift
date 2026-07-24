import AppKit
import SwiftUI

struct PortDeckMarkShape: Shape {
  private static let sourceOrigin = CGPoint(x: 96, y: 324)
  private static let sourceSize = CGSize(width: 832, height: 376)

  func path(in rect: CGRect) -> Path {
    let scale = min(
      rect.width / Self.sourceSize.width,
      rect.height / Self.sourceSize.height
    )
    let renderedSize = CGSize(
      width: Self.sourceSize.width * scale,
      height: Self.sourceSize.height * scale
    )
    let renderedOrigin = CGPoint(
      x: rect.midX - renderedSize.width / 2,
      y: rect.midY - renderedSize.height / 2
    )

    func point(x: CGFloat, y: CGFloat) -> CGPoint {
      CGPoint(
        x: renderedOrigin.x + (x - Self.sourceOrigin.x) * scale,
        y: renderedOrigin.y + (y - Self.sourceOrigin.y) * scale
      )
    }

    func sourceRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
      let origin = point(x: x, y: y)
      return CGRect(
        x: origin.x,
        y: origin.y,
        width: width * scale,
        height: height * scale
      )
    }

    var path = Path()
    path.addRoundedRect(
      in: sourceRect(x: 120, y: 348, width: 784, height: 328),
      cornerSize: CGSize(width: 100 * scale, height: 100 * scale)
    )
    path.addRoundedRect(
      in: sourceRect(x: 168, y: 396, width: 688, height: 232),
      cornerSize: CGSize(width: 52 * scale, height: 52 * scale)
    )
    path.addEllipse(in: sourceRect(x: 546, y: 472, width: 80, height: 80))
    path.addEllipse(in: sourceRect(x: 696, y: 472, width: 80, height: 80))
    return path
  }
}

enum PortDeckMenuBarIcon {
  @MainActor
  static let image: NSImage = {
    let imageSize = NSSize(width: 20, height: 10)
    let image = NSImage(size: imageSize, flipped: false) { bounds in
      let sourceOrigin = CGPoint(x: 96, y: 324)
      let sourceSize = CGSize(width: 832, height: 376)
      let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
      let renderedSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
      let renderedOrigin = CGPoint(
        x: bounds.midX - renderedSize.width / 2,
        y: bounds.midY - renderedSize.height / 2
      )

      func sourceRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
          x: renderedOrigin.x + (x - sourceOrigin.x) * scale,
          y: renderedOrigin.y + (y - sourceOrigin.y) * scale,
          width: width * scale,
          height: height * scale
        )
      }

      let mark = NSBezierPath()
      mark.windingRule = .evenOdd
      mark.append(
        NSBezierPath(
          roundedRect: sourceRect(x: 120, y: 348, width: 784, height: 328),
          xRadius: 100 * scale,
          yRadius: 100 * scale
        )
      )
      mark.append(
        NSBezierPath(
          roundedRect: sourceRect(x: 168, y: 396, width: 688, height: 232),
          xRadius: 52 * scale,
          yRadius: 52 * scale
        )
      )
      mark.appendOval(in: sourceRect(x: 546, y: 472, width: 80, height: 80))
      mark.appendOval(in: sourceRect(x: 696, y: 472, width: 80, height: 80))
      NSColor.black.setFill()
      mark.fill()
      return true
    }
    image.isTemplate = true
    return image
  }()
}
