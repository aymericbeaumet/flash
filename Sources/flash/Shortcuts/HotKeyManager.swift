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

  /// One registered hotkey. Holds the Carbon `EventHotKeyRef` so
  /// `UnregisterEventHotKey` can be paired with the original
  /// `RegisterEventHotKey` call, plus the user-supplied callback.
  private struct Registration {
    let id: UInt32
    let ref: EventHotKeyRef
    let onFire: () -> Void
  }

  private var registrations: [UInt32: Registration] = [:]
  private var nextID: UInt32 = 1
  private var eventHandlerRef: EventHandlerRef?
  /// 'flHS' (Flash HotKey System) — distinguishes our registrations
  /// from any other Carbon hotkey client in the same process. Carbon
  /// requires per-app uniqueness on (signature, id) tuples.
  private let signature: OSType = 0x66_6C_48_53

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
    let id = nextID
    nextID += 1
    let hotKeyID = EventHotKeyID(signature: signature, id: id)
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      virtualKey, modifiers, hotKeyID,
      GetEventDispatcherTarget(), 0, &ref)
    guard status == noErr, let ref else {
      return status == noErr ? OSStatus(paramErr) : status
    }
    registrations[id] = Registration(id: id, ref: ref, onFire: onFire)
    return noErr
  }

  /// Drop every previously-registered hotkey. Used before reloading
  /// mode mappings so a removed line stops responding immediately.
  func unregisterAll() {
    for (_, b) in registrations {
      UnregisterEventHotKey(b.ref)
    }
    registrations.removeAll()
  }

  fileprivate func fire(id: UInt32) {
    registrations[id]?.onFire()
  }

  private func installEventHandler() {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed))
    let userData = Unmanaged.passUnretained(self).toOpaque()
    let callback: EventHandlerUPP = { (_, event, userData) -> OSStatus in
      guard let userData, let event else { return noErr }
      let manager = Unmanaged<HotKeyManager>.fromOpaque(userData)
        .takeUnretainedValue()
      var hotKeyID = EventHotKeyID()
      let result = GetEventParameter(
        event,
        OSType(kEventParamDirectObject),
        OSType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID)
      guard result == noErr else { return noErr }
      manager.fire(id: hotKeyID.id)
      return noErr
    }
    InstallEventHandler(
      GetEventDispatcherTarget(),
      callback,
      1, &eventType, userData, &eventHandlerRef)
  }
}
