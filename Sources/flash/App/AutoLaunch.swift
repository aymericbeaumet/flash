import Foundation
import ServiceManagement

/// Login-item registration, reconciled from `[app] autostart` on every
/// launch and config reload — the config file is the single source of
/// truth, replacing the install-script LaunchAgent. SMAppService is the
/// App-Store-era API: the entry appears under System Settings → General →
/// Login Items as "Flash".
enum AutoLaunch {
  static func reconcile(enabled: Bool) {
    let service = SMAppService.mainApp
    let registered = service.status == .enabled
    guard registered != enabled else { return }
    do {
      if enabled {
        try service.register()
        FlashLog.info("[autolaunch] registered login item (app.autostart = true)")
      } else {
        try service.unregister()
        FlashLog.info("[autolaunch] unregistered login item (app.autostart = false)")
      }
    } catch {
      // Registration legitimately fails when running from a staging copy
      // outside /Applications; the next launch of the installed copy
      // reconciles again.
      FlashLog.warn(
        "[autolaunch] \(enabled ? "register" : "unregister") failed: \(error)")
    }
  }
}
