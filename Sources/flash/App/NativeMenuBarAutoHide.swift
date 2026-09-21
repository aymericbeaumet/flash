import AppKit
import Foundation

/// Flash's status bar occupies the same band as the system menu bar, so when
/// it is enabled Flash asks macOS to auto-hide the native one — the global
/// `_HIHideMenuBar` default behind System Settings → Control Center → Menu Bar
/// → "Automatically hide and show the menu bar". The window server picks the
/// write up live; no relaunch or `killall` is involved. Reaching for the top
/// edge still reveals the real menu bar, which the bar window yields to
/// (`OverlayPanel.setStatusBarYieldsToNativeMenuBar`).
///
/// Flash only reverses what it set. An ownership flag in Flash's own defaults
/// records whether the hide came from Flash, so disabling the bar restores a
/// menu bar Flash hid while leaving a preference the user set themselves
/// alone.
enum NativeMenuBarAutoHide {
  private static let preferenceKey = "_HIHideMenuBar" as CFString
  static let ownershipKey = "hidNativeMenuBar"

  /// What one reconcile pass should do, given the request, the current system
  /// value, and whether Flash is the one that hid it. Pure so the ownership
  /// rules are unit-tested without touching global preferences.
  struct Reconciliation: Equatable {
    /// The value to write, or nil to leave the system preference alone.
    var write: Bool?
    /// The ownership flag to persist afterwards.
    var owned: Bool
  }

  static func reconciliation(hidden: Bool, current: Bool, owned: Bool) -> Reconciliation {
    guard hidden else {
      // Only undo Flash's own hide, and only while it is still in effect.
      return Reconciliation(write: owned && current ? false : nil, owned: false)
    }
    // Already hidden by the user: adopt the state without claiming it, so
    // disabling the bar later cannot take their menu bar setting with it.
    return current ? Reconciliation(write: nil, owned: owned) : Reconciliation(
      write: true, owned: true)
  }

  static func reconcile(hidden: Bool, defaults: UserDefaults = .standard) {
    let current = isHidden()
    let plan = reconciliation(
      hidden: hidden, current: current, owned: defaults.bool(forKey: ownershipKey))
    if let write = plan.write { setHidden(write) }
    if plan.owned {
      defaults.set(true, forKey: ownershipKey)
    } else {
      defaults.removeObject(forKey: ownershipKey)
    }
    FlashLog.info(
      "[statusbar] native_menu_bar_auto_hide requested=\(hidden) was=\(current) "
        + "wrote=\(plan.write.map(String.init) ?? "nothing") owned=\(plan.owned)")
  }

  static func isHidden() -> Bool {
    let value = CFPreferencesCopyValue(
      preferenceKey, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
      kCFPreferencesAnyHost)
    return (value as? NSNumber)?.boolValue ?? false
  }

  private static func setHidden(_ hidden: Bool) {
    CFPreferencesSetValue(
      preferenceKey, NSNumber(value: hidden), kCFPreferencesAnyApplication,
      kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
  }
}
