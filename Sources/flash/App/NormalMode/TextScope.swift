import FlashCore
import Foundation

/// Whether NORMAL acts on the focused text: the one decision every
/// text-or-page choice reads. Editable focus alone is not enough, since
/// many pages keep a field focused (Google Docs' hidden editor, a search box
/// that takes the focus on load, the address bar): NORMAL acts on a field
/// only once the user engaged it, by an explicit act in it.
///
/// - Engage: leaving INSERT with the focus in a field, `gi` (`input focus`),
///   a primary click or an `f` commit on a text input, whose focus then
///   settles on editable text, and `v` / `V`.
/// - Disengage: the focus settling on another element or app, Escape in
///   NORMAL (`mode leave`), and any mode change but the round trips through
///   INSERT, VISUAL, the command line (`:42` goes to line 42 of the field)
///   and a HYPER hold (a `<leader>` sequence typed in the field).
///
/// While engaged NORMAL reads the text table (`[mode.text.mappings]`),
/// `move` drives the caret, and the motions, placements and changes act on
/// the text; otherwise the field is a page: `move` scrolls and NORMAL's own
/// keys apply. The interpreter's table follows the engagement only, never a
/// focus reading on its own, so a half-typed sequence survives focus
/// noise. Pure value; the app delegate holds the one instance, on main.
struct TextScope: Equatable {
  /// A focused element: its app and its identity (`CFHash`).
  struct Element: Hashable {
    var pid: pid_t
    var identity: Int
  }

  enum EngageReason: String, Equatable {
    case leftInsert = "left_insert"
    case inputFocus = "input_focus"
    case click
    case hint
    case visual
  }

  enum DisengageReason: String, Equatable {
    case focusMoved = "focus_moved"
    case escape
    case modeChanged = "mode_changed"
    case configChanged = "config_changed"
  }

  /// What a transition did, for the log and the table.
  enum Change: Equatable {
    case engaged(Element, EngageReason)
    case disengaged(Element, DisengageReason)

    var element: Element {
      switch self {
      case .engaged(let element, _), .disengaged(let element, _): return element
      }
    }
  }

  /// An act whose focus has not settled yet: a click, `gi` or an `f`
  /// commit. Each reading until the user's next key engages the editable
  /// text it names, so a reading of the focus from before the click is
  /// corrected by the next one.
  struct Awaiting: Equatable {
    /// The app the act was in; nil for a click, which may bring another
    /// app forward.
    var pid: pid_t?
    var reason: EngageReason
    /// A key was typed while a reading was pending: that reading is the
    /// act's last.
    var endsAfterNextReading = false
  }

  private(set) var engaged: Element?
  private(set) var awaiting: Awaiting?

  /// D0: where NORMAL engages at all. `[mode.text] enabled` is the switch,
  /// off for a user who keeps Vim inside the field (kindaVim, SketchyVim);
  /// `[mode.apps."<bundle>".text] enabled` forces one app either way, over the
  /// plugins' `own_text_editing` declarations (`OwnTextEditingApps`: VS
  /// Code and its forks, the JetBrains IDEs, Zed, Sublime Text).
  struct Policy: Equatable {
    var enabled = true
    var apps: [String: Bool] = [:]

    init(enabled: Bool = true, apps: [String: Bool] = [:]) {
      self.enabled = enabled
      self.apps = apps
    }

    init(_ mode: Config.Mode) {
      enabled = mode.textEnabled
      apps = mode.appMappings.compactMapValues(\.engagesText)
    }
  }

  var policy = Policy()

  /// Whether NORMAL may engage a field in `bundleIdentifier`: the switch is
  /// on, and the app is forced on, or not declared to edit text its own
  /// way. Pure: no AX, nothing read on the keypress.
  func engages(_ bundleIdentifier: String?) -> Bool {
    guard policy.enabled else { return false }
    if let bundleIdentifier, let forced = policy.apps[bundleIdentifier] { return forced }
    return !OwnTextEditingApps.contains(bundleIdentifier)
  }

  /// Whether the focused element's kind is editable text: a text field, a
  /// text area, a search field, a combo box, a secure field or a web input.
  /// A terminal never is.
  static func isEditable(_ text: FocusedText) -> Bool {
    text.kind == .singleLine || text.kind == .multiLine
  }

  /// D1: whether NORMAL acts on `text`, read from `element` in `pid`:
  /// editable text the user engaged.
  func isActive(for text: FocusedText, pid: pid_t, element: Int?) -> Bool {
    guard Self.isEditable(text), let element, let engaged else { return false }
    return engaged == Element(pid: pid, identity: element)
  }

  /// `text` as NORMAL may act on it: itself when active, else uneditable,
  /// so a placement or a change only enters INSERT.
  func gate(_ text: FocusedText, pid: pid_t, element: Int?) -> FocusedText {
    isActive(for: text, pid: pid, element: element) ? text : .uneditable
  }

  /// Whether NORMAL reads the text table: a field is engaged.
  var isEngaged: Bool { engaged != nil }

  /// The region `move` resolves by: editable text that is not engaged is
  /// a page, where the keys scroll.
  func region(of reading: FocusRegionTracker.Reading, pid: pid_t) -> FocusRegion {
    guard case .text = reading.region else { return reading.region }
    guard let element = reading.element, engaged == Element(pid: pid, identity: element)
    else { return .document }
    return reading.region
  }

  // MARK: Transitions

  /// Engage `element`, in the app `bundleIdentifier`; nil when it already
  /// is, or when NORMAL never engages there (`engages`).
  mutating func engage(_ element: Element, in bundleIdentifier: String?, reason: EngageReason)
    -> Change?
  {
    guard engages(bundleIdentifier), engaged != element else { return nil }
    engaged = element
    return .engaged(element, reason)
  }

  /// The config changed: `policy` applies from now on, and an engagement it
  /// refuses ends (`bundle` names the engaged app).
  mutating func update(
    policy: Policy, invalidatesPending: Bool = false, bundle: (pid_t) -> String?
  ) -> Change? {
    if invalidatesPending || self.policy != policy { awaiting = nil }
    self.policy = policy
    guard let engaged, !engages(bundle(engaged.pid)) else { return nil }
    return disengage(.configChanged)
  }

  /// Disengage; nil when nothing was engaged. A pending act ends too.
  mutating func disengage(_ reason: DisengageReason) -> Change? {
    awaiting = nil
    guard let element = engaged else { return nil }
    engaged = nil
    return .disengaged(element, reason)
  }

  /// A click, `gi` or an `f` commit in `pid` (nil: any app) went out: the
  /// readings until the next key engage the editable text they name.
  mutating func awaitFocus(in pid: pid_t?, reason: EngageReason) {
    awaiting = Awaiting(pid: pid, reason: reason)
  }

  /// A key reached NORMAL: a pending act ends now, or after the reading
  /// still pending (`readPending`), which then still counts for it.
  mutating func keyTyped(readPending: Bool) {
    guard awaiting != nil else { return }
    if readPending {
      awaiting?.endsAfterNextReading = true
    } else {
      awaiting = nil
    }
  }

  /// A reading of `pid`'s focus landed (`bundle` is the app's id). A pending
  /// act engages the editable text it names, where NORMAL engages at all;
  /// otherwise a reading naming another element or app disengages, and one
  /// naming the engaged element keeps it, whatever its region says.
  mutating func focusSettled(pid: pid_t, bundle: String?, reading: FocusRegionTracker.Reading)
    -> Change?
  {
    let element = reading.element.map { Element(pid: pid, identity: $0) }
    if let pending = awaiting {
      if pending.endsAfterNextReading { awaiting = nil }
      if pending.pid == nil || pending.pid == pid, case .text = reading.region,
        let element
      {
        return engage(element, in: bundle, reason: pending.reason)
      }
    }
    guard let engaged, element != engaged else { return nil }
    self.engaged = nil
    return .disengaged(engaged, .focusMoved)
  }

  /// The focus may have moved to `pid` before a reading says where: another
  /// app ends the engagement at once.
  mutating func focusMayHaveChanged(pid: pid_t) -> Change? {
    guard let engaged, engaged.pid != pid else { return nil }
    awaiting = awaiting?.pid == nil ? awaiting : nil
    self.engaged = nil
    return .disengaged(engaged, .focusMoved)
  }

  /// What a mode change does to the engagement: the round trips through
  /// INSERT, VISUAL, the command line and a HYPER hold keep it, leaving
  /// INSERT engages the field the focus is in, and every other mode ends it.
  enum ModeChangeEffect: Equatable {
    case keep
    case engageFocus
    case disengage
  }

  static func effect(ofModeChange previous: Mode, to next: Mode) -> ModeChangeEffect {
    switch (previous, next) {
    case (.insert, .normal): return .engageFocus
    case (.normal, .insert), (.visual, .insert), (.normal, .visual), (.visual, .visual),
      (.visual, .normal), (.normal, .normal), (.insert, .insert),
      (.normal, .command), (.normal, .hyper):
      return .keep
    case (_, .normal), (_, .insert), (_, .visual):
      // Back from a mode that already ended it.
      return .keep
    default:
      return .disengage
    }
  }
}
