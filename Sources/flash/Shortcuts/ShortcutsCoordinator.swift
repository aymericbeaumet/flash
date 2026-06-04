import AppKit
import Foundation

/// Owns the app-switch hotkey lifecycle.
///
/// Shortcuts come from `Config.shortcuts` (the `[shortcuts]` section
/// of flash.toml). Each entry is `hotkey-string -> app-name-or-bundle-id`.
/// On every `apply`, the entire Carbon hotkey registration set is
/// rebuilt from scratch — cheap (a few dozen registrations) and
/// avoids partial-state bugs when the user edits the config.
final class ShortcutsCoordinator {

  private let cache = AppActivationCache()
  private let hotkeys = HotKeyManager()

  func start() {
    cache.start()
  }

  func stop() {
    hotkeys.unregisterAll()
    cache.stop()
  }

  /// Replace the registered hotkey set with the bindings in `shortcuts`.
  /// Called once at startup with the loaded config, and again on every
  /// config-file reload event from AppDelegate.
  func apply(shortcuts: [String: String]) {
    hotkeys.unregisterAll()
    for (hotkey, target) in shortcuts {
      guard let rule = HotkeySyntax.parse(hotkey: hotkey, target: target) else {
        FlashLog.write("[shortcuts] could not parse \"\(hotkey)\"")
        continue
      }
      let ok = hotkeys.register(
        modifiers: rule.modifiers, virtualKey: rule.virtualKey
      ) { [weak cache] in
        cache?.activate(target: target)
      }
      if !ok {
        FlashLog.write(
          "[shortcuts] could not register \"\(hotkey)\" — "
            + "another app may already own this hotkey")
      }
    }
  }
}
