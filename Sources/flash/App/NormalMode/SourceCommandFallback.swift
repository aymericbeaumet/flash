import FlashCore

/// What NORMAL does with a command once no source performed it in the
/// focused app. Sources own their contexts first (tmux windows and panes, the
/// browsers plugin, the accessibility tab strip); this decides everything
/// else, and it knows no app and no chord:
///
///   1. the binding a plugin manifest declares for the command in the focused
///      app (`bindings`: a chord, a chord sequence or a menu item), or
///      nothing where it declares the app has none (`false`);
///   2. else Flash's own scrolling, for the commands that scroll (a list
///      with no first-item binding scrolls to its edge on `move top`);
///   3. else nothing.
///
/// A terminal emulator then refuses any chord that would type text
/// (`AppDelegate.commandChordTypesText`), so a command never becomes stray
/// terminal input.
enum SourceCommandFallback: Equatable {
  /// Dispatch this binding in the focused app.
  case binding(CommandBinding)
  /// Scroll the focused app by wheel lines.
  case scroll(NormalModeDispatcher.ScrollKind)
  /// Move the focused window's scroller to an edge.
  case scrollEdge(NormalModeDispatcher.ScrollKind)
  /// The focused app has no such command.
  case none

  static func resolve(_ name: CommandName, binding: CommandBinding?) -> SourceCommandFallback {
    switch binding {
    case .unbound?:
      return .none
    case let binding?:
      return .binding(binding)
    case nil:
      return flashOwned[name] ?? .none
    }
  }

  /// What Flash does itself when no plugin binds the command: scrolling is
  /// Flash's own wheel and scroller mechanism, not a chord any app binds.
  static let flashOwned: [CommandName: SourceCommandFallback] = [
    CommandName("resource", "next"): .scroll(.down),
    CommandName("resource", "previous"): .scroll(.up),
    CommandName("scroll", "top"): .scrollEdge(.top),
    CommandName("scroll", "bottom"): .scrollEdge(.bottom),
    CommandName("move", "top"): .scrollEdge(.top),
    CommandName("move", "bottom"): .scrollEdge(.bottom),
  ]
}
