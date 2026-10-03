import CoreGraphics

/// The geometry of `[overlay] hint_placement`, in NSScreen coordinates (y
/// grows upwards). Only where the chip is drawn depends on it: the click still
/// aims at the corner chip's centre (`AppDelegate.hintCommitPoint`), so a
/// placement can never change what a hint clicks.
extension HintPlacement {
  /// A chip of `size` for `target`, kept on `screen` (the target's display,
  /// `screen(for:among:)`) when one is given.
  func chipFrame(target: CGRect, size: CGSize, screen: CGRect?) -> CGRect {
    let frame: CGRect
    switch self {
    case .corner:
      frame = OverlayPanel.chipFrame(target: target, width: size.width, height: size.height)
    case .center:
      frame = CGRect(
        x: target.midX - size.width / 2, y: target.midY - size.height / 2,
        width: size.width, height: size.height)
    case .above, .below:
      // The leading edge, as the corner chip uses; a target barely wider
      // than the chip gets it centred instead.
      let x =
        target.width < size.width * 1.3 ? target.midX - size.width / 2 : target.minX
      let y = self == .above ? target.maxY : target.minY - size.height
      frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }
    guard let screen, !screen.isNull, !screen.isEmpty else { return frame }
    return Self.clamp(frame, into: screen)
  }

  /// The display a target's chip stays on: the one holding the target's
  /// centre, else the one it overlaps most; nil when it is on none.
  static func screen(for target: CGRect, among screens: [CGRect]) -> CGRect? {
    let centre = CGPoint(x: target.midX, y: target.midY)
    if let holding = screens.first(where: { $0.contains(centre) }) { return holding }
    var best: (screen: CGRect, area: CGFloat)?
    for screen in screens {
      let overlap = screen.intersection(target)
      guard !overlap.isNull else { continue }
      let area = overlap.width * overlap.height
      if area > (best?.area ?? 0) { best = (screen, area) }
    }
    return best?.screen
  }

  /// `frame` moved the least distance that puts it inside `screen`; a chip
  /// larger than the screen keeps its bottom-left corner on it.
  private static func clamp(_ frame: CGRect, into screen: CGRect) -> CGRect {
    var clamped = frame
    clamped.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
    clamped.origin.y = max(screen.minY, min(frame.minY, screen.maxY - frame.height))
    return clamped
  }
}
