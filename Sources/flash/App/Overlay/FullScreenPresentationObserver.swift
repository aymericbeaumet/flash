import AppKit

/// Follows the presentation options the frontmost app puts into effect
/// (`NSApp.currentSystemPresentationOptions`), which say whether it is full
/// screen: native full screen, or a window that covers the display and hides
/// the menu bar, as games and browser video do. Flash steps aside for such an
/// app (`AppDelegate.frontmostPresentationDidChange`). Key-value observed;
/// nothing polls.
final class FullScreenPresentationObserver {
  private var observation: NSKeyValueObservation?

  /// `onChange` runs on the main thread after every change of the options;
  /// read the launch value from `NSApp.currentSystemPresentationOptions`.
  init(
    _ application: NSApplication,
    onChange: @escaping (NSApplication.PresentationOptions) -> Void
  ) {
    observation = application.observe(\.currentSystemPresentationOptions, options: [.new]) {
      application, _ in
      let options = application.currentSystemPresentationOptions
      if Thread.isMainThread {
        onChange(options)
      } else {
        DispatchQueue.main.async { onChange(options) }
      }
    }
  }

  deinit { observation?.invalidate() }

  /// The frontmost app has taken the menu bar over for a full-screen
  /// presentation: native full screen auto-hides it, a covering window hides
  /// it outright. Ordinary apps put neither into effect, and Flash's own
  /// auto-hide preference is no presentation option.
  static func isFullScreen(_ options: NSApplication.PresentationOptions) -> Bool {
    !options.isDisjoint(with: [.fullScreen, .hideMenuBar, .autoHideMenuBar])
  }
}
