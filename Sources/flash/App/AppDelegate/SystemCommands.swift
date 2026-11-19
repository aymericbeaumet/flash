import AppKit
import FlashCore

/// The system-surface verbs Flash performs itself, and the lock chord it
/// posts for `host.system_action`. No path here blocks main: the surfaces
/// run on their controller's queue.
extension AppDelegate {
  /// `<surface> show|hide|toggle`, the trackpad gestures for the same
  /// surfaces and Hyper+3: `SystemSurfaceController` runs them off main, one
  /// at a time. `completion` gets nil once done, or why it could not be;
  /// without one, a failure shows in the centred alert.
  func performSystemSurface(
    _ command: SystemSurfaceCommand, completion: ((String?) -> Void)? = nil
  ) {
    systemSurfaces.perform(command) { [weak self] failure in
      if let completion { return completion(failure) }
      guard let failure else { return }
      self?.overlay.displayAlert(.message(failure, style: .error))
    }
  }

  /// macOS's Lock Screen shortcut, posted to the session the way any global
  /// key is: noted first, so the Carbon path does not take the echo for the
  /// user's own binding of the same chord. The lock mechanism of
  /// `LiveSystemActions`; called on main.
  func postLockScreenChord() -> Bool {
    guard let chord = HotkeySyntax.parse(hotkey: SystemActionExecution.lockScreenShortcut) else {
      return false
    }
    mappings.noteSyntheticKey(virtualKey: chord.virtualKey, flags: chord.eventFlags)
    return NormalModeDispatcher.sendGlobalKey(
      virtualKey: CGKeyCode(chord.virtualKey), flags: chord.eventFlags)
  }
}
