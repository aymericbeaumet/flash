import CoreGraphics
import Foundation

/// Affine transform from page-CSS coordinates to NSScreen coordinates,
/// solved at runtime from a small set of fiducial pairs the companion
/// extension injects + measures.
///
/// The transform is decomposable into translate + per-axis scale (no
/// rotation/skew — browsers don't rotate viewport coords). With 2+
/// fiducials in non-collinear positions we have enough equations to
/// solve directly.
///
/// Why fiducials instead of computing from devicePixelRatio + AXWebArea:
///   - macOS Retina scales DPR differently for the same logical pixel
///     count depending on display mode (full-resolution vs scaled).
///   - Browser zoom level changes the CSS->screen ratio invisibly.
///   - AXWebArea position can include or exclude chrome offsets in ways
///     that drift between Firefox releases.
/// Fiducial-based calibration sidesteps all of that — if a fiducial is
/// at CSS (40,40) and AX reports it at screen (180, 720), the transform
/// is whatever maps one to the other, regardless of why.
public struct OracleTransform {
  public let scaleX: Double
  // Typically negative: CSS Y grows downward, NSScreen Y grows upward.
  public let scaleY: Double
  public let translateX: Double
  public let translateY: Double

  public init(scaleX: Double, scaleY: Double, translateX: Double, translateY: Double) {
    self.scaleX = scaleX
    self.scaleY = scaleY
    self.translateX = translateX
    self.translateY = translateY
  }

  public enum SolveError: Error, CustomStringConvertible {
    case insufficientFiducials(have: Int, need: Int)
    case degenerate(String)

    public var description: String {
      switch self {
      case .insufficientFiducials(let have, let need):
        return "Need \(need) fiducial pairs, got \(have)."
      case .degenerate(let why):
        return "Cannot solve transform: \(why)"
      }
    }
  }

  /// Solve from CSS-screen pairs. Picks the pair with the largest CSS
  /// separation from the first to avoid degenerate near-collinear
  /// inputs.
  public static func solve(pairs: [(css: CGPoint, screen: CGPoint)]) throws -> OracleTransform {
    guard pairs.count >= 2 else {
      throw SolveError.insufficientFiducials(have: pairs.count, need: 2)
    }
    let anchor = pairs[0]
    var best = pairs[1]
    var bestMag: Double = -1
    for p in pairs.dropFirst() {
      let dx = Double(p.css.x - anchor.css.x)
      let dy = Double(p.css.y - anchor.css.y)
      let mag = dx * dx + dy * dy
      if mag > bestMag {
        bestMag = mag
        best = p
      }
    }
    let dxCSS = Double(best.css.x - anchor.css.x)
    let dyCSS = Double(best.css.y - anchor.css.y)
    let dxScreen = Double(best.screen.x - anchor.screen.x)
    let dyScreen = Double(best.screen.y - anchor.screen.y)
    guard abs(dxCSS) > 1e-3 else {
      throw SolveError.degenerate("fiducials share same CSS x")
    }
    guard abs(dyCSS) > 1e-3 else {
      throw SolveError.degenerate("fiducials share same CSS y")
    }
    let sx = dxScreen / dxCSS
    let sy = dyScreen / dyCSS
    let tx = Double(anchor.screen.x) - sx * Double(anchor.css.x)
    let ty = Double(anchor.screen.y) - sy * Double(anchor.css.y)
    return OracleTransform(scaleX: sx, scaleY: sy, translateX: tx, translateY: ty)
  }

  public func screenPoint(fromCSS p: CGPoint) -> CGPoint {
    CGPoint(
      x: CGFloat(Double(p.x) * scaleX + translateX),
      y: CGFloat(Double(p.y) * scaleY + translateY))
  }

  /// Convert a CSS-space rect (top-left origin) to a NSScreen-space
  /// rect (bottom-left origin). Handles the Y-axis flip via negative
  /// `scaleY` — output rect is always normalized (positive width/height).
  public func screenRect(fromCSS r: CGRect) -> CGRect {
    let p1 = screenPoint(fromCSS: CGPoint(x: r.minX, y: r.minY))
    let p2 = screenPoint(fromCSS: CGPoint(x: r.maxX, y: r.maxY))
    let x = min(p1.x, p2.x)
    let y = min(p1.y, p2.y)
    let w = abs(p2.x - p1.x)
    let h = abs(p2.y - p1.y)
    return CGRect(x: x, y: y, width: w, height: h)
  }

  /// Maximum per-fiducial residual after applying the solved transform.
  /// The runner asserts this is sub-pixel so a broken calibration fails
  /// loudly instead of corrupting every downstream rect comparison.
  public func maxResidual(pairs: [(css: CGPoint, screen: CGPoint)]) -> Double {
    var maxR: Double = 0
    for (css, screen) in pairs {
      let computed = screenPoint(fromCSS: css)
      let dx = Double(computed.x - screen.x)
      let dy = Double(computed.y - screen.y)
      let r = (dx * dx + dy * dy).squareRoot()
      if r > maxR { maxR = r }
    }
    return maxR
  }
}
