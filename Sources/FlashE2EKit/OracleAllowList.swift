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
/// fixture HTML (e.g. `Snapshots/github-home.allowed.json`). A
/// strict-ISO failure is suppressed when the divergence's centroid
/// lies within `tolerance` of an allow-list entry on the same side.
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
    rect: CGRect, side: AllowListEntry.Side, tolerance: CGFloat = 8
  ) -> Bool {
    let cx = rect.midX, cy = rect.midY
    for entry in entries where entry.side == side {
      let dx = cx - entry.cgRect.midX
      let dy = cy - entry.cgRect.midY
      if dx * dx + dy * dy <= tolerance * tolerance {
        return true
      }
    }
    return false
  }
}
