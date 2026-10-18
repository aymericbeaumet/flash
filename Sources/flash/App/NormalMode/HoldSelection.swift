import CoreGraphics

/// HOLD holds a mouse button, so the text an app selects runs from where
/// the button went down to where the pointer is. A motion extends it the way
/// Vim's selection extends from the cursor: by moving the pointer, or by
/// moving the page under a pointer that stays put and telling the app.
enum HoldSelection {
  /// An app extends a drag selection only on a drag event, so after a
  /// scroll the held button's drag is re-posted where the pointer is: once
  /// a frame after the scroll's last wheel step (`scrollMs` after it starts),
  /// and once more after an app's own smooth scroll has settled.
  static func catchUpDelays(scrollMs: Int) -> [Int] {
    [scrollMs + 16, scrollMs + 200]
  }

  /// Where `gg` / `G` drag the pointer: the top or bottom edge of the
  /// window, `inset` points inside, in the pointer's column kept inside the
  /// window. Dragging there extends the selection to the first or last line.
  static func edgePoint(top: Bool, pointer: CGPoint, window: CGRect, inset: CGFloat = 2)
    -> CGPoint
  {
    let dx = min(inset, window.width / 2)
    let dy = min(inset, window.height / 2)
    let x = min(max(pointer.x, window.minX + dx), window.maxX - dx)
    return CGPoint(x: x, y: top ? window.maxY - dy : window.minY + dy)
  }
}
