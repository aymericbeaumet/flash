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
///     (the same one `URLEventHandler` consults when the AppleEvent
///     receiver decodes a CLI-sent verb). All in-process; no shell-out.
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
  private var lastAppliedScope: MappingScope = .insert
  private var lastFireDiagnostic: String?
  private var lastFireAt: Date = .distantPast
  /// Chords Flash just synthesized into the focused app (e.g. the `⌘⇧]`
  /// Messages tab-traversal fallback). `postToPid` is *supposed* to bypass
  /// the session-level Carbon dispatcher, but the OS sometimes routes the
  /// synthetic event back through it, where it re-triggers the scope-bound
  /// hotkey for the SAME chord: `tab_next` → synthesize `⌘⇧]` → `tab_next`
  /// … a self-feeding loop. `fire`'s 80 ms same-action debounce masks it
  /// only when the round-trip beats 80 ms; Messages' conversation-switch
  /// latency regularly loses that race, so the loop runs away. Each
  /// synthesize notes one expected echo keyed by chord; the next matching
  /// hotkey fire inside the window consumes it instead of dispatching,
  /// breaking the loop. Genuine user presses beyond the noted count still
  /// dispatch normally.
  private var syntheticEchoes: [UInt64: (count: Int, at: Date)] = [:]
  private static let syntheticEchoWindow: TimeInterval = 0.3

  func start(dispatch: @escaping (MappingCommand) -> Void, currentMode: @escaping () -> FlashMode) {
    mappingDispatch = dispatch
    self.currentMode = currentMode
  }

  func apply(mode: Config.Mode) {
    configuredMode = mode
    rebuild(for: lastAppliedScope)
  }

  /// Re-register Carbon hotkeys for the current input surface. Carbon
  /// registrations are global. All-scope mappings stay active on every surface;
  /// normal- and insert-scoped mappings are removed while the command field owns
  /// the keyboard.
  func apply(scope: MappingScope) {
    guard scope != lastAppliedScope else { return }
    rebuild(for: scope)
  }

  private func rebuild(for mappingScope: MappingScope) {
    lastAppliedScope = mappingScope
    hotkeys.unregisterAll()
    activeMappings.removeAll(keepingCapacity: true)
    for (scope, mapping) in Self.nativeMappings(in: configuredMode) {
      guard Self.scopeIsActive(scope, for: mappingScope) else { continue }
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

  static func scopeIsActive(_ scope: ModeScope, for mappingScope: MappingScope) -> Bool {
    switch mappingScope {
    case .command:
      return scope == .all
    case .normal:
      switch scope {
      case .all, .normal: return true
      case .insert: return false
      }
    case .insert:
      switch scope {
      case .all, .insert: return true
      case .normal: return false
      }
    }
  }

  // MARK: - Hot path

  func handle(event: NSEvent) -> Bool {
    guard
      let active = activeMapping(
        virtualKey: UInt32(event.keyCode),
        modifiers: Self.carbonModifiers(from: event.modifierFlags))
    else { return false }
    fire(active.mapping, scope: active.scope, parsed: active.parsed)
    return true
  }

  /// Whether a chord matches an active mapping, without firing it — from raw
  /// CGEvent fields so the tap's swallow decision stays off the `NSEvent`
  /// (keyboard-layout-resolving) path on the hot per-keystroke route. Lets an
  /// *unmapped* chord pass through (`passthrough_modifiers`) while a mapped one
  /// is still captured.
  func hasMapping(virtualKey: UInt32, cgFlags: CGEventFlags) -> Bool {
    activeMapping(virtualKey: virtualKey, modifiers: Self.carbonModifiers(fromCG: cgFlags)) != nil
  }

  private func activeMapping(virtualKey: UInt32, modifiers: UInt32) -> ActiveMapping? {
    activeMappings.first {
      $0.parsed.modifiers == modifiers && $0.parsed.virtualKey == virtualKey
    }
  }

  private func fire(_ mapping: ModeMapping, scope: ModeScope, parsed: ParsedHotkey) {
    guard mappingApplies(scope: scope, parsed: parsed) else { return }
    let diagnostic = mapping.action.diagnosticDescription
    let now = Date()
    if consumeSyntheticEcho(virtualKey: parsed.virtualKey, modifiers: parsed.modifiers, now: now) {
      FlashLog.debug("[mappings] suppressed self-synthesized echo \(diagnostic)")
      return
    }
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

  /// Record that Flash just synthesized `virtualKey`+`flags` into the
  /// focused app. Called by the normal-mode key senders immediately before
  /// the `postToPid`. See `syntheticEchoes` for why this exists.
  func noteSyntheticKey(virtualKey: UInt32, flags: CGEventFlags) {
    let key = Self.echoKey(virtualKey: virtualKey, modifiers: Self.carbonModifiers(fromCG: flags))
    let now = Date()
    let priorCount =
      syntheticEchoes[key].map {
        now.timeIntervalSince($0.at) < Self.syntheticEchoWindow ? $0.count : 0
      }
      ?? 0
    syntheticEchoes[key] = (count: priorCount + 1, at: now)
  }

  /// Consume one expected echo for this chord, if a fresh one is pending.
  /// Returns true when the fire should be suppressed as a self-echo.
  private func consumeSyntheticEcho(virtualKey: UInt32, modifiers: UInt32, now: Date) -> Bool {
    let key = Self.echoKey(virtualKey: virtualKey, modifiers: modifiers)
    guard let pending = syntheticEchoes[key],
      now.timeIntervalSince(pending.at) < Self.syntheticEchoWindow,
      pending.count > 0
    else {
      syntheticEchoes.removeValue(forKey: key)
      return false
    }
    if pending.count <= 1 {
      syntheticEchoes.removeValue(forKey: key)
    } else {
      syntheticEchoes[key] = (count: pending.count - 1, at: pending.at)
    }
    return true
  }

  private static func echoKey(virtualKey: UInt32, modifiers: UInt32) -> UInt64 {
    (UInt64(modifiers) << 32) | UInt64(virtualKey)
  }

  static func carbonModifiers(fromCG flags: CGEventFlags) -> UInt32 {
    var out: UInt32 = 0
    if flags.contains(.maskCommand) { out |= UInt32(cmdKey) }
    if flags.contains(.maskShift) { out |= UInt32(shiftKey) }
    if flags.contains(.maskControl) { out |= UInt32(controlKey) }
    if flags.contains(.maskAlternate) { out |= UInt32(optionKey) }
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
