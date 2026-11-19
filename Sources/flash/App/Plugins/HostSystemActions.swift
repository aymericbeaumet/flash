import AppKit
import FlashCore
import Foundation
import IOKit
import IOKit.pwr_mgt

/// One `host.system_action` action (`protocol.json` `system_actions`): the
/// machine and session actions the host carries out for a plugin holding the
/// `system_actions` capability. The raw value is the name on the wire.
enum HostSystemAction: String, CaseIterable, Equatable {
  case lockScreen = "lock_screen"
  case sleep
  case displaySleep = "display_sleep"
  case screensaver
  case toggleAppearance = "toggle_appearance"
  case restart
  case shutdown
  case logout
  case emptyTrash = "empty_trash"

  /// Nothing undoes it: honoured only inside a perform the user confirmed
  /// (`system_actions.destructive`).
  var isDestructive: Bool {
    switch self {
    case .restart, .shutdown, .logout, .emptyTrash: return true
    case .lockScreen, .sleep, .displaySleep, .screensaver, .toggleAppearance: return false
    }
  }

  /// How the host carries it out.
  var execution: SystemActionExecution {
    switch self {
    case .lockScreen: return .lockScreenChord
    case .sleep: return .sleepSystem
    case .displaySleep: return .sleepDisplays
    case .screensaver: return .startScreensaver
    case .restart:
      return .appleScript("tell application \"System Events\" to restart", timeout: 10)
    case .shutdown:
      return .appleScript("tell application \"System Events\" to shut down", timeout: 10)
    case .logout:
      return .appleScript("tell application \"System Events\" to log out", timeout: 10)
    case .emptyTrash:
      return .appleScript("tell application \"Finder\" to empty trash", timeout: 30)
    case .toggleAppearance:
      return .appleScript(
        "tell application \"System Events\" to tell appearance preferences to "
          + "set dark mode to not dark mode", timeout: 10)
    }
  }
}

/// The mechanism behind one system action.
enum SystemActionExecution: Equatable {
  /// macOS's own Lock Screen shortcut, posted to the session through the
  /// global-key path: macOS locks, Flash synthesizes no app chord.
  case lockScreenChord
  /// `pmset sleepnow` without the subprocess.
  case sleepSystem
  /// `pmset displaysleepnow` without the subprocess.
  case sleepDisplays
  case startScreensaver
  /// An Apple Event to System Events or Finder, from a fixed host script.
  case appleScript(String, timeout: TimeInterval)

  /// Control-Command-Q, in Flash's key syntax.
  static let lockScreenShortcut = "ctrl+cmd+q"
}

/// Carries a system action out. The resident wires `LiveSystemActions` at
/// launch; nothing is wired inside the test runner, where a test injects its
/// own, so no test can lock, sleep, restart, shut down or log out the Mac,
/// empty the Trash, change the appearance or start the screen saver.
protocol SystemActionPerforming {
  /// Carry `execution` out and answer nil, or why it failed. The lock chord
  /// is asked for on main; every other mechanism on `HostSystemActions.queue`,
  /// never main: a power request or an Apple Event can wait seconds.
  func perform(_ execution: SystemActionExecution) -> String?
}

enum HostSystemActions {
  /// One action at a time, off main and off every plugin's queue.
  static let queue = DispatchQueue(label: "flash.system-actions", qos: .userInitiated)

  /// The queue `execution` runs on.
  static func queue(for execution: SystemActionExecution) -> DispatchQueue {
    execution == .lockScreenChord ? .main : queue
  }

  /// False inside the test runner: the real mechanisms answer a refusal
  /// there, whoever reaches them.
  static let mechanismsAllowed = NSClassFromString("XCTestCase") == nil
  static let inertReason = "system actions are inert inside the test runner"
}

/// The resident's mechanisms: the lock chord through the global-key path,
/// power management through IOKit, the screen saver through NSWorkspace, and
/// the Apple Events through the in-process `AppleScriptRunner`.
struct LiveSystemActions: SystemActionPerforming {
  /// Posts macOS's Lock Screen shortcut; called on main.
  let lockScreen: () -> Bool
  var appleScript: (String, TimeInterval) -> AppleScriptOutput = { source, timeout in
    guard HostSystemActions.mechanismsAllowed else {
      return AppleScriptOutput(status: -1, stdout: "", stderr: HostSystemActions.inertReason)
    }
    return AppleScriptRunner.run(source, timeout: timeout)
  }

  func perform(_ execution: SystemActionExecution) -> String? {
    switch execution {
    case .lockScreenChord:
      return lockScreen() ? nil : "lock screen shortcut unavailable"
    case .sleepSystem:
      return Self.sleepSystem()
    case .sleepDisplays:
      return Self.sleepDisplays()
    case .startScreensaver:
      return Self.startScreensaver()
    case .appleScript(let source, let timeout):
      return appleScript(source, timeout).failure
    }
  }

  private static func sleepSystem() -> String? {
    guard HostSystemActions.mechanismsAllowed else { return HostSystemActions.inertReason }
    let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
    guard port != IO_OBJECT_NULL else { return "power management unavailable" }
    defer { IOServiceClose(port) }
    let result = IOPMSleepSystem(port)
    return result == kIOReturnSuccess ? nil : "IOPMSleepSystem returned \(result)"
  }

  /// The display wrangler's idle request, as `pmset displaysleepnow` makes it.
  private static func sleepDisplays() -> String? {
    guard HostSystemActions.mechanismsAllowed else { return HostSystemActions.inertReason }
    let wrangler = IORegistryEntryFromPath(
      kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
    guard wrangler != IO_OBJECT_NULL else { return "display wrangler unavailable" }
    defer { IOObjectRelease(wrangler) }
    let result = IORegistryEntrySetCFProperty(
      wrangler, "IORequestIdle" as CFString, kCFBooleanTrue)
    return result == KERN_SUCCESS ? nil : "IORequestIdle returned \(result)"
  }

  private static func startScreensaver() -> String? {
    guard HostSystemActions.mechanismsAllowed else { return HostSystemActions.inertReason }
    guard
      let url = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.ScreenSaverEngine")
    else { return "no ScreenSaverEngine" }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) {
      _, error in
      if let error {
        FlashLog.warn("[system] screensaver start failed: \(error.localizedDescription)")
      }
    }
    return nil
  }
}
