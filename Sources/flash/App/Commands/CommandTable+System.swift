import AppKit
import FlashCore

/// macOS: the system surfaces.
extension URLEventHandler {
  static let systemCommands: [String: CommandDefinition] = [
    "desktop show": surface(.desktop, .show),
    "desktop hide": surface(.desktop, .hide),
    "desktop toggle": surface(.desktop, .toggle),
    "missioncontrol show": surface(.missionControl, .show),
    "missioncontrol hide": surface(.missionControl, .hide),
    "missioncontrol toggle": surface(.missionControl, .toggle),
    "appwindows show": surface(.appWindows, .show),
    "appwindows hide": surface(.appWindows, .hide),
    "appwindows toggle": surface(.appWindows, .toggle),
    "launchpad show": surface(.launchpad, .show),
    "launchpad hide": surface(.launchpad, .hide),
    "launchpad toggle": surface(.launchpad, .toggle),
    "notificationcenter show": surface(.notificationCenter, .show),
    "notificationcenter hide": surface(.notificationCenter, .hide),
    "notificationcenter toggle": surface(.notificationCenter, .toggle),
    "controlcenter show": surface(.controlCenter, .show),
    "controlcenter hide": surface(.controlCenter, .hide),
    "controlcenter toggle": surface(.controlCenter, .toggle),
  ]

  /// `<surface> show|hide|toggle`, which take no arguments.
  static func surface(
    _ surface: SystemSurface, _ visibility: SurfaceVisibility
  ) -> CommandDefinition {
    let command = SystemSurfaceCommand(surface, visibility)
    return .init(command.summary, parse: { _ in .systemSurface(command) })
  }
}
