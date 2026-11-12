import AppKit

/// Launches, or brings forward, the app LaunchServices knows by bundle id:
/// a mark whose app is not running, an apple catalog's `open`, a plugin's
/// `host.open {bundle_id}`. The lookup runs off main, the open on main, and
/// `completion` runs on main with the failure, if any, so the caller can
/// show it.
enum ApplicationLauncher {
  static func open(bundleID: String, completion: @escaping (String?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
      DispatchQueue.main.async {
        guard let url else {
          completion("no app for bundle id \(bundleID)")
          return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        { _, error in
          DispatchQueue.main.async { completion(error.map { String(describing: $0) }) }
        }
      }
    }
  }
}
