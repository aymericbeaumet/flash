import Foundation

/// When Flash, left the active app by one of its own surfaces, hands
/// activation back to the app behind.
///
/// Flash takes activation only for a surface that types: the command line,
/// a key-window hint session, About, a focused terminal popup. Leaving one
/// does not always give it back, and `NSApp.deactivate()` is ignored on this
/// macOS. In INSERT that is the one state that breaks typing: every key the
/// tap passes, Command chords included, reaches Flash instead of the window
/// that looks focused. NORMAL needs no hand-back, since the tap takes its
/// keys whoever is active.
enum IdleActivation {
  /// True when Flash, active while showing `mode`, must hand activation
  /// back. About and a hint session (which may read its labels through the
  /// key window) keep it, and so does a physical click still handing focus
  /// to the app it landed on: that click moves activation itself, and a
  /// hand-back could race it to the wrong app.
  static func handsBack(
    flashActive: Bool, mode: Mode, aboutWindowVisible: Bool, hintSessionActive: Bool,
    pointerClickPending: Bool
  ) -> Bool {
    guard flashActive, mode == .insert else { return false }
    return !aboutWindowVisible && !hintSessionActive && !pointerClickPending
  }
}
