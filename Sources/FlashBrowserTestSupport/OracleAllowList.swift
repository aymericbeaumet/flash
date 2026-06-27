import CoreGraphics
import Foundation

/// One justified divergence between Vimium and Flash on a given fixture.
public struct AllowListEntry: Codable {
  public enum Side: String, Codable {
    /// Vimium hinted it; Flash did not. AX-side gap.
    case vimiumOnly
    /// Flash hinted it; Vimium did not. AX-side over-match.
    case flashOnly
  }
  public let side: Side
  /// `[x, y, w, h]` in **page-relative** NSScreen-space points: the
  /// divergence rect with the fiducial-derived `pageScreenRect` origin
  /// subtracted off (see `OracleDiff.classify`'s `pageOrigin`). Storing
  /// page-relative instead of absolute screen coords makes the sidecar
  /// invariant to where Firefox's window actually sits — critical now
  /// that the oracle parks its windows offscreen, which shifts every
  /// absolute coordinate by the (clamped) offscreen offset. The legacy
  /// sidecars were recorded under the old maximize path where the page
  /// sat at the screen origin, so their absolute values already equal
  /// page-relative values within tolerance.
  public let rect: [Double]
  public let axRole: String?
  public let domSelector: String?

  public init(
    side: Side, rect: [Double], reason: String,
    axRole: String? = nil, domSelector: String? = nil
  ) {
    self.side = side
    self.rect = rect
    self.axRole = axRole
    self.domSelector = domSelector
  }

  public var cgRect: CGRect {
    CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
  }
}

/// Per-fixture allow-list. Loaded from a JSON sidecar next to the
/// fixture HTML (e.g. `allowlists/github-home.allowed.json`). A
/// strict-ISO failure is suppressed when the divergence has the same
/// side and recorded kind, a similar shape, and a centroid close to an
/// allow-list entry. Collected browser snapshots can shift with Firefox
/// chrome/window placement, so matching tolerates origin drift while
/// still requiring equivalent target kind and dimensions.
public struct OracleAllowList: Codable {
  public let entries: [AllowListEntry]

  public static let empty = OracleAllowList(entries: [])

  public init(entries: [AllowListEntry]) {
    self.entries = entries
  }

  public static func load(from url: URL) throws -> OracleAllowList {
    let data = try Data(contentsOf: url)
    if data.isEmpty { return .empty }
    return try JSONDecoder().decode(OracleAllowList.self, from: data)
  }

  public func contains(
    rect: CGRect,
    side: AllowListEntry.Side,
    axRole: String? = nil,
    domSelector: String? = nil,
    pageOrigin: CGPoint = .zero,
    positionTolerance: CGFloat = 220,
    sizeTolerance: CGFloat = 8
  ) -> Bool {
    // Stored entries are page-relative; bring the live (absolute-screen)
    // rect into the same space before comparing centroids.
    let cx = rect.midX - pageOrigin.x
    let cy = rect.midY - pageOrigin.y
    for entry in entries where entry.side == side {
      if let expected = entry.axRole, expected != axRole { continue }
      if let expected = entry.domSelector, expected != domSelector { continue }
      let entryRect = entry.cgRect
      guard abs(rect.width - entryRect.width) <= sizeTolerance,
        abs(rect.height - entryRect.height) <= sizeTolerance
      else {
        continue
      }
      let dx = cx - entryRect.midX
      let dy = cy - entryRect.midY
      if dx * dx + dy * dy <= positionTolerance * positionTolerance {
        return true
      }
    }
    return false
  }
}
