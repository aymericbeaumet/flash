import AppKit
import Carbon.HIToolbox
import Foundation

/// Owns the native modified-key mapping lifecycle.
///
/// On every `apply(mode:)` the Carbon registration set is rebuilt from
/// scratch. AOT: parsing of the mapping lhs and URL value happens at
/// config load, before any keypress arrives. The hot path on a Carbon
/// callback is one switch over the pre-resolved `MappingCommand`.
///
/// Dispatch policy:
///   - `flashCommand` → fed back to the shared `URLCommand` handler
///     (the same one `URLEventHandler` uses for live `flash://...`
///     URLs from `open` / `osascript`). All in-process; no shell-out.
///   - `shellCommand` → launched as an argv array exactly because the
///     user configured that explicit native mapping.
final class MappingsCoordinator {

  private struct ActiveMapping {
    let parsed: ParsedHotkey
    let scope: ModeScope
    let mapping: ModeMapping
  }

  private let hotkeys = HotKeyManager()
  private var mappingDispatch: ((MappingCommand) -> Void)?
  private var currentMode: (() -> FlashMode)?
  private var activeMappings: [ActiveMapping] = []
  private var configuredMode: Config.Mode = .init()
  private var lastAppliedFlashMode: FlashMode = .insert
  private var lastFireDiagnostic: String?
  private var lastFireAt: Date = .distantPast

  func start(dispatch: @escaping (MappingCommand) -> Void, currentMode: @escaping () -> FlashMode) {
    mappingDispatch = dispatch
    self.currentMode = currentMode
  }

  func stop() {
    hotkeys.unregisterAll()
    mappingDispatch = nil
    currentMode = nil
  }

  func apply(mode: Config.Mode) {
    configuredMode = mode
    rebuild(for: lastAppliedFlashMode)
  }

  /// Re-register Carbon hotkeys for the current flash mode. The mode
  /// matters for scope == .normal / .insert because Carbon registrations
  /// are global — a registered .normal hotkey would still **consume**
  /// the key combo system-wide while in insert mode, leaving it without
  /// a dispatch path. That's broken for system shortcuts like `cmd+tab`:
  /// the user expects them to pass through to the Dock when Flash is in
  /// insert. Re-registering on mode flips lets scope-bound shortcuts
  /// switch between "Flash captures" and "system handles".
  func applyForFlashMode(_ flashMode: FlashMode) {
    guard flashMode != lastAppliedFlashMode else { return }
    rebuild(for: flashMode)
  }

  private func rebuild(for flashMode: FlashMode) {
    lastAppliedFlashMode = flashMode
    hotkeys.unregisterAll()
    activeMappings.removeAll(keepingCapacity: true)
    for (scope, mapping) in Self.nativeMappings(in: configuredMode) {
      guard Self.scopeIsActive(scope, for: flashMode) else { continue }
      guard let parsed = HotkeySyntax.parse(hotkey: mapping.key) else {
        if mapping.key.contains("+") {
          FlashLog.warn("[mappings] could not parse native mapping \"\(mapping.key)\"")
        }
        continue
      }
      activeMappings.append(ActiveMapping(parsed: parsed, scope: scope, mapping: mapping))
      let status = hotkeys.register(
        modifiers: parsed.modifiers, virtualKey: parsed.virtualKey
      ) { [weak self] in
        self?.fire(mapping, scope: scope, parsed: parsed)
      }
      if status == noErr {
        FlashLog.debug("[mappings] registered \"\(mapping.key)\"")
      } else {
        FlashLog.warn(
          "[mappings] could not register \"\(mapping.key)\" — "
            + "status=\(status); another app may already own this hotkey")
      }
    }
  }

  static func scopeIsActive(_ scope: ModeScope, for flashMode: FlashMode) -> Bool {
    switch scope {
    case .all: return true
    case .normal: return flashMode == .normal
    case .insert: return flashMode == .insert
    }
  }

  // MARK: - Hot path

  func handle(event: NSEvent) -> Bool {
    let modifiers = Self.carbonModifiers(from: event.modifierFlags)
    let virtualKey = UInt32(event.keyCode)
    guard
      let active = activeMappings.first(where: {
        $0.parsed.modifiers == modifiers && $0.parsed.virtualKey == virtualKey
      })
    else {
      return false
    }
    fire(active.mapping, scope: active.scope, parsed: active.parsed)
    return true
  }

  private func fire(_ mapping: ModeMapping, scope: ModeScope, parsed: ParsedHotkey) {
    guard mappingApplies(scope: scope, parsed: parsed) else { return }
    let diagnostic = mapping.action.diagnosticDescription
    let now = Date()
    if lastFireDiagnostic == diagnostic, now.timeIntervalSince(lastFireAt) < 0.08 {
      return
    }
    lastFireDiagnostic = diagnostic
    lastFireAt = now
    FlashLog.debug("[mappings] fired \(diagnostic)")
    mappingDispatch?(mapping.action)
  }

  private func mappingApplies(scope: ModeScope, parsed: ParsedHotkey) -> Bool {
    Self.mappingApplies(scope: scope, currentMode: currentMode?(), modifiers: parsed.modifiers)
  }

  static func mappingApplies(
    scope: ModeScope,
    currentMode: FlashMode?,
    modifiers: UInt32
  ) -> Bool {
    guard scope != .all else { return true }
    guard let current = currentMode else { return false }
    switch (scope, current) {
    case (.normal, .normal), (.insert, .insert):
      return true
    default:
      return false
    }
  }

  private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    let independent = flags.intersection(.deviceIndependentFlagsMask)
    var out: UInt32 = 0
    if independent.contains(.command) { out |= UInt32(cmdKey) }
    if independent.contains(.shift) { out |= UInt32(shiftKey) }
    if independent.contains(.control) { out |= UInt32(controlKey) }
    if independent.contains(.option) { out |= UInt32(optionKey) }
    return out
  }

  private static func nativeMappings(in mode: Config.Mode) -> [(ModeScope, ModeMapping)] {
    let scoped: [(ModeScope, [ModeMapping])] = [
      (.all, mode.all),
      (.normal, mode.normal),
      (.insert, mode.insert),
    ]
    return scoped.flatMap { scope, mappings in
      mappings
        .filter { $0.key.contains("+") }
        .map { (scope, $0) }
    }
  }
}
