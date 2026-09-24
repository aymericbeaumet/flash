import AppKit
import Carbon.HIToolbox

/// The live Text Input Sources reads behind `KeyboardLayout`. Main thread.
enum InputSources {
  struct Current: Equatable {
    var id: String?
    var asciiCapable: Bool
  }

  /// The selected keyboard input source (a layout or an input method).
  static func current() -> Current {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
      return Current(id: nil, asciiCapable: true)
    }
    return Current(
      id: string(source, kTISPropertyInputSourceID),
      asciiCapable: bool(source, kTISPropertyInputSourceIsASCIICapable) ?? true)
  }

  /// The ASCII-capable layout the system pairs with the current source (the
  /// one a Russian or Japanese user switches to for Latin text).
  static func asciiCapableLayout() -> KeyboardLayout? {
    TISCopyCurrentASCIICapableKeyboardLayoutInputSource().flatMap {
      layout(of: $0.takeRetainedValue())
    }
  }

  /// The layout the current source types with; for `flash doctor`.
  static func currentLayout() -> KeyboardLayout? {
    TISCopyCurrentKeyboardLayoutInputSource().flatMap { layout(of: $0.takeRetainedValue()) }
  }

  /// An installed input source by ID, enabled or not.
  static func layout(id: String) -> KeyboardLayout? {
    let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
    guard
      let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue()
        as? [TISInputSource],
      let source = list.first
    else { return nil }
    return layout(of: source)
  }

  private static func layout(of source: TISInputSource) -> KeyboardLayout? {
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
      return nil
    }
    let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    return KeyboardLayout.translating(
      layoutData: data, sourceID: string(source, kTISPropertyInputSourceID) ?? "unknown",
      keyboardType: UInt32(LMGetKbdType()))
  }

  private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
    TISGetInputSourceProperty(source, key).map {
      Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
    }
  }

  private static func bool(_ source: TISInputSource, _ key: CFString) -> Bool? {
    TISGetInputSourceProperty(source, key).map {
      CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue())
    }
  }
}

/// Owns the reference table of `[app] keyboard_layout`. It is rebuilt when
/// the selected input source changes (a distributed notification) and on
/// every config load — never on a keypress, whose path only reads the table
/// the overlay holds.
final class KeyboardLayoutMonitor {
  struct State: Equatable {
    var inputSourceID: String?
    var reference = KeyboardLayout.Reference()
  }

  private(set) var state = State()
  private var setting = KeyboardLayout.Setting.auto
  private var observer: NSObjectProtocol?
  /// Receives every changed state on the main thread.
  var onChange: ((State) -> Void)?

  deinit {
    if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
  }

  /// Adopt the configured setting and rebuild. Called on every config load.
  func apply(setting: KeyboardLayout.Setting) {
    self.setting = setting
    if observer == nil {
      observer = DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
        object: nil, queue: .main
      ) { [weak self] _ in self?.rebuild(reason: "input_source_changed") }
    }
    rebuild(reason: "config")
  }

  private func rebuild(reason: String) {
    let current = InputSources.current()
    let reference = KeyboardLayout.reference(
      setting: setting, currentIsASCIICapable: current.asciiCapable,
      asciiCapableLayout: InputSources.asciiCapableLayout,
      namedLayout: InputSources.layout(id:))
    let next = State(inputSourceID: current.id, reference: reference)
    guard next != state else { return }
    if let missing = reference.missingSourceID, missing != state.reference.missingSourceID {
      FlashLog.warn(
        "[keyboard] app.keyboard_layout names \(missing), which is not an installed "
          + "keyboard layout; reading keys as US-ANSI")
    }
    FlashLog.debug(
      "[keyboard] layout reason=\(reason) source=\(current.id ?? "unknown") "
        + "reference=\(reference.table?.sourceID ?? "none")")
    state = next
    onChange?(next)
  }
}
