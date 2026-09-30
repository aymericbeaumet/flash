import Carbon.HIToolbox
import CoreGraphics
import FlashCore

/// What NORMAL does with a high-level action once no source performed it in
/// the focused app. Sources own their contexts first (tmux windows and panes,
/// the browsers plugin, the accessibility tab strip); this is the one place
/// that decides everything else, and it knows no app by name:
///
///   1. the chord a plugin manifest declares for the action in the focused app
///      (`action_keystrokes`), or nothing where it declares the app has none;
///   2. else the platform convention below, when the action has one;
///   3. else nothing.
///
/// A terminal emulator then refuses any chord that would type text
/// (`AppDelegate.commandChordTypesText`), so an action never becomes stray
/// terminal input.
enum SourceActionFallback: Equatable {
  /// Send this chord to the focused app.
  case chord(key: CGKeyCode, flags: CGEventFlags)
  /// Scroll the focused app by wheel lines.
  case scroll(NormalModeDispatcher.ScrollKind)
  /// Move the focused window's scroller to an edge.
  case scrollEdge(NormalModeDispatcher.ScrollKind)
  /// The focused app has no such action.
  case none

  static func resolve(_ name: SourceActionName, declared: ActionKeystroke?) -> SourceActionFallback
  {
    switch declared {
    case .chord(let chord)?:
      return .chord(key: chord.keyCode, flags: chord.eventFlags)
    case .unbound?:
      return .none
    case nil:
      return conventions[name] ?? .none
    }
  }

  /// `tab_select`: Command and the tab's digit, for the first nine tabs.
  static func tabSelect(index: Int) -> SourceActionFallback {
    guard (1...digitKeys.count).contains(index) else { return .none }
    return .chord(key: digitKeys[index - 1], flags: .maskCommand)
  }

  /// The platform conventions the core owns: the chord macOS apps share for an
  /// action whenever they have it, harmless where they don't (an app without
  /// tabs ignores Command-Shift-]). Plugins declare the apps that differ, such
  /// as editors whose new tab is Command-N.
  ///
  /// An action without an entry has no shared chord, so it acts only where a
  /// source or a declaration knows the app: reload is Command-R in a browser
  /// but reply in Mail and run in Xcode; Command-Shift-T reopens a browser
  /// tab but toggles the tab bar in Finder; the last tab, tab moves, panes and
  /// archiving differ everywhere.
  static let conventions: [SourceActionName: SourceActionFallback] = [
    .tabNext: .chord(key: CGKeyCode(kVK_ANSI_RightBracket), flags: [.maskCommand, .maskShift]),
    .tabPrevious: .chord(key: CGKeyCode(kVK_ANSI_LeftBracket), flags: [.maskCommand, .maskShift]),
    .tabFirst: tabSelect(index: 1),
    .tabNew: .chord(key: CGKeyCode(kVK_ANSI_T), flags: .maskCommand),
    .tabClose: .chord(key: CGKeyCode(kVK_ANSI_W), flags: .maskCommand),
    .historyBack: .chord(key: CGKeyCode(kVK_ANSI_LeftBracket), flags: .maskCommand),
    .historyForward: .chord(key: CGKeyCode(kVK_ANSI_RightBracket), flags: .maskCommand),
    .resourceNext: .scroll(.down),
    .resourcePrevious: .scroll(.up),
    .scrollTop: .scrollEdge(.top),
    .scrollBottom: .scrollEdge(.bottom),
  ]

  private static let digitKeys: [CGKeyCode] = [
    kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
    kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
  ].map { CGKeyCode($0) }
}
