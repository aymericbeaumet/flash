import FlashCore

/// What NORMAL does with an action once no source performed it in the focused
/// app. Sources own their contexts first (tmux windows and panes, the browsers
/// plugin, the accessibility tab strip); this decides everything else, and it
/// knows no app and no chord:
///
///   1. the binding a plugin manifest declares for the action in the focused
///      app (`action_bindings`: a chord, a chord sequence or a menu item), or
///      nothing where it declares the app has none (`false`);
///   2. else Flash's own scrolling, for the four actions that scroll;
///   3. else nothing.
///
/// A terminal emulator then refuses any chord that would type text
/// (`AppDelegate.commandChordTypesText`), so an action never becomes stray
/// terminal input.
enum SourceActionFallback: Equatable {
  /// Dispatch this binding in the focused app.
  case binding(ActionBinding)
  /// Scroll the focused app by wheel lines.
  case scroll(NormalModeDispatcher.ScrollKind)
  /// Move the focused window's scroller to an edge.
  case scrollEdge(NormalModeDispatcher.ScrollKind)
  /// The focused app has no such action.
  case none

  static func resolve(_ name: SourceActionName, binding: ActionBinding?) -> SourceActionFallback {
    switch binding {
    case .unbound?:
      return .none
    case let binding?:
      return .binding(binding)
    case nil:
      return flashOwned[name] ?? .none
    }
  }

  /// What Flash does itself when no plugin binds the action: scrolling is
  /// Flash's own wheel and scroller mechanism, not a chord any app binds.
  static let flashOwned: [SourceActionName: SourceActionFallback] = [
    .resourceNext: .scroll(.down),
    .resourcePrevious: .scroll(.up),
    .scrollTop: .scrollEdge(.top),
    .scrollBottom: .scrollEdge(.bottom),
  ]
}
