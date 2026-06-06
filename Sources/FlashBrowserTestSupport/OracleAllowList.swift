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
  /// `[x, y, w, h]` in NSScreen coords (post-fiducial transform for
  /// Vimium-only entries; native AX coords for flashOnly).
  public let rect: [Double]
  public let reason: String
  public let axRole: String?
  public let domSelector: String?

  public init(
    side: Side, rect: [Double], reason: String,
    axRole: String? = nil, domSelector: String? = nil
  ) {
    self.side = side
    self.rect = rect
    self.reason = reason
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
    positionTolerance: CGFloat = 220,
    sizeTolerance: CGFloat = 8
  ) -> Bool {
    let cx = rect.midX
    let cy = rect.midY
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
