import AppKit
import FlashCore

/// macOS: sound, Apple's catalogs, system surfaces, power, appearance and processes.
extension URLEventHandler {
  static let systemCommands: [String: CommandDefinition] = [
    "volume up": .init(
      "Raise the output volume one step", parse: { _ in .media(.volumeUp) }),
    "volume down": .init(
      "Lower the output volume one step", parse: { _ in .media(.volumeDown) }),
    "volume mute": .init(
      "Mute or unmute the output", parse: { _ in .media(.volumeMute) }),
    "audio input": .init(
      "List the input devices, or select one with --device", [.text("device", "name-or-uid")],
      parse: { audioDeviceCommand(.input, $0) }),
    "audio output": .init(
      "List the output devices, or select one with --device", [.text("device", "name-or-uid")],
      parse: { audioDeviceCommand(.output, $0) }),
    "media status": .init(
      "Show what the media apps are playing and the volume", parse: { _ in .media(.status) }),
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
    "calendar join": .init(CalendarCommand.join.summary, parse: { _ in .calendar(.join) }),
    "calendar next": .init(CalendarCommand.next.summary, parse: { _ in .calendar(.next) }),
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
    "screen lock": .init(
      "Lock the screen", parse: { a in a.args.isEmpty ? .systemAction(.screenLock) : nil }),
    "system sleep": .init(
      "Sleep the Mac", parse: { a in a.args.isEmpty ? .systemAction(.systemSleep) : nil }),
    "display sleep": .init(
      "Turn the displays off", parse: { a in a.args.isEmpty ? .systemAction(.displaySleep) : nil }),
    "system restart": .init(
      "Restart the Mac, after asking",
      parse: { a in
        a.args.isEmpty ? .systemAction(.systemRestart) : nil
      }),
    "system shutdown": .init(
      "Shut the Mac down, after asking",
      parse: { a in
        a.args.isEmpty ? .systemAction(.systemShutdown) : nil
      }),
    "system logout": .init(
      "Log out, after asking", parse: { a in a.args.isEmpty ? .systemAction(.systemLogout) : nil }),
    "trash empty": .init(
      "Empty the Trash, after asking",
      parse: { a in a.args.isEmpty ? .systemAction(.trashEmpty) : nil }),
    "appearance toggle": .init(
      "Switch between light and dark appearance",
      parse: { a in
        a.args.isEmpty ? .systemAction(.darkModeToggle) : nil
      }),
    "screensaver start": .init(
      "Start the screen saver",
      parse: { a in
        a.args.isEmpty ? .systemAction(.screensaverStart) : nil
      }),
    "process kill": .init(
      "Terminate one process, after asking", [.integer("pid", required: true)],
      parse: { a in
        guard let pid = a.int("pid").flatMap({ pid_t(exactly: $0) }), pid > 1 else { return nil }
        return .processKill(pid: pid)
      }),
  ]

  /// `<surface> show|hide|toggle`, which take no arguments.
  static func surface(
    _ surface: SystemSurface, _ visibility: SurfaceVisibility
  ) -> CommandDefinition {
    let command = SystemSurfaceCommand(surface, visibility)
    return .init(command.summary, parse: { _ in .systemSurface(command) })
  }

  /// `audio input` / `audio output`: no `--device` lists the devices; a device
  /// is a name or UID, never blank.
  static func audioDeviceCommand(_ direction: AudioDeviceDirection, _ a: CommandArgs) -> URLCommand?
  {
    guard let device = a.value("device") else { return .media(.device(direction, query: nil)) }
    let query = device.trimmed
    guard !query.isEmpty else { return nil }
    return .media(.device(direction, query: query))
  }
}
