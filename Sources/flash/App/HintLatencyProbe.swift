import FlashCore
import Foundation

/// How long hints take to appear: from the input that asked for them (the
/// tap event's timestamp, the Carbon hotkey event's, the AppleEvent's
/// arrival) to the Core Animation commit that puts them on screen, one frame
/// or less before the display shows them. Logged once per activation as
///
///     [latency] hints_visible ms=<n> origin=<key|hotkey|cli>
///       prepared=<hit|miss|none> targets=<n> class=<native|browser|electron|other>
///       surface=<surface>
///
/// `Scripts/benchmark-hints.sh` collects these lines; see docs/performance.md.
struct HintLatencyProbe: Equatable {
  /// Whether the hints came from the focused app's prepared model; `none`
  /// for surfaces that walk nothing (the mouse grid).
  enum Prepared: String {
    case hit, miss, none
  }

  enum AppClass: String {
    case native, browser, electron, other
  }

  let trace: Trace.ID
  let origin: Trace.Origin
  let triggeredAt: TimeInterval

  /// The probe for an activation begun by `trigger`: keys, hotkeys and CLI
  /// verbs, the inputs a user waits on. Nil for anything else, or when the
  /// activation no longer runs inside its trigger's turn.
  static func arm(_ trigger: Trace.Trigger?) -> HintLatencyProbe? {
    guard let trigger, [.key, .hotkey, .cli].contains(trigger.origin) else { return nil }
    return HintLatencyProbe(trace: trigger.id, origin: trigger.origin, triggeredAt: trigger.uptime)
  }

  /// The app's runtime as the benchmark groups it. Read from traits already
  /// cached, so the display path never touches a bundle on disk.
  static func appClass(_ traits: AppTraits?) -> AppClass {
    guard let traits else { return .other }
    if traits.isWebBrowser { return .browser }
    switch traits.engine {
    case nil: return .native
    case .chromium: return .electron
    case .gecko, .flutter: return .other
    }
  }

  func line(
    visibleAt uptime: TimeInterval, prepared: Prepared, targets: Int, appClass: AppClass,
    surface: String
  ) -> String {
    let ms = String(format: "%.1f", max(0, uptime - triggeredAt) * 1000)
    return "[latency] hints_visible ms=\(ms) origin=\(origin.rawValue) "
      + "prepared=\(prepared.rawValue) targets=\(targets) class=\(appClass.rawValue) "
      + "surface=\(surface)"
  }
}
