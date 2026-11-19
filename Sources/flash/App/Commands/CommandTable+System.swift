import AppKit
import FlashCore

/// macOS: Apple's catalogs and system surfaces.
extension URLEventHandler {
  static let systemCommands: [String: CommandDefinition] = [
    "notes open": .init(
      AppleCatalogCommand.open(.notes).summary, parse: { _ in .appleCatalog(.open(.notes)) }),
    "notes refresh": .init(
      AppleCatalogCommand.refresh(.notes).summary, parse: { _ in .appleCatalog(.refresh(.notes)) }),
    "reminders open": .init(
      AppleCatalogCommand.open(.reminders).summary, parse: { _ in .appleCatalog(.open(.reminders)) }
    ),
    "reminders refresh": .init(
      AppleCatalogCommand.refresh(.reminders).summary,
      parse: { _ in .appleCatalog(.refresh(.reminders)) }),
    "contacts open": .init(
      AppleCatalogCommand.open(.contacts).summary, parse: { _ in .appleCatalog(.open(.contacts)) }),
    "contacts refresh": .init(
      AppleCatalogCommand.refresh(.contacts).summary,
      parse: { _ in .appleCatalog(.refresh(.contacts)) }),
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
