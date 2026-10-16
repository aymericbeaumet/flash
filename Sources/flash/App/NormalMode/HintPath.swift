import Foundation

/// `--path`: the targets between two picks. Hints are in reading order, so
/// the span between two indexes is the span the eye reads between them.
enum HintPath {
  /// Every index from `first` to `second`, both included, in that direction,
  /// clipped to `count`. Empty when either pick is out of range.
  static func indexes(from first: Int, to second: Int, count: Int) -> [Int] {
    guard first >= 0, second >= 0, first < count, second < count else { return [] }
    if first <= second { return Array(first...second) }
    return Array((second...first).reversed())
  }
}
