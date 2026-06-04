import AppKit
import Foundation

/// Owns the app-switch hotkey lifecycle.
///
/// On every `apply(shortcuts:dispatch:)` the Carbon registration set
/// is rebuilt from scratch. AOT: parsing of the hotkey LHS and the
/// URL/argv value happens here, before any keypress arrives. The hot
/// path on a Carbon callback is one switch over the pre-resolved
/// `ShortcutAction`.
///
/// Dispatch policy:
///   - `flashCommand` → fed back to the shared `URLCommand` handler
///     (the same one `URLEventHandler` uses for live `flash://...`
///     URLs from `open` / `osascript`). All in-process; no shell-out.
///   - `openable` → `NSWorkspace.shared.open` (Launch Services).
///   - `shell` → `Process` exec with the argv as-is. Off the main
///     thread so a slow spawn never blocks the next hotkey.
final class ShortcutsCoordinator {

  private let hotkeys = HotKeyManager()
  private var flashDispatch: ((URLCommand) -> Void)?

  func start(dispatch: @escaping (URLCommand) -> Void) {
    flashDispatch = dispatch
  }

  func stop() {
    hotkeys.unregisterAll()
    flashDispatch = nil
  }

  func apply(shortcuts: [Shortcut]) {
    hotkeys.unregisterAll()
    for shortcut in shortcuts {
      guard let parsed = HotkeySyntax.parse(hotkey: shortcut.hotkey) else {
        FlashLog.warn(
          "[shortcuts] could not parse hotkey \"\(shortcut.hotkey)\"")
        continue
      }
      let action = shortcut.action
      let ok = hotkeys.register(
        modifiers: parsed.modifiers, virtualKey: parsed.virtualKey
      ) { [weak self] in
        self?.fire(action)
      }
      if !ok {
        FlashLog.warn(
          "[shortcuts] could not register \"\(shortcut.hotkey)\" — "
            + "another app may already own this hotkey")
      }
    }
  }

  // MARK: - Hot path

  private func fire(_ action: ShortcutAction) {
    switch action {
    case .flashCommand(let cmd):
      flashDispatch?(cmd)
    case .shell(let argv):
      runShell(argv)
    }
  }

  private func runShell(_ argv: [String]) {
    guard let executable = argv.first else { return }
    // Background spawn — a slow process must not block the next
    // hotkey callback. Process.run() itself is fork+exec and
    // typically ~5-10ms; queueing it off-main keeps the Carbon
    // event loop unblocked.
    DispatchQueue.global(qos: .userInitiated).async {
      let task = Process()
      // Treat unqualified executables as commands on PATH by
      // delegating to /usr/bin/env. Absolute paths skip env.
      if executable.contains("/") {
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = Array(argv.dropFirst())
      } else {
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = argv
      }
      do {
        try task.run()
      } catch {
        FlashLog.error(
          "[shortcuts] shell exec failed for \(argv): \(error)")
      }
    }
  }
}
