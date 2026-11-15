import AppKit

/// Follows whether the frontmost app hides the menu bar, from the presentation
/// options it puts into effect (`NSApp.currentSystemPresentationOptions`): an
/// app drawing a full-screen window without a native full-screen Space, as
/// games do, hides it outright. The status bar takes the menu bar's place, so
/// it steps aside with it. Key-value observed; nothing polls.
final class MenuBarPresentationObserver {
  private var observation: NSKeyValueObservation?

  /// `onChange` runs on the main thread after every change of the options;
  /// read the launch value with `hidesMenuBar(_:)`.
  init(_ application: NSApplication, onChange: @escaping (Bool) -> Void) {
    observation = application.observe(\.currentSystemPresentationOptions, options: [.new]) {
      application, _ in
      let hidden = Self.hidesMenuBar(application.currentSystemPresentationOptions)
      if Thread.isMainThread {
        onChange(hidden)
      } else {
        DispatchQueue.main.async { onChange(hidden) }
      }
    }
  }

  deinit { observation?.invalidate() }

  /// Only an outright hide counts. Native full screen auto-hides the menu bar
  /// instead, and its Space already leaves the bar windows out, display by
  /// display.
  static func hidesMenuBar(_ options: NSApplication.PresentationOptions) -> Bool {
    options.contains(.hideMenuBar)
  }
}
