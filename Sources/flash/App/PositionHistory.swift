import CoreGraphics
import Foundation

/// Saved pointer positions (`mouse_position`): a bounded list, newest last,
/// kept per app or shared by every app. Pure value; `AppDelegate` owns one.
struct PositionHistory: Equatable {
  struct Entry: Equatable {
    var point: CGPoint
    /// The app the position was saved in; nil when none was focused.
    var bundleID: String?
  }

  /// Two positions closer than this are the same place: saving again
  /// refreshes it, and cycling or unsaving from it counts as being on it.
  static let samePlaceDistance: CGFloat = 12

  private(set) var entries: [Entry] = []

  /// The positions `mouse_position` acts on: every one, or this app's when
  /// the history is per app.
  func positions(app: String?, scope: Config.PositionScope) -> [CGPoint] {
    visible(app: app, scope: scope).map(\.point)
  }

  private func visible(app: String?, scope: Config.PositionScope) -> [Entry] {
    switch scope {
    case .global: return entries
    case .app: return entries.filter { $0.bundleID == app }
    }
  }

  /// Remember `point`. A position already saved at that place moves to the
  /// end; past `maxSize` the oldest of the list the scope keeps is dropped.
  /// Returns how many positions that list now holds.
  @discardableResult
  mutating func save(
    _ point: CGPoint, app: String?, scope: Config.PositionScope, maxSize: Int
  ) -> Int {
    guard point.x.isFinite, point.y.isFinite else { return positions(app: app, scope: scope).count }
    let entry = Entry(point: point, bundleID: scope == .app ? app : nil)
    entries.removeAll { existing in
      Self.samePlace(existing.point, point) && Self.sameList(existing, entry, scope: scope)
    }
    entries.append(entry)
    var count = 0
    var trimmed: [Entry] = []
    for existing in entries.reversed() {
      if Self.sameList(existing, entry, scope: scope) {
        count += 1
        if count > max(1, maxSize) { continue }
      }
      trimmed.append(existing)
    }
    entries = trimmed.reversed()
    return min(count, max(1, maxSize))
  }

  /// Forget the saved position the pointer is on. False when it is on none.
  @discardableResult
  mutating func unsave(near point: CGPoint, app: String?, scope: Config.PositionScope) -> Bool {
    let probe = Entry(point: point, bundleID: scope == .app ? app : nil)
    let before = entries.count
    entries.removeAll {
      Self.samePlace($0.point, point) && Self.sameList($0, probe, scope: scope)
    }
    return entries.count != before
  }

  /// Forget every position of the list the scope keeps.
  mutating func clear(app: String?, scope: Config.PositionScope) {
    switch scope {
    case .global: entries.removeAll()
    case .app: entries.removeAll { $0.bundleID == app }
    }
  }

  /// The saved position after the one the pointer is on, wrapping; the first
  /// when the pointer is on none. Nil with nothing saved.
  func next(from point: CGPoint, app: String?, scope: Config.PositionScope) -> CGPoint? {
    step(from: point, app: app, scope: scope, delta: 1)
  }

  /// The saved position before the one the pointer is on, wrapping; the last
  /// when the pointer is on none.
  func previous(from point: CGPoint, app: String?, scope: Config.PositionScope) -> CGPoint? {
    step(from: point, app: app, scope: scope, delta: -1)
  }

  private func step(
    from point: CGPoint, app: String?, scope: Config.PositionScope, delta: Int
  ) -> CGPoint? {
    let list = positions(app: app, scope: scope)
    guard !list.isEmpty else { return nil }
    guard let current = list.firstIndex(where: { Self.samePlace($0, point) }) else {
      return delta > 0 ? list.first : list.last
    }
    let index = ((current + delta) % list.count + list.count) % list.count
    return list[index]
  }

  static func samePlace(_ a: CGPoint, _ b: CGPoint) -> Bool {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return dx * dx + dy * dy <= samePlaceDistance * samePlaceDistance
  }

  private static func sameList(_ a: Entry, _ b: Entry, scope: Config.PositionScope) -> Bool {
    scope == .global || a.bundleID == b.bundleID
  }
}
