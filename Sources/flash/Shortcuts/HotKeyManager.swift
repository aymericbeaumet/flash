import AppKit
import Carbon.HIToolbox
import Foundation

/// Carbon-backed system-level hotkey registry. `RegisterEventHotKey`
/// catches keypresses BEFORE they reach the focused application,
/// matching what skhd / Karabiner do — and far less expensive than
/// `NSEvent.addGlobalMonitorForEvents`, which only observes events
/// after the OS has already routed them.
///
/// The event handler runs on the main run loop (where Carbon's
/// dispatcher target lives); each registration's `onFire` closure runs
/// synchronously inline, so the hot path from keypress to callback
/// is sub-millisecond.
final class HotKeyManager {

  private var registrations: [UInt32: EventHotKeyRef] = [:]
  private var routerIDsByChord: [ParsedHotkey: UInt32] = [:]
  private let router = HotKeyEventRouter()
  private var eventHandlerRef: EventHandlerRef?

  var registeredChords: Set<ParsedHotkey> { Set(routerIDsByChord.keys) }

  init() {
    installEventHandler()
  }

  deinit {
    unregisterAll()
    if let h = eventHandlerRef { RemoveEventHandler(h) }
  }

  /// Register a hotkey. Returns `noErr` when Carbon accepted the registration.
  /// macOS will refuse if another process already owns the same
  /// (modifiers, virtualKey) combo — in that case we log + skip.
  @discardableResult
  func register(
    modifiers: UInt32, virtualKey: UInt32, onFire: @escaping () -> Void
  ) -> OSStatus {
    register(ParsedHotkey(modifiers: modifiers, virtualKey: virtualKey), onFire: onFire)
  }

  @discardableResult
  func register(_ chord: ParsedHotkey, onFire: @escaping () -> Void) -> OSStatus {
    let hotKeyID = router.register(onFire: onFire)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      chord.virtualKey, chord.modifiers, hotKeyID,
      GetEventDispatcherTarget(), 0, &ref)
    guard status == noErr, let ref else {
      router.remove(id: hotKeyID.id)
      return status == noErr ? OSStatus(paramErr) : status
    }
    registrations[hotKeyID.id] = ref
    routerIDsByChord[chord] = hotKeyID.id
    return noErr
  }

  func unregister(_ chord: ParsedHotkey) {
    guard let id = routerIDsByChord.removeValue(forKey: chord) else { return }
    if let ref = registrations.removeValue(forKey: id) {
      UnregisterEventHotKey(ref)
    }
    router.remove(id: id)
  }

  struct ReconcileResult {
    var added = 0
    var removed = 0
    var refused: [ParsedHotkey] = []
  }

  /// Bring the registration set to exactly `desired` with the minimum Carbon
  /// churn: chords that stay registered are untouched, so a NORMAL↔INSERT
  /// scope change or a config reload only touches the chords that actually
  /// differ. `onFire` receives the chord so callbacks stay mapping-independent
  /// and a kept registration dispatches whatever the current scope resolves.
  @discardableResult
  func reconcile(
    desired: Set<ParsedHotkey>, onFire: @escaping (ParsedHotkey) -> Void
  ) -> ReconcileResult {
    var result = ReconcileResult()
    for chord in routerIDsByChord.keys where !desired.contains(chord) {
      unregister(chord)
      result.removed += 1
    }
    for chord in desired where routerIDsByChord[chord] == nil {
      if register(chord, onFire: { onFire(chord) }) == noErr {
        result.added += 1
      } else {
        result.refused.append(chord)
      }
    }
    return result
  }

  /// Drop every previously-registered hotkey.
  func unregisterAll() {
    for ref in registrations.values {
      UnregisterEventHotKey(ref)
    }
    registrations.removeAll()
    routerIDsByChord.removeAll()
    router.removeAll()
  }

  private func installEventHandler() {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed))
    let userData = Unmanaged.passUnretained(self).toOpaque()
    let callback: EventHandlerUPP = { (_, event, userData) -> OSStatus in
      guard let userData else { return OSStatus(eventNotHandledErr) }
      let manager = Unmanaged<HotKeyManager>.fromOpaque(userData)
        .takeUnretainedValue()
      return manager.router.handle(event: event)
    }
    InstallEventHandler(
      GetEventDispatcherTarget(),
      callback,
      1, &eventType, userData, &eventHandlerRef)
  }
}

/// Each Carbon handler must decline events owned by another manager so the
/// dispatcher can continue through the handler chain. IDs remain unique across
/// managers and reloads, including delayed events for removed registrations.
final class HotKeyEventRouter {
  private static let signature: OSType = 0x66_6C_48_53  // flHS
  private static let idLock = NSLock()
  private static var nextID: UInt32 = 1
  private var callbacks: [UInt32: () -> Void] = [:]

  func register(onFire: @escaping () -> Void) -> EventHotKeyID {
    Self.idLock.lock()
    let id = Self.nextID
    Self.nextID += 1
    Self.idLock.unlock()
    callbacks[id] = onFire
    return EventHotKeyID(signature: Self.signature, id: id)
  }

  func remove(id: UInt32) {
    callbacks.removeValue(forKey: id)
  }

  func removeAll() {
    callbacks.removeAll()
  }

  func handle(event: EventRef?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let result = GetEventParameter(
      event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID), nil,
      MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard result == noErr, hotKeyID.signature == Self.signature,
      let callback = callbacks[hotKeyID.id]
    else { return OSStatus(eventNotHandledErr) }
    callback()
    return noErr
  }
}
