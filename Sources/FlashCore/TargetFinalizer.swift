import CoreGraphics

extension CGRect {
  /// Boundary-inclusive point containment.
  ///
  /// `CGRect.contains` treats the max-X and max-Y edges as *outside* (a
  /// half-open interval). That rejects an element whose center lands exactly
  /// on the viewport's right or bottom edge — the classic case being a link
  /// that straddles the top/bottom fold so its center sits precisely on the
  /// boundary. Vimium keeps such elements (its visible-center test is `>=`
  /// and `<=` on all four sides), so Flash must use the same closed-interval
  /// test or it reports a spurious "missed hint" for every edge-straddling
  /// control.
  public func containsInclusive(_ point: CGPoint) -> Bool {
    point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
  }
}

public struct TargetCandidate {
  public let target: JumpTarget
  public let priority: Int
  public let providerOrder: Int
  public let ordinal: Int

  public init(
    target: JumpTarget,
    priority: Int,
    providerOrder: Int,
    ordinal: Int
  ) {
    self.target = target
    self.priority = priority
    self.providerOrder = providerOrder
    self.ordinal = ordinal
  }
}

public struct TargetFinalizerResult {
  public let targets: [JumpTarget]
  public let rawCount: Int
  public let visibleCount: Int
  public let dedupedCount: Int
}

public enum TargetFinalizer {
  public static func finalize(
    _ candidates: [TargetCandidate],
    visibleRegions: [CGRect]
  ) -> [JumpTarget] {
    finalizeWithStats(candidates, visibleRegions: visibleRegions).targets
  }

  public static func finalizeWithStats(
    _ candidates: [TargetCandidate],
    visibleRegions: [CGRect]
  ) -> TargetFinalizerResult {
    let visible = candidates.filter { isVisible($0.target, in: visibleRegions) }

    var dedup = SpatialDedup()
    var kept: [TargetCandidate] = []
    kept.reserveCapacity(visible.count)
    let byDedupPreference = visible.sorted { lhs, rhs in
      let lhsArea = area(lhs.target.frame)
      let rhsArea = area(rhs.target.frame)
      if lhsArea != rhsArea { return lhsArea < rhsArea }
      if !lhsArea.isFinite {
        let lhsLog = logArea(lhs.target.frame)
        let rhsLog = logArea(rhs.target.frame)
        if lhsLog != rhsLog { return lhsLog < rhsLog }
      }
      if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
      if lhs.providerOrder != rhs.providerOrder { return lhs.providerOrder < rhs.providerOrder }
      if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
      return verticalOrder(lhs.target, rhs.target)
    }
    for candidate in byDedupPreference {
      guard !dedup.contains(candidate.target.frame) else { continue }
      dedup.insert(candidate.target.frame)
      kept.append(candidate)
    }

    let targets = visualRows(kept.map(\.target))
    return TargetFinalizerResult(
      targets: targets,
      rawCount: candidates.count,
      visibleCount: visible.count,
      dedupedCount: targets.count)
  }

  public static func isVisible(_ target: JumpTarget, in regions: [CGRect]) -> Bool {
    guard !regions.isEmpty else { return false }
    let frame = target.frame
    guard frame.width > 0, frame.height > 0,
      [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
    else { return false }
    let center = CGPoint(x: frame.midX, y: frame.midY)
    return regions.contains { $0.containsInclusive(center) }
  }

  private static func area(_ rect: CGRect) -> CGFloat {
    max(0, rect.width) * max(0, rect.height)
  }

  fileprivate static func logArea(_ rect: CGRect) -> CGFloat {
    log(rect.width) + log(rect.height)
  }

  private static func visualRows(_ targets: [JumpTarget]) -> [JumpTarget] {
    let ordered = targets.sorted(by: verticalOrder)
    var result: [JumpTarget] = []
    result.reserveCapacity(ordered.count)
    var start = 0
    while start < ordered.count {
      let top = ordered[start].frame.maxY
      var end = start + 1
      // Anchor each row to its highest target. Pairwise tolerance in a sort
      // comparator is nontransitive when three targets straddle two rows.
      while end < ordered.count, top - ordered[end].frame.maxY <= 8 { end += 1 }
      result.append(contentsOf: ordered[start..<end].sorted(by: horizontalOrder))
      start = end
    }
    return result
  }

  private static func verticalOrder(_ lhs: JumpTarget, _ rhs: JumpTarget) -> Bool {
    if lhs.frame.maxY != rhs.frame.maxY { return lhs.frame.maxY > rhs.frame.maxY }
    return horizontalOrder(lhs, rhs)
  }

  private static func horizontalOrder(_ lhs: JumpTarget, _ rhs: JumpTarget) -> Bool {
    if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
    if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY > rhs.frame.minY }
    if lhs.frame.width != rhs.frame.width { return lhs.frame.width < rhs.frame.width }
    if lhs.frame.height != rhs.frame.height { return lhs.frame.height < rhs.frame.height }
    if lhs.id != rhs.id { return lhs.id < rhs.id }
    if lhs.pid != rhs.pid { return (lhs.pid ?? .min) < (rhs.pid ?? .min) }
    return lhs.providerID < rhs.providerID
  }
}

/// Spatial-hash dedup keyed on a 256-pixel grid. For N=1500 targets, a
/// pairwise scan is O(N^2). Bucketing keeps this close to O(N) because
/// each target only compares against nearby rectangles.
private struct SpatialDedup {
  private static let cellSize: CGFloat = 256
  private var buckets: [Int64: [CGRect]] = [:]
  private var allFrames: [CGRect] = []
  private var oversizedFrames: [CGRect] = []

  private static func key(_ x: Int, _ y: Int) -> Int64 {
    (Int64(x) << 32) | (Int64(y) & 0xffff_ffff)
  }

  private func bucketRange(_ rect: CGRect) -> (xMin: Int, xMax: Int, yMin: Int, yMax: Int)? {
    let left = (rect.minX / Self.cellSize).rounded(.down)
    let right = (rect.maxX / Self.cellSize).rounded(.down)
    let bottom = (rect.minY / Self.cellSize).rounded(.down)
    let top = (rect.maxY / Self.cellSize).rounded(.down)
    // Untrusted geometry must not trap integer conversion or allocate a grid
    // proportional to its area. Exceptional frames use bounded linear lookup.
    guard (right - left + 1) * (top - bottom + 1) <= 256,
      let xMin = Int(exactly: left), let xMax = Int(exactly: right),
      let yMin = Int(exactly: bottom), let yMax = Int(exactly: top)
    else { return nil }
    return (xMin, xMax, yMin, yMax)
  }

  func contains(_ rect: CGRect) -> Bool {
    guard let r = bucketRange(rect) else {
      return allFrames.contains { overlapsSubstantially($0, rect) }
    }
    if oversizedFrames.contains(where: { overlapsSubstantially($0, rect) }) { return true }
    for x in r.xMin...r.xMax {
      for y in r.yMin...r.yMax {
        guard let bucket = buckets[Self.key(x, y)] else { continue }
        for other in bucket where overlapsSubstantially(other, rect) { return true }
      }
    }
    return false
  }

  mutating func insert(_ rect: CGRect) {
    allFrames.append(rect)
    guard let r = bucketRange(rect) else {
      oversizedFrames.append(rect)
      return
    }
    for x in r.xMin...r.xMax {
      for y in r.yMin...r.yMax {
        buckets[Self.key(x, y), default: []].append(rect)
      }
    }
  }

  /// Two rects are considered duplicates when they substantially cover the
  /// same screen real estate. The intent is to drop AX wrappers that
  /// repeat a single logical control — Firefox's `<a><img/></a>` (AXLink
  /// and AXImage with identical frames), or two web-area providers each
  /// emitting the same anchor.
  ///
  /// We require the smaller rect to fill most of the larger one: when a
  /// tiny inner control sits inside a much larger clickable container
  /// (e.g. a small icon button nested inside a large `<button>`), the
  /// outer control is its own legitimate hint target and must survive.
  /// Requiring `smaller / larger > 0.5` keeps the same-rect collapse
  /// (ratio ≈ 1) while letting nested independent controls coexist.
  private func overlapsSubstantially(_ a: CGRect, _ b: CGRect) -> Bool {
    let inter = a.intersection(b)
    if inter.isNull { return false }
    let interArea = inter.width * inter.height
    let aArea = a.width * a.height
    let bArea = b.width * b.height
    let smaller = min(aArea, bArea)
    let larger = max(aArea, bArea)
    guard smaller > 0, larger > 0 else { return false }
    if !larger.isFinite {
      guard inter.width > 0, inter.height > 0 else { return false }
      let aLog = TargetFinalizer.logArea(a)
      let bLog = TargetFinalizer.logArea(b)
      return TargetFinalizer.logArea(inter) - min(aLog, bLog) > log(0.6)
        && min(aLog, bLog) - max(aLog, bLog) > log(0.5)
    }
    let containment = interArea / smaller
    let sizeRatio = smaller / larger
    return containment > 0.6 && sizeRatio > 0.5
  }
}
