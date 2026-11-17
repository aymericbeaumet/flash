import FlashCore
import Foundation

/// How long hints take to appear: from the input that asked for them (the
/// tap event's timestamp, the Carbon hotkey event's, the AppleEvent's
/// arrival) to the Core Animation commit that puts them on screen, one frame
/// or less before the display shows them. Logged once per activation as
///
///     [latency] hints_visible ms=<n> origin=<key|hotkey|cli>
///       prepared=<hit|miss|none> targets=<n> class=<native|browser|electron|other>
///       surface=<surface> bundle=<id|-> outcome=<hit|miss|retried|empty|none>
///       miss_reason=<PreparedModelMiss|->
///
/// or, when the activation ends without drawing anything, as
///
///     [latency] hints_empty ms=<n> bundle=<id|-> path=<path> origin=<…>
///       surface=<surface>
///
/// `Scripts/benchmark-hints.sh` collects these lines; see docs/performance.md.
struct HintLatencyProbe: Equatable {
  /// Whether the hints came from the focused app's prepared model; `none`
  /// for surfaces that walk nothing (the mouse grid).
  enum Prepared: String {
    case hit, miss, none
  }

  /// How the app's own hints were obtained: served from the prepared model,
  /// walked, walked again after a degenerate first walk, or not at all (the
  /// app yielded nothing, even when status-bar segments were still shown).
  /// `none` for surfaces that walk nothing.
  enum Outcome: String {
    case hit, miss, retried, empty, none
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

  /// A target activation's outcome: `appHints` counts the app's own hints,
  /// before any status-bar segment joins them.
  static func outcome(_ discovery: DiscoveryOutcome, appHints: Int) -> Outcome {
    if appHints == 0 { return .empty }
    if discovery.retried { return .retried }
    return discovery.preparedHit ? .hit : .miss
  }

  /// Milliseconds from the trigger to `uptime`, never negative.
  func elapsedMs(at uptime: TimeInterval) -> Double {
    max(0, uptime - triggeredAt) * 1000
  }

  /// `missReason` says why the prepared model could not serve a miss; `-`
  /// for a hit and for surfaces that never consult it.
  func line(
    visibleAt uptime: TimeInterval, prepared: Prepared, outcome: Outcome, targets: Int,
    appClass: AppClass, bundleIdentifier: String?, surface: String, missReason: PreparedModelMiss?
  ) -> String {
    "[latency] hints_visible ms=\(Self.format(elapsedMs(at: uptime))) origin=\(origin.rawValue) "
      + "prepared=\(prepared.rawValue) targets=\(targets) class=\(appClass.rawValue) "
      + "surface=\(surface) bundle=\(Self.field(bundleIdentifier)) outcome=\(outcome.rawValue) "
      + "miss_reason=\(missReason?.rawValue ?? "-")"
  }

  /// An activation that ended without hints: `path` names where discovery
  /// gave up (the `[discover] complete` path, or why it never walked).
  func emptyLine(
    endedAt uptime: TimeInterval, bundleIdentifier: String?, path: String, surface: String
  ) -> String {
    "[latency] hints_empty ms=\(Self.format(elapsedMs(at: uptime))) "
      + "bundle=\(Self.field(bundleIdentifier)) path=\(path) origin=\(origin.rawValue) "
      + "surface=\(surface)"
  }

  /// The activation as telemetry: `flash.hints.latency` and a span from the
  /// trigger inside its interaction. No bundle identifier: which apps the
  /// user works in stays on this Mac.
  func recordTelemetry(
    endedAt uptime: TimeInterval, surface: String, outcome: String, appClass: String?,
    targets: Int
  ) {
    guard FlashTelemetry.current != nil else { return }
    var attributes = ["origin": origin.rawValue, "surface": surface, "outcome": outcome]
    if let appClass { attributes["app_class"] = appClass }
    FlashTelemetry.record(.hintsLatency, elapsedMs(at: uptime), attributes)
    attributes["targets"] = String(targets)
    FlashTelemetry.span(
      outcome == "empty" ? "hints empty" : "hints visible", trace: trace.text,
      startUptime: triggeredAt, endUptime: uptime, attributes: attributes, origin: origin)
  }

  private static func format(_ ms: Double) -> String {
    String(format: "%.1f", ms)
  }

  /// A bundle id never contains whitespace; an unknown one is `-`, so every
  /// field still parses as `name=value`.
  private static func field(_ bundleIdentifier: String?) -> String {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return "-" }
    return bundleIdentifier
  }
}
