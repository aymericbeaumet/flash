import CoreGraphics
import Foundation

/// Where the easiest labels go (`[hints] label_order`), as pure geometry.
/// Frames and regions are NSScreen rectangles: y grows upward, so the top
/// row of zones is the band with the largest y.
enum HintLabelOrdering {
  /// `region` when it is a usable rectangle, else the frames' bounding box.
  static func frame(of frames: [CGRect], region: CGRect?) -> CGRect {
    if let region, usable(region) { return region }
    var union = CGRect.null
    for frame in frames where usable(frame) { union = union.union(frame) }
    return union.isNull ? .zero : union
  }

  private static func usable(_ rect: CGRect) -> Bool {
    !rect.isNull && !rect.isInfinite && rect.width > 0 && rect.height > 0
      && rect.minX.isFinite && rect.minY.isFinite
  }

  /// Target indexes, nearest the centre of the region first; ties keep
  /// reading order. The label list is assigned in this order.
  static func centerRanks(frames: [CGRect], region: CGRect?) -> [Int] {
    let bounds = frame(of: frames, region: region)
    let centre = CGPoint(x: bounds.midX, y: bounds.midY)
    return frames.indices.sorted { lhs, rhs in
      let a = distance(frames[lhs], to: centre)
      let b = distance(frames[rhs], to: centre)
      if a != b { return a < b }
      return lhs < rhs
    }
  }

  private static func distance(_ frame: CGRect, to point: CGPoint) -> CGFloat {
    let dx = frame.midX - point.x
    let dy = frame.midY - point.y
    let squared = dx * dx + dy * dy
    return squared.isFinite ? squared : .infinity
  }

  /// The zone keys as they sit on the keyboard: one array per physical row,
  /// top row first, each left to right. A literal alphabet has no keyboard
  /// and is one row in written order.
  static func zoneRows(
    alphabet: [Character], keyRows: [Character: Int], keyColumns: [Character: Int]
  ) -> [[Character]] {
    let placed = alphabet.filter { keyRows[$0] != nil && keyColumns[$0] != nil }
    guard placed.count == alphabet.count, !alphabet.isEmpty else { return [alphabet] }
    let rowIndexes = Set(alphabet.compactMap { keyRows[$0] }).sorted()
    let written = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })
    return rowIndexes.map { row in
      alphabet.filter { keyRows[$0] == row }.sorted { lhs, rhs in
        let a = keyColumns[lhs] ?? 0
        let b = keyColumns[rhs] ?? 0
        if a != b { return a < b }
        return (written[lhs] ?? 0) < (written[rhs] ?? 0)
      }
    }
  }

  /// The zone key of every frame: the row band its centre falls in, then the
  /// column band within that row. A centre outside the region clamps to its
  /// nearest zone.
  static func zones(frames: [CGRect], rows: [[Character]], region: CGRect?) -> [Character] {
    let bounds = frame(of: frames, region: region)
    guard !rows.isEmpty, rows.allSatisfy({ !$0.isEmpty }) else { return [] }
    return frames.map { frame in
      let rowBand = band(
        (bounds.maxY - frame.midY) / max(bounds.height, 1), count: rows.count)
      let row = rows[rowBand]
      let column = band((frame.midX - bounds.minX) / max(bounds.width, 1), count: row.count)
      return row[column]
    }
  }

  /// Which of `count` equal bands a 0…1 position falls in, clamped.
  private static func band(_ position: CGFloat, count: Int) -> Int {
    guard count > 1, position.isFinite else { return 0 }
    let index = Int((position * CGFloat(count)).rounded(.down))
    return min(max(index, 0), count - 1)
  }
}
