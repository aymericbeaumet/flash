import CoreGraphics

/// One `[[tiling.rules]]` entry: windows of `bundleID` (whose title contains
/// `titleContains`, when set) float or tile regardless of their kind, and
/// open on `workspace`. The first matching rule wins, in file order.
struct TilingRule: Equatable, Sendable {
  var bundleID: String
  var titleContains: String?
  /// nil: dialogs and palettes float, standard windows tile.
  var floats: Bool?
  var workspace: String?

  func matches(bundleID: String, title: () -> String?) -> Bool {
    guard self.bundleID == bundleID else { return false }
    guard let titleContains else { return true }
    return title()?.range(of: titleContains, options: .caseInsensitive) != nil
  }

  /// The first rule matching a window of `bundleID`. The title, an AX round
  /// trip, is read only when a rule for the app needs it, and once.
  static func first(
    in rules: [TilingRule], bundleID: String?, title: () -> String?
  ) -> TilingRule? {
    guard let bundleID else { return nil }
    var cached: String??
    for rule in rules where rule.bundleID == bundleID {
      guard rule.titleContains != nil else { return rule }
      if cached == nil { cached = .some(title()) }
      let read = cached ?? nil
      if rule.matches(bundleID: bundleID, title: { read }) { return rule }
    }
    return nil
  }
}

/// `[tiling]`: AeroSpace-style tiling and workspaces, off by default.
struct TilingSettings: Equatable, Sendable {
  var enabled = false
  var persist = true
  /// The root layout of a new workspace.
  var layout: TilingLayoutKind = .tiles
  /// nil (`auto`): along a display's long side.
  var orientation: TilingOrientation?
  var gaps: TilingGaps = .zero
  var accordionPadding: CGFloat = 30
  /// Workspaces always listed, in this order (`#{flash.workspaces}`); the
  /// first free one is what a display shows first.
  var workspaces: [String] = []
  /// Workspaces shown only on one display (`[tiling.monitors]`).
  var pinned: [String: TilingMonitorPattern] = [:]
  var rules: [TilingRule] = []

  static let accordionPaddingRange: ClosedRange<Int> = 0...200
  static let gapRange: ClosedRange<Int> = 0...200

  /// What a workspace or rule name may be: no spaces, at most 32 characters,
  /// so the CLI and `#{flash.workspaces}` read it as one word.
  static func isValidWorkspaceName(_ name: String) -> Bool {
    !name.isEmpty && name.count <= 32
      && name.unicodeScalars.allSatisfy { !$0.properties.isWhitespace && $0.value >= 0x20 }
  }
}
