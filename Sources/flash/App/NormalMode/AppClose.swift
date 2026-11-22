/// `app close`, vim's `:q`. `tab close` runs first, as the sources, the
/// plugin confirmation and the app's binding resolve it. Only an app with no
/// tab to close — no source, and `tab close` bound `false` or not at all,
/// as the `defaults` plugin declares for Messages — goes on to its windows:
/// vim quits the window it is in, and the last one quits the program.
enum AppClose {
  enum Step: Equatable {
    case closeWindow
    case quitApp
  }

  /// Whether `tab close` ended with no tab to close, so the windows follow.
  /// A tab closed, a chord sent, a source that failed, a refused chord or
  /// no app at all end `:q` where they are.
  static func continuesToWindows(after outcome: NormalModeCommandOutcome) -> Bool {
    outcome == .unavailable
  }

  /// With the app's standard windows counted (nil: unreadable), the focused
  /// one closes while others remain; the last one, none, or a list that
  /// cannot be read quits the app, as `:q` at vim's last window does.
  static func step(standardWindows: Int?) -> Step {
    guard let standardWindows, standardWindows > 1 else { return .quitApp }
    return .closeWindow
  }
}
