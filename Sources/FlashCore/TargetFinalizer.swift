import CoreGraphics

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
      if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
      if lhs.providerOrder != rhs.providerOrder { return lhs.providerOrder < rhs.providerOrder }
      return lhs.ordinal < rhs.ordinal
    }
    for candidate in byDedupPreference {
      guard !dedup.contains(candidate.target.frame) else { continue }
      dedup.insert(candidate.target.frame)
      kept.append(candidate)
    }

    kept.sort { visualOrder($0.target, $1.target) }
    let targets = kept.map(\.target)
    return TargetFinalizerResult(
      targets: targets,
      rawCount: candidates.count,
      visibleCount: visible.count,
      dedupedCount: targets.count)
  }

  public static func isVisible(_ target: JumpTarget, in regions: [CGRect]) -> Bool {
    guard !regions.isEmpty else { return false }
    let frame = target.frame
    guard frame.width > 0, frame.height > 0 else { return false }
    let center = CGPoint(x: frame.midX, y: frame.midY)
    return regions.contains { $0.contains(center) }
  }

  private static func area(_ rect: CGRect) -> CGFloat {
    max(0, rect.width) * max(0, rect.height)
  }

  private static func visualOrder(_ lhs: JumpTarget, _ rhs: JumpTarget) -> Bool {
    let lhsTop = lhs.frame.maxY
    let rhsTop = rhs.frame.maxY
    if abs(lhsTop - rhsTop) > 8 { return lhsTop > rhsTop }
    if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
    if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY > rhs.frame.minY }
    if lhs.frame.width != rhs.frame.width { return lhs.frame.width < rhs.frame.width }
    if lhs.frame.height != rhs.frame.height { return lhs.frame.height < rhs.frame.height }
    return lhs.id < rhs.id
  }
}

/// Spatial-hash dedup keyed on a 256-pixel grid. For N=1500 targets, a
/// pairwise scan is O(N^2). Bucketing keeps this close to O(N) because
/// each target only compares against nearby rectangles.
private struct SpatialDedup {
  private static let cellSize: CGFloat = 256
  private var buckets: [Int64: [CGRect]] = [:]

  private static func key(_ x: Int, _ y: Int) -> Int64 {
    (Int64(x) << 32) | (Int64(y) & 0xffff_ffff)
  }

  private func bucketRange(_ rect: CGRect) -> (xMin: Int, xMax: Int, yMin: Int, yMax: Int) {
    let xMin = Int((rect.minX / Self.cellSize).rounded(.down))
    let xMax = Int((rect.maxX / Self.cellSize).rounded(.down))
    let yMin = Int((rect.minY / Self.cellSize).rounded(.down))
    let yMax = Int((rect.maxY / Self.cellSize).rounded(.down))
    return (xMin, xMax, yMin, yMax)
  }

  func contains(_ rect: CGRect) -> Bool {
    let r = bucketRange(rect)
    for x in r.xMin...r.xMax {
      for y in r.yMin...r.yMax {
        guard let bucket = buckets[Self.key(x, y)] else { continue }
        for other in bucket where overlapsSubstantially(other, rect) { return true }
      }
    }
    return false
  }

  mutating func insert(_ rect: CGRect) {
    let r = bucketRange(rect)
    for x in r.xMin...r.xMax {
      for y in r.yMin...r.yMax {
        buckets[Self.key(x, y), default: []].append(rect)
      }
    }
  }

  private func overlapsSubstantially(_ a: CGRect, _ b: CGRect) -> Bool {
    let inter = a.intersection(b)
    if inter.isNull { return false }
    let interArea = inter.width * inter.height
    let smaller = min(a.width * a.height, b.width * b.height)
    return smaller > 0 && interArea / smaller > 0.6
  }
}
