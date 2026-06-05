import AppKit
import Carbon.HIToolbox
import Foundation

/// Owns the native modified-key mapping lifecycle.
///
/// On every `apply(mode:)` the Carbon registration set is rebuilt from
/// scratch. AOT: parsing of the mapping lhs and URL value happens at
/// config load, before any keypress arrives. The hot path on a Carbon
/// callback is one switch over the pre-resolved `MappingAction`.
///
/// Dispatch policy:
///   - `flashCommand` → fed back to the shared `URLCommand` handler
///     (the same one `URLEventHandler` uses for live `flash://...`
///     URLs from `open` / `osascript`). All in-process; no shell-out.
final class MappingsCoordinator {

  private struct ActiveMapping {
    let parsed: ParsedHotkey
    let scope: ModeScope
    let mapping: ModeMapping
  }

  private let hotkeys = HotKeyManager()
  private var flashDispatch: ((URLCommand) -> Void)?
  private var currentMode: (() -> FlashMode)?
  private var activeMappings: [ActiveMapping] = []
  private var lastFireDiagnostic: String?
  private var lastFireAt: Date = .distantPast

  func start(dispatch: @escaping (URLCommand) -> Void, currentMode: @escaping () -> FlashMode) {
    flashDispatch = dispatch
    self.currentMode = currentMode
  }

  func stop() {
    hotkeys.unregisterAll()
    flashDispatch = nil
    currentMode = nil
  }

  func apply(mode: Config.Mode) {
    hotkeys.unregisterAll()
    activeMappings.removeAll(keepingCapacity: true)
    for (scope, mapping) in Self.nativeMappings(in: mode) {
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
        self?.fire(mapping, scope: scope)
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

  // MARK: - Hot path

  func handle(event: NSEvent) -> Bool {
    let modifiers = Self.carbonModifiers(from: event.modifierFlags)
    let virtualKey = UInt32(event.keyCode)
    guard let active = activeMappings.first(where: {
      $0.parsed.modifiers == modifiers && $0.parsed.virtualKey == virtualKey
    }) else {
      return false
    }
    fire(active.mapping, scope: active.scope)
    return true
  }

  private func fire(_ mapping: ModeMapping, scope: ModeScope) {
    guard mappingApplies(scope: scope) else { return }
    let diagnostic = mapping.action.diagnosticDescription
    let now = Date()
    if lastFireDiagnostic == diagnostic, now.timeIntervalSince(lastFireAt) < 0.08 {
      return
    }
    lastFireDiagnostic = diagnostic
    lastFireAt = now
    FlashLog.debug("[mappings] fired \(diagnostic)")
    flashDispatch?(mapping.action.command)
  }

  private func mappingApplies(scope: ModeScope) -> Bool {
    guard scope != .all else { return true }
    guard let current = currentMode?() else { return false }
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
