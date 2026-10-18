import AppKit
import FlashCore

/// Trackpad gestures, emulated from the keyboard the way BetterTouchTool and
/// Mac Mouse Fix emulate them for mice: each finger count and motion does what
/// macOS's default trackpad gesture does, by the most direct means available.
///
/// - Pinch, spread, rotate and smart zoom are posted as real gesture events
///   (the private `NSEventTypeGesture` fields below), so AppKit hands them to
///   `magnify(with:)`, `rotate(with:)` and `smartMagnify(with:)` like a
///   trackpad's own.
/// - Look Up and page back / forward are the focused app's actions
///   (`look_up`, `history_back`, `history_forward`), resolved like any other.
/// - Mission Control, App Exposé, Launchpad and Show Desktop ask the Dock
///   (`CoreDockSendNotification`, Launchpad as the app launcher that
///   replaced it in macOS 26);
///   switching Spaces posts the system's Control-arrow shortcut.
/// - A two-finger tap is a secondary click.
enum TrackpadGesture {
  enum Motion: String, CaseIterable, Hashable {
    case tap
    case doubleTap = "double_tap"
    case pinch, spread
    case rotateLeft = "rotate_left"
    case rotateRight = "rotate_right"
    case swipeLeft = "swipe_left"
    case swipeRight = "swipe_right"
    case swipeUp = "swipe_up"
    case swipeDown = "swipe_down"
  }

  enum Action: Equatable {
    case secondaryClick
    case smartZoom
    case zoom(in: Bool)
    case rotate(counterclockwise: Bool)
    case historyBack, historyForward
    case lookUp
    case missionControl, appExpose, launchpad, showDesktop
    case spaceLeft, spaceRight
  }

  /// What `fingers` doing `motion` does on a Mac trackpad with the default
  /// gestures; nil where macOS has no such gesture. Directions are the
  /// fingers': content follows them, so two fingers swiping right go back
  /// and three swiping left bring in the Space on the right.
  static func action(fingers: Int, motion: Motion) -> Action? {
    switch (fingers, motion) {
    case (2, .tap): return .secondaryClick
    case (2, .doubleTap): return .smartZoom
    case (2, .spread): return .zoom(in: true)
    case (2, .pinch): return .zoom(in: false)
    case (2, .rotateLeft): return .rotate(counterclockwise: true)
    case (2, .rotateRight): return .rotate(counterclockwise: false)
    case (2, .swipeRight): return .historyBack
    case (2, .swipeLeft): return .historyForward
    case (3, .tap): return .lookUp
    case (3, .swipeUp), (4, .swipeUp): return .missionControl
    case (3, .swipeDown), (4, .swipeDown): return .appExpose
    case (3, .swipeLeft), (4, .swipeLeft): return .spaceRight
    case (3, .swipeRight), (4, .swipeRight): return .spaceLeft
    case (4, .pinch), (5, .pinch): return .launchpad
    case (4, .spread), (5, .spread): return .showDesktop
    default: return nil
    }
  }

  // MARK: Gesture events

  /// A gesture AppKit receives as one: magnification (positive zooms in),
  /// rotation in degrees (positive is counterclockwise), smart magnify, or a
  /// swipe.
  enum Synthesized: Equatable {
    case magnify(Double)
    case rotate(Double)
    case smartMagnify
    case swipe(SwipeDirection)
  }

  enum SwipeDirection: Equatable {
    case up, down, left, right

    /// The swipe field's direction bits.
    var bits: Int64 {
      switch self {
      case .up: return 1
      case .down: return 2
      case .left: return 4
      case .right: return 8
      }
    }
  }

  /// One posted event: the gesture type, its phase, its value, and when to
  /// post it after the first, in milliseconds.
  struct EventSpec: Equatable {
    var hidType: Int64
    var phase: Int64?
    var magnification: Double?
    var rotation: Double?
    var swipeDirection: Int64?
    var delayMs: Int
  }

  /// Private `CGEvent` fields of `NSEventTypeGesture` events, as trackpads
  /// post them (verified against AppKit's `magnify(with:)`, `rotate(with:)`,
  /// `smartMagnify(with:)` and `swipe(with:)`).
  enum Field {
    static let eventType: UInt32 = 55
    static let gestureType: UInt32 = 110
    static let magnification: UInt32 = 113
    static let rotation: UInt32 = 114
    static let swipeDirection: UInt32 = 115
    static let phase: UInt32 = 132
  }

  static let gestureEventType: Int64 = 29
  private static let began: Int64 = 1
  private static let changed: Int64 = 2
  private static let ended: Int64 = 4

  /// The events of one gesture: a began, `steps` changes spread over
  /// `durationMs`, and an end, or one event for smart magnify.
  static func events(for gesture: Synthesized, steps: Int = 6, durationMs: Int = 120) -> [EventSpec]
  {
    let stepMs = max(1, durationMs / max(1, steps))
    func stroke(_ type: Int64, _ total: Double, _ value: (Double) -> (Double?, Double?))
      -> [EventSpec]
    {
      var events = [
        EventSpec(
          hidType: type, phase: began, magnification: value(0).0, rotation: value(0).1, delayMs: 0)
      ]
      for step in 1...max(1, steps) {
        let (magnification, rotation) = value(total / Double(max(1, steps)))
        events.append(
          EventSpec(
            hidType: type, phase: changed, magnification: magnification, rotation: rotation,
            delayMs: step * stepMs))
      }
      events.append(
        EventSpec(
          hidType: type, phase: ended, magnification: value(0).0, rotation: value(0).1,
          delayMs: (max(1, steps) + 1) * stepMs))
      return events
    }
    switch gesture {
    case .magnify(let amount): return stroke(8, amount) { ($0, nil) }
    case .rotate(let degrees): return stroke(5, degrees) { (nil, $0) }
    case .smartMagnify: return [EventSpec(hidType: 22, delayMs: 0)]
    case .swipe(let direction):
      return [
        EventSpec(hidType: 16, phase: began, swipeDirection: direction.bits, delayMs: 0),
        EventSpec(hidType: 16, phase: ended, swipeDirection: direction.bits, delayMs: stepMs),
      ]
    }
  }

  /// Post `gesture` at `screenPoint` (NSScreen), on the dispatcher's queue so
  /// it lands after any pointer move queued before it.
  static func post(_ gesture: Synthesized, at screenPoint: CGPoint) {
    let point = CGPoint(x: screenPoint.x, y: ScreenSpace.primaryHeight - screenPoint.y)
    let start = DispatchTime.now()
    for spec in events(for: gesture) {
      ActionDispatcher.clickQueue.asyncAfter(deadline: start + .milliseconds(spec.delayMs)) {
        guard let event = CGEvent(source: nil),
          let type = CGEventField(rawValue: Field.eventType),
          let gestureType = CGEventField(rawValue: Field.gestureType)
        else { return }
        event.setIntegerValueField(type, value: gestureEventType)
        event.setIntegerValueField(gestureType, value: spec.hidType)
        if let phase = spec.phase, let field = CGEventField(rawValue: Field.phase) {
          event.setIntegerValueField(field, value: phase)
        }
        if let value = spec.magnification, let field = CGEventField(rawValue: Field.magnification) {
          event.setDoubleValueField(field, value: value)
        }
        if let value = spec.rotation, let field = CGEventField(rawValue: Field.rotation) {
          event.setDoubleValueField(field, value: value)
        }
        if let value = spec.swipeDirection, let field = CGEventField(rawValue: Field.swipeDirection)
        {
          event.setIntegerValueField(field, value: value)
        }
        event.location = point
        event.setIntegerValueField(
          .eventSourceUserData, value: ActionDispatcher.syntheticMouseEventTag)
        event.post(tap: .cghidEventTap)
      }
    }
  }

  // MARK: The Dock

  /// The app launcher that replaced Launchpad in macOS 26.
  static let appLauncherBundleID = "com.apple.apps.launcher"

  /// Ask the Dock to show App Exposé, Launchpad or the desktop (private
  /// `CoreDockSendNotification`, resolved at run time). Launchpad opens the
  /// system app launcher where it exists, the Dock's Launchpad before it.
  /// False when the Dock does not offer it.
  @discardableResult
  static func dock(_ action: Action) -> Bool {
    let name: String
    switch action {
    case .appExpose: name = "com.apple.expose.front.awake"
    case .launchpad:
      if let launcher = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: appLauncherBundleID)
      {
        NSWorkspace.shared.openApplication(
          at: launcher, configuration: NSWorkspace.OpenConfiguration())
        return true
      }
      name = "com.apple.launchpad.toggle"
    case .showDesktop: name = "com.apple.showdesktop.awake"
    default: return false
    }
    return SystemKeyboard.sendDockNotification(name)
  }
}
