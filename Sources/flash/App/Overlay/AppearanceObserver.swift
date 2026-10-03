import AppKit

/// Follows the system appearance for `[overlay.dark]`: key-value observation
/// of `NSApp.effectiveAppearance`, which changes with the Light/Dark setting
/// and its automatic schedule. Event-driven; nothing polls. The overlay reads
/// the result at its next draw.
final class AppearanceObserver {
  private var observation: NSKeyValueObservation?

  /// `onChange` runs on the main thread: right away, then after every change.
  init(_ application: NSApplication, onChange: @escaping (Bool) -> Void) {
    observation = application.observe(\.effectiveAppearance, options: [.initial, .new]) {
      application, _ in
      let dark = Self.isDark(application.effectiveAppearance)
      if Thread.isMainThread {
        onChange(dark)
      } else {
        DispatchQueue.main.async { onChange(dark) }
      }
    }
  }

  deinit { observation?.invalidate() }

  static func isDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  }
}
