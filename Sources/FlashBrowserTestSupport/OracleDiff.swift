import CoreGraphics
import FlashCore
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
    public var hardFailures: [DiffEntry] {
      entries.filter { entry in
        if entry.suppressedByAllowList { return false }
        switch entry.kind {
        case .matched: return false
        case .vimiumOnly, .flashOnly: return true
        }
      }
    }
  }

  /// Pair Vimium anchors with Flash AX targets by greedy
  /// nearest-neighbour. A pair is a candidate when its rect centroids
  /// are within 12pt OR their IoU ≥ 0.5. Each item on either side
  /// matches at most once; ties broken by smallest centroid distance.
  /// Unmatched entries are classified per side and checked against
  /// `allowList` for strict-ISO suppression.
  public static func classify(
    vimium: [VimiumAnchor],
    flash: [JumpTarget],
    allowList: OracleAllowList
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
        if dist <= 12 || iou >= 0.5 {
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
      let suppressed = allowList.contains(rect: v.screenRect, side: .vimiumOnly)
      entries.append(
        DiffEntry(kind: .vimiumOnly(v), suppressedByAllowList: suppressed))
    }
    for (fi, f) in flash.enumerated() where !matchedF.contains(fi) {
      let suppressed = allowList.contains(rect: f.frame, side: .flashOnly)
      entries.append(
        DiffEntry(kind: .flashOnly(f), suppressedByAllowList: suppressed))
    }
    return Result(entries: entries)
  }

  /// Emit pass/fail lines through `recorder`. Hard failures are any
  /// unmatched entry not covered by allow-list; everything else is
  /// summarized into a single pass line.
  public static func report(
    _ result: Result,
    fixtureName: String,
    recorder: FirefoxE2ERecorder
  ) {
    recorder.pass(
      "\(fixtureName): \(result.matchedCount) matched, "
        + "\(result.hardFailures.count) divergence(s) requiring action")

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
          + "axRole=\(t.role ?? "<nil>") id=\(t.id)"
        if entry.suppressedByAllowList {
          recorder.pass("allow-listed " + line)
        } else {
          recorder.fail(line)
        }
      }
    }
  }

  /// JSON shape suitable for pasting into a fixture's `.allowed.json`.
  /// Used by the `--update-allow-list` CLI flag to bootstrap a new
  /// fixture's sidecar.
  public static func suggestedAllowListJSON(_ result: Result) -> String {
    var entries: [AllowListEntry] = []
    for entry in result.entries {
      guard !entry.suppressedByAllowList else { continue }
      switch entry.kind {
      case .matched: continue
      case .vimiumOnly(let v):
        entries.append(
          AllowListEntry(
            side: .vimiumOnly,
            rect: rectArray(v.screenRect),
            reason: "TODO — explain why this is acceptable",
            axRole: nil,
            domSelector: v.tag.isEmpty ? nil : v.tag))
      case .flashOnly(let t):
        entries.append(
          AllowListEntry(
            side: .flashOnly,
            rect: rectArray(t.frame),
            reason: "TODO — explain why this is acceptable",
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

  private static func rectString(_ r: CGRect) -> String {
    String(format: "[%.0f,%.0f %.0fx%.0f]", r.minX, r.minY, r.width, r.height)
  }

  private static func rectArray(_ r: CGRect) -> [Double] {
    [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
  }

  private static func quote(_ s: String) -> String {
    "\"\(s.prefix(30))\""
  }
}
