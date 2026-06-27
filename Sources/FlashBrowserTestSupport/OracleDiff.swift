import CoreGraphics
import FlashCore
import FlashIntegrationTestSupport
import Foundation

public struct DiffEntry {
  public enum Kind {
    case matched(vimium: VimiumAnchor, flash: JumpTarget)
    case vimiumOnly(VimiumAnchor)
    case flashOnly(JumpTarget)
  }
  public let kind: Kind
  /// True when this entry would otherwise be a strict-ISO failure but
  /// is covered by an allow-list sidecar entry.
  public let suppressedByAllowList: Bool
}

public enum OracleDiff {
  public struct Result {
    public let entries: [DiffEntry]

    public var matchedCount: Int {
      entries.reduce(0) { acc, e in
        if case .matched = e.kind { return acc + 1 }
        return acc
      }
    }
    /// Hard failures = anything Flash *missed* relative to Vimium. Flash
    /// reporting *more* targets than Vimium is acceptable (it surfaces a
    /// real AX-exposed control like a "Skip to main content" link or a
    /// hidden focusable shortcut) and reported separately as a soft
    /// warning. Missing hint targets are the only state that breaks
    /// strict ISO — they hide functionality from the user.
    public var hardFailures: [DiffEntry] {
      entries.filter { entry in
        if entry.suppressedByAllowList { return false }
        switch entry.kind {
        case .matched, .flashOnly: return false
        case .vimiumOnly: return true
        }
      }
    }

    /// Soft warnings = anything Flash reports that Vimium does not.
    /// Surfaced in oracle output as informational lines but do not fail
    /// the runner.
    public var softWarnings: [DiffEntry] {
      entries.filter { entry in
        if entry.suppressedByAllowList { return false }
        switch entry.kind {
        case .matched, .vimiumOnly: return false
        case .flashOnly: return true
        }
      }
    }
  }

  /// Pair Vimium anchors with Flash AX targets by greedy
  /// nearest-neighbour. A pair is a candidate when its rect centroids
  /// are within 12pt, their IoU ≥ 0.5, or one rect substantially
  /// contains the other. The containment case handles Firefox AX
  /// exposing a smaller text/icon rect inside Vimium's DOM clickable
  /// rectangle; clicking either rect activates the same target.
  /// Each item on either side matches at most once; ties broken by
  /// smallest centroid distance.
  /// Unmatched entries are classified per side and checked against
  /// `allowList` for strict-ISO suppression.
  public static func classify(
    vimium: [VimiumAnchor],
    flash: [JumpTarget],
    allowList: OracleAllowList,
    pageRect: CGRect = .zero
  ) -> Result {
    struct Candidate {
      let vIdx: Int
      let fIdx: Int
      let cost: Double
    }
    var candidates: [Candidate] = []
    for (vi, v) in vimium.enumerated() {
      for (fi, f) in flash.enumerated() {
        let dist = centroidDistance(v.screenRect, f.frame)
        let iou = iouRatio(v.screenRect, f.frame)
        let containment = smallerOverlapRatio(v.screenRect, f.frame)
        // Width and height matching within a few points indicate the same
        // logical control. Firefox's AX rect for some controls (e.g.
        // Google's search result links wrapping an `<h3>`) can be ~30pt
        // offset vertically from the DOM bounding rect Vimium reads,
        // even though Flash is correctly hinting the same anchor. Pair
        // them when the dimensions line up exactly and the rects sit
        // within roughly one control-height of each other.
        let widthDiff = abs(v.screenRect.width - f.frame.width)
        let heightDiff = abs(v.screenRect.height - f.frame.height)
        let dimsMatch = widthDiff <= 4 && heightDiff <= 4
        let dimToleranceLimit = max(
          Double(max(v.screenRect.height, f.frame.height)),
          24)
        if dist <= 12 || iou >= 0.5 || containment >= 0.6
          || (dimsMatch && dist <= dimToleranceLimit)
        {
          candidates.append(Candidate(vIdx: vi, fIdx: fi, cost: dist))
        }
      }
    }
    candidates.sort { $0.cost < $1.cost }
    var matchedV = Set<Int>()
    var matchedF = Set<Int>()
    var matches: [(Int, Int)] = []
    for c in candidates {
      if matchedV.contains(c.vIdx) || matchedF.contains(c.fIdx) { continue }
      matches.append((c.vIdx, c.fIdx))
      matchedV.insert(c.vIdx)
      matchedF.insert(c.fIdx)
    }

    var entries: [DiffEntry] = []
    for (vi, fi) in matches {
      entries.append(
        DiffEntry(
          kind: .matched(vimium: vimium[vi], flash: flash[fi]),
          suppressedByAllowList: false))
    }
    for (vi, v) in vimium.enumerated() where !matchedV.contains(vi) {
      let suppressed = allowList.contains(
        rect: v.screenRect,
        side: .vimiumOnly,
        domSelector: v.tag,
        pageOrigin: pageRect.origin)
      entries.append(
        DiffEntry(kind: .vimiumOnly(v), suppressedByAllowList: suppressed))
    }
    for (fi, f) in flash.enumerated() where !matchedF.contains(fi) {
      let suppressed = allowList.contains(
        rect: f.frame,
        side: .flashOnly,
        axRole: f.role,
        pageOrigin: pageRect.origin)
      entries.append(
        DiffEntry(kind: .flashOnly(f), suppressedByAllowList: suppressed))
    }
    return Result(entries: entries)
  }

  /// Emit pass/fail lines through `recorder`. Hard failures are
  /// vimium-only entries (Flash missed a target) not covered by
  /// allow-list. Flash-only entries are surfaced as informational
  /// "Flash reports more" passes because surfacing an extra real AX
  /// target never hides functionality from the user.
  public static func report(
    _ result: Result,
    fixtureName: String,
    recorder: FlashIntegrationRecorder
  ) {
    recorder.pass(
      "\(fixtureName): \(result.matchedCount) matched, "
        + "\(result.hardFailures.count) divergence(s) requiring action, "
        + "\(result.softWarnings.count) flash-only soft warning(s)")

    for entry in result.entries {
      switch entry.kind {
      case .matched: continue
      case .vimiumOnly(let v):
        let line =
          "vimiumOnly  rect=\(rectString(v.screenRect)) "
          + "tag=\(v.tag) role=\(v.role.isEmpty ? "-" : v.role) "
          + "label=\(quote(v.label))"
        if entry.suppressedByAllowList {
          recorder.pass("allow-listed " + line)
        } else {
          recorder.fail(line)
        }
      case .flashOnly(let t):
        let line =
          "flashOnly   rect=\(rectString(t.frame)) "
          + "axRole=\(t.role ?? "<nil>") label=\(quote(t.accessibilityLabel ?? "")) id=\(t.id)"
        if entry.suppressedByAllowList {
          recorder.pass("allow-listed " + line)
        } else {
          recorder.pass("flash-more " + line)
        }
      }
    }
  }

  /// JSON shape suitable for pasting into a fixture's `.allowed.json`.
  /// Used by the `--update-allow-list` CLI flag to bootstrap a new
  /// fixture's sidecar.
  public static func suggestedAllowListJSON(_ result: Result, pageRect: CGRect = .zero)
    -> String
  {
    var entries: [AllowListEntry] = []
    let origin = pageRect.origin
    for entry in result.entries {
      guard !entry.suppressedByAllowList else { continue }
      switch entry.kind {
      case .matched: continue
      case .vimiumOnly(let v):
        entries.append(
          AllowListEntry(
            side: .vimiumOnly,
            rect: rectArray(v.screenRect, pageOrigin: origin),
            reason: "explain why this divergence is acceptable before committing",
            axRole: nil,
            domSelector: v.tag.isEmpty ? nil : v.tag))
      case .flashOnly(let t):
        entries.append(
          AllowListEntry(
            side: .flashOnly,
            rect: rectArray(t.frame, pageOrigin: origin),
            reason: "explain why this divergence is acceptable before committing",
            axRole: t.role,
            domSelector: nil))
      }
    }
    let payload = OracleAllowList(entries: entries)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = (try? encoder.encode(payload)) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  private static func centroidDistance(_ a: CGRect, _ b: CGRect) -> Double {
    let dx = Double(a.midX - b.midX)
    let dy = Double(a.midY - b.midY)
    return (dx * dx + dy * dy).squareRoot()
  }

  private static func iouRatio(_ a: CGRect, _ b: CGRect) -> Double {
    let inter = a.intersection(b)
    if inter.isNull || inter.isEmpty { return 0 }
    let iArea = Double(inter.width * inter.height)
    let union = Double(a.width * a.height + b.width * b.height) - iArea
    return union > 0 ? iArea / union : 0
  }

  private static func smallerOverlapRatio(_ a: CGRect, _ b: CGRect) -> Double {
    let inter = a.intersection(b)
    if inter.isNull || inter.isEmpty { return 0 }
    let smaller = min(a.width * a.height, b.width * b.height)
    guard smaller > 0 else { return 0 }
    return Double(inter.width * inter.height / smaller)
  }

  private static func rectString(_ r: CGRect) -> String {
    String(format: "[%.0f,%.0f %.0fx%.0f]", r.minX, r.minY, r.width, r.height)
  }

  private static func rectArray(_ r: CGRect, pageOrigin: CGPoint = .zero) -> [Double] {
    [
      Double(r.minX - pageOrigin.x), Double(r.minY - pageOrigin.y),
      Double(r.width), Double(r.height),
    ]
  }

  private static func quote(_ s: String) -> String {
    "\"\(s.prefix(30))\""
  }
}
