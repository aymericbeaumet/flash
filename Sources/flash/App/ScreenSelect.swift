import AppKit
import FlashCore

/// `mouse screens [--index=<n> | --direction=next|previous] [--to=center|last]
/// [--focus]`, monitor select: which display, where on it the pointer lands,
/// and whether keyboard focus follows. Pure value state; `AppDelegate`
/// (`activateScreens`, `PointerWarps.swift`) applies it.
struct ScreenSelectRequest: Hashable {
  /// Which display.
  enum Pick: Hashable {
    /// Label every display with its number and take the one typed.
    case labels
    /// Display `n`, counting from 1 (`ScreenSelect.arranged`).
    case index(Int)
    /// The display after or before the pointer's, wrapping.
    case next
    case previous
  }

  /// Where the pointer lands on it.
  enum Landing: String, Hashable, CaseIterable {
    /// The centre of its usable frame: inside the Dock and the bar.
    case center
    /// Where the pointer was when a pick last took it off that display;
    /// the centre the first time.
    case last
  }

  var pick: Pick = .labels
  var landing: Landing = .center
  /// Focus the frontmost window on that display as well.
  var focus = false

  var argTokens: [String] {
    var tokens: [String] = []
    switch pick {
    case .labels: break
    case .index(let number): tokens.append("--index=\(number)")
    case .next: tokens.append("--direction=next")
    case .previous: tokens.append("--direction=previous")
    }
    if landing != .center { tokens.append("--to=\(landing.rawValue)") }
    if focus { tokens.append("--focus") }
    return tokens
  }
}

enum ScreenSelect {
  /// Displays in their numbering order: left to right, ties top to bottom.
  /// The order of `--index`, a NORMAL count, the labels and
  /// `[widgets.<name>] screen = <n>`; `window move --screen` and
  /// `--direction` step through it.
  static func arranged(_ layouts: [WindowScreenLayout]) -> [WindowScreenLayout] {
    layouts.sorted {
      ($0.frame.minX, -$0.frame.maxY) < ($1.frame.minX, -$1.frame.maxY)
    }
  }

  /// What a pick does on `displays`, the arranged display frames.
  enum Plan: Equatable {
    /// No such display: nothing happens, and nothing is shown.
    case none
    /// Label every display.
    case labels
    /// Act on `displays[index]` at once.
    case display(Int)
  }

  /// One display is picked without a label, whatever the pick asked.
  static func plan(
    _ pick: ScreenSelectRequest.Pick, displays: [CGRect], pointer: CGPoint
  ) -> Plan {
    guard !displays.isEmpty else { return .none }
    switch pick {
    case .labels:
      return displays.count == 1 ? .display(0) : .labels
    case .index(let number):
      return displays.indices.contains(number - 1) ? .display(number - 1) : .none
    case .next, .previous:
      let current = displayIndex(of: pointer, in: displays)
      let step = pick == .next ? 1 : -1
      return .display(((current + step) % displays.count + displays.count) % displays.count)
    }
  }

  /// The display holding `point`, else the nearest one: a pointer can sit
  /// in the gap an arrangement leaves between displays.
  static func displayIndex(of point: CGPoint, in displays: [CGRect]) -> Int {
    if let index = displays.firstIndex(where: { $0.contains(point) }) { return index }
    func distance(_ rect: CGRect) -> CGFloat {
      let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
      let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
      return dx * dx + dy * dy
    }
    return displays.indices.min { distance(displays[$0]) < distance(displays[$1]) } ?? 0
  }

  static let targetPrefix = "screen:"

  /// One target per arranged display, on the centre of its usable frame.
  /// The id carries the display's identity, which the commit looks up again.
  static func targets(_ arranged: [WindowScreenLayout]) -> [JumpTarget] {
    arranged.enumerated().map { index, layout in
      let centre = self.centre(of: layout)
      return JumpTarget(
        id: targetPrefix + layout.identity,
        frame: CGRect(x: centre.x - 1, y: centre.y - 1, width: 2, height: 2),
        role: "FlashScreen",
        accessibilityLabel: "Display \(index + 1)",
        priority: .important,
        providerID: AppDelegate.screensProviderID)
    }
  }

  /// The display identity a screen target names; nil for any other target.
  static func identity(of target: JumpTarget) -> String? {
    guard target.providerID == AppDelegate.screensProviderID,
      target.id.hasPrefix(targetPrefix)
    else { return nil }
    return String(target.id.dropFirst(targetPrefix.count))
  }

  /// Each display labelled with its number, so the label typed is the
  /// display's `--index`. Nil past nine displays, where `1` would prefix
  /// `10`: the hint alphabet labels them instead.
  static func numberedHints(_ targets: [JumpTarget]) -> [AssignedHint]? {
    guard targets.count <= 9 else { return nil }
    return targets.enumerated().map { AssignedHint(target: $1, label: String($0 + 1)) }
  }

  /// Where the pointer lands on `layout`.
  static func landing(
    on layout: WindowScreenLayout, _ landing: ScreenSelectRequest.Landing,
    memory: ScreenPointerMemory
  ) -> CGPoint {
    switch landing {
    case .center: return centre(of: layout)
    case .last: return memory.point(on: layout) ?? centre(of: layout)
    }
  }

  /// A pick's commit, against the displays connected when it lands: the
  /// display, the point the pointer goes to, and the memory with the
  /// pointer's departure recorded. Nil when no connected display has that
  /// identity: it was unplugged under its label, and the pick cancels.
  static func select(
    identity: String, landing: ScreenSelectRequest.Landing, layouts: [WindowScreenLayout],
    pointer: CGPoint, memory: ScreenPointerMemory
  ) -> (display: WindowScreenLayout, point: CGPoint, memory: ScreenPointerMemory)? {
    guard let display = layouts.first(where: { $0.identity == identity }) else { return nil }
    var memory = memory
    memory.leave(pointer: pointer, layouts: layouts)
    return (display, self.landing(on: display, landing, memory: memory), memory)
  }

  private static func centre(of layout: WindowScreenLayout) -> CGPoint {
    let frame =
      layout.usableFrame.isNull || layout.usableFrame.isEmpty ? layout.frame : layout.usableFrame
    return CGPoint(x: frame.midX, y: frame.midY)
  }
}

/// Where the pointer was on each display when a `mouse screens` pick took
/// it away, for `--to=last`: one point per connected display, by identity.
struct ScreenPointerMemory: Equatable {
  private(set) var points: [String: CGPoint] = [:]

  /// The pointer leaves for a pick: remember it on its display, and forget
  /// the displays no longer connected.
  mutating func leave(pointer: CGPoint, layouts: [WindowScreenLayout]) {
    let connected = Set(layouts.map(\.identity))
    points = points.filter { connected.contains($0.key) }
    guard let display = layouts.first(where: { $0.frame.contains(pointer) }) else { return }
    points[display.identity] = pointer
  }

  /// The remembered point, while `layout` still holds it.
  func point(on layout: WindowScreenLayout) -> CGPoint? {
    guard let point = points[layout.identity], layout.frame.contains(point) else { return nil }
    return point
  }
}
