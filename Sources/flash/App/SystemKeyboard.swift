import AppKit

/// The printed Apple function row, and the plain F-keys behind it.
///
/// Hyper+1…9, 0, -, + follow the icons: brightness, Mission Control,
/// Spotlight, Dictation, Focus, media, mute, and volume. Shift+Hyper sends
/// F1–F12. Special keys are posted as system events, the same path as the
/// keyboard. Mission Control is no key event on recent macOS (a posted 160
/// reaches nothing): Hyper+3 is `missioncontrol toggle`, which asks the Dock
/// (`SystemSurfaceController`). F-keys are ordinary keystrokes to the
/// focused app.
enum SystemKeyboard {
  /// One macOS function-row action, in F1…F12 order; F3, Mission Control,
  /// is a system surface instead (`missioncontrol toggle`).
  enum RowKey: String, CaseIterable {
    case brightnessDown = "brightness_down"
    case brightnessUp = "brightness_up"
    case spotlight
    case dictation
    case focus
    case mediaPrevious = "media_previous"
    case mediaPlay = "media_play"
    case mediaNext = "media_next"
    case mute
    case volumeDown = "volume_down"
    case volumeUp = "volume_up"

    static func named(_ raw: String) -> RowKey? {
      allCases.first { $0.rawValue == raw.lowercased() }
    }
  }

  /// Where every synthesized event goes: the HID tap, as the keyboard's own
  /// keys arrive. Tests swap it to count events without posting them.
  static var eventPoster: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }

  /// NX_KEYTYPE values from `IOKit/hidsystem/ev_keymap.h`.
  private enum Auxiliary {
    static let soundUp = 0
    static let soundDown = 1
    static let brightnessUp = 2
    static let brightnessDown = 3
    static let mute = 7
    static let play = 16
    static let next = 17
    static let previous = 18
  }

  static func perform(_ key: RowKey) {
    switch key {
    case .brightnessDown: postAuxiliary(Auxiliary.brightnessDown)
    case .brightnessUp: postAuxiliary(Auxiliary.brightnessUp)
    case .spotlight: postNamedKey("space", flags: .maskCommand)
    case .dictation: postNamedKey("f5", flags: .maskSecondaryFn)
    case .focus: postNamedKey("f6", flags: .maskSecondaryFn)
    case .mediaPrevious: postAuxiliary(Auxiliary.previous)
    case .mediaPlay: postAuxiliary(Auxiliary.play)
    case .mediaNext: postAuxiliary(Auxiliary.next)
    case .mute: postAuxiliary(Auxiliary.mute)
    case .volumeDown: postAuxiliary(Auxiliary.soundDown)
    case .volumeUp: postAuxiliary(Auxiliary.soundUp)
    }
  }

  /// Move to the Space on the left or right: the system's Control-arrow
  /// shortcut, what a three-finger horizontal swipe does.
  static func switchSpace(toTheRight: Bool) {
    postNamedKey(toTheRight ? "right" : "left", flags: .maskControl)
  }

  private static func postNamedKey(_ name: String, flags: CGEventFlags = []) {
    guard let key = HotkeySyntax.parseKey(name) else { return }
    postKey(CGKeyCode(key), flags: flags)
  }

  /// NX_KEYDOWN (0x0A) then NX_KEYUP (0x0B), subtype 8
  /// (`NX_SUBTYPE_AUX_CONTROL_BUTTONS`).
  @discardableResult
  static func postAuxiliary(_ code: Int) -> Bool {
    for state in [0x0A, 0x0B] {
      let data1 = (code << 16) | (state << 8)
      guard
        let event = NSEvent.otherEvent(
          with: .systemDefined,
          location: .zero,
          modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
          timestamp: 0,
          windowNumber: 0,
          context: nil,
          subtype: 8,
          data1: data1,
          data2: -1),
        let cgEvent = event.cgEvent
      else { return false }
      cgEvent.setIntegerValueField(
        .eventSourceUserData, value: NormalModeDispatcher.syntheticKeyEventTag)
      eventPoster(cgEvent)
    }
    return true
  }

  static func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
    let source = SyntheticEventSources.hid
    guard
      let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
    else { return }
    down.flags = flags
    up.flags = flags
    down.setIntegerValueField(
      .eventSourceUserData, value: NormalModeDispatcher.syntheticKeyEventTag)
    up.setIntegerValueField(
      .eventSourceUserData, value: NormalModeDispatcher.syntheticKeyEventTag)
    eventPoster(down)
    eventPoster(up)
  }
}
