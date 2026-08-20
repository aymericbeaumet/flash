import Foundation

/// Runtime-applied config tunables that were historically hardcoded deep in
/// their subsystems. One home, one `apply(_:)` from config load/reload —
/// consumers read the statics at use time. Writes happen on the main thread
/// during config application; reads are scalar loads from various queues,
/// which is benign for these advisory knobs.
enum FlashTunables {
  /// `[mode] scroll_step` — pixels per h/j/k/l (and ctrl+e/y) step.
  static var scrollStepPixels: Int32 = 60
  /// `[mode] scroll_page_fraction` — d/u fraction of the scroll range.
  static var scrollPageFraction: Double = 0.5
  /// `[mode] click_hold_ms` — synthesized mouse-down→up hold.
  static var clickHoldMs: Int = 18
  /// `[mode] send_key_interval_ms` — spacing between send_key chords.
  static var sendKeyIntervalMs: Int = 35
  /// `[overlay] alert_duration` — default `alert_show` dwell (seconds).
  static var alertDuration: TimeInterval = 2.0
  /// `[overlay] banner_duration_ms` — transient banner dwell.
  static var bannerDurationMs: Int = 700
  /// `[plugins] install_timeout` — third-party install script hard kill.
  static var pluginInstallTimeoutSeconds: Int = 120
  /// `[plugins] startup_timeout` — plugin handshake deadline.
  static var pluginStartupTimeoutSeconds: Int = 15
  /// `[flashlight] snapshot_timeout_ms` — warm-catalog aggregate deadline.
  static var flashlightSnapshotTimeoutMs: Int = 150
  /// `[flashlight] live_query_timeout_ms` — per-keystroke deadline for
  /// `mode = "live"` plugin sources. Never joins the first-paint barrier, so
  /// raising it cannot regress first paint — it only delays that source's
  /// own merge into an explicitly scoped pool.
  static var flashlightLiveQueryTimeoutMs: Int = 1000
  /// `[statusbar] font_size` — bar text size in points.
  static var statusBarFontSize: Double = 13
  /// `[statusbar] notch_margin` — points kept clear beside a notch.
  static var statusBarNotchMargin: Double = 0

  static func apply(_ config: Config) {
    scrollStepPixels = Int32(config.mode.scrollStep)
    scrollPageFraction = config.mode.scrollPageFraction
    clickHoldMs = config.mode.clickHoldMs
    sendKeyIntervalMs = config.mode.sendKeyIntervalMs
    alertDuration = config.overlay.alertDuration
    bannerDurationMs = config.overlay.bannerDurationMs
    pluginInstallTimeoutSeconds = config.plugins.installTimeoutSeconds
    pluginStartupTimeoutSeconds = config.plugins.startupTimeoutSeconds
    flashlightSnapshotTimeoutMs = config.flashlight.snapshotTimeoutMs
    flashlightLiveQueryTimeoutMs = config.flashlight.liveQueryTimeoutMs
    statusBarFontSize = config.statusBar.fontSize
    statusBarNotchMargin = config.statusBar.notchMargin
  }
}
