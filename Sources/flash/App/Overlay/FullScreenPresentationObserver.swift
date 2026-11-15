import AppKit

/// Follows the presentation options the frontmost app puts into effect
/// (`NSApp.currentSystemPresentationOptions`), which say whether it covers the
/// display with a window behind a hidden menu bar, as games do. Flash steps
/// aside for such an app (`AppDelegate.frontmostPresentationDidChange`); native
/// full screen shows no option to another process and is read from the
/// focused window instead (`FullScreenSignals.nativeWindow`). Key-value
/// observed; nothing polls.
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
  /// presentation, hiding or auto-hiding it. Ordinary apps put neither into
  /// effect, and Flash's own auto-hide preference is no presentation option.
  static func isFullScreen(_ options: NSApplication.PresentationOptions) -> Bool {
    !options.isDisjoint(with: [.fullScreen, .hideMenuBar, .autoHideMenuBar])
  }
}

/// The two ways the frontmost app is known to be full screen; either is
/// enough.
struct FullScreenSignals: Equatable {
  /// Its presentation options take the menu bar over: a window covering the
  /// display, as games use (`FullScreenPresentationObserver.isFullScreen`).
  var presentation = false
  /// Its focused window is in native full screen (`AXFullScreen`), which no
  /// presentation option shows another process.
  var nativeWindow = false

  var isFullScreen: Bool { presentation || nativeWindow }
}
