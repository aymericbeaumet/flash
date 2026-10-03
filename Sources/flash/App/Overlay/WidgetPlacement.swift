import CoreGraphics
import Foundation

/// Where a desktop widget's windows go: which displays, and the frame on each.
/// Frames live in the Flash-usable part of a display — its visible frame
/// (menu bar and Dock excluded) less the Flash bar band when the bar reserves
/// space there — in AppKit's y-up global coordinates.
enum WidgetPlacement {
  /// The displays a widget shows on. Display numbers count left to right
  /// (ties top to bottom); a number past the last display shows nothing.
  static func screens(
    _ selection: Config.Widget.Screen, layouts: [WindowScreenLayout], widget name: String
  ) -> [WindowScreenLayout] {
    switch selection {
    case .all:
      return layouts
    case .primary:
      return (layouts.first { $0.frame.origin == .zero } ?? layouts.first).map { [$0] } ?? []
    case .index(let number):
      let ordered = layouts.sorted {
        ($0.frame.minX, -$0.frame.maxY) < ($1.frame.minX, -$1.frame.maxY)
      }
      guard ordered.indices.contains(number - 1) else {
        FlashLog.debug(
          "[widgets] no display \(number) name=\(name) displays=\(layouts.count)",
          source: "core:WidgetPlacement")
        return []
      }
      return [ordered[number - 1]]
    }
  }

  /// The widget's frame for `anchor`, `gap` points in from the anchored
  /// edges (ignored along a centred axis), kept inside `usable`. A widget
  /// larger than the usable frame keeps its top-left corner in view.
  static func frame(
    anchor: Config.Widget.Anchor, gap: CGSize, size: CGSize, usable: CGRect
  ) -> CGRect {
    let x: CGFloat
    switch anchor {
    case .topLeft, .centreLeft, .bottomLeft: x = usable.minX + gap.width
    case .topCentre, .centre, .bottomCentre: x = usable.midX - size.width / 2
    case .topRight, .centreRight, .bottomRight: x = usable.maxX - gap.width - size.width
    }
    let y: CGFloat
    switch anchor {
    case .topLeft, .topCentre, .topRight: y = usable.maxY - gap.height - size.height
    case .centreLeft, .centre, .centreRight: y = usable.midY - size.height / 2
    case .bottomLeft, .bottomCentre, .bottomRight: y = usable.minY + gap.height
    }
    return CGRect(
      x: max(usable.minX, min(x, usable.maxX - size.width)),
      y: min(usable.maxY - size.height, max(y, usable.minY)),
      width: size.width, height: size.height)
  }
}
