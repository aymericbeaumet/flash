import AppKit
import Carbon.HIToolbox
import Foundation

/// Owns the native modified-key mapping lifecycle.
///
/// All-scope Carbon registrations stay installed across base mode transitions;
/// terminal focus suspends both registration sets. AOT: parsing of the mapping
/// lhs and URL value happens at config load, before any keypress arrives. The
/// hot path on a Carbon callback is one switch over the pre-resolved
/// `MappingCommand`.
///
/// Dispatch policy:
///   - `flashCommand` → fed back to the shared `URLCommand` handler
///     (the same one `URLEventHandler` consults when the AppleEvent
///     receiver decodes a CLI-sent verb). All in-process; no shell-out.
///   - `shellCommand` → launched as an argv array exactly because the
///     user configured that explicit native mapping.
final class MappingsCoordinator {

  private let allHotkeys = HotKeyManager()
  private let scopedHotkeys = HotKeyManager()
  private var mappingDispatch: ((MappingCommand) -> Void)?
  private var activeMappings: [ParsedHotkey: ModeMapping] = [:]
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

  func start(dispatch: @escaping (MappingCommand) -> Void) {
    mappingDispatch = dispatch
  }

  func apply(mode: Config.Mode) {
    configuredMode = mode
    reconcileAllMappings()
    reconcileScopedMappings(for: lastAppliedScope)
  }

  /// All-mode Carbon registrations stay installed; callbacks resolve the
  /// current scope's winning action for their chord. Terminal input suspends
  /// both registration sets in favor of its local matcher. Registrations are
  /// reconciled by chord, so a scope change only touches chords that differ
  /// between the two scopes.
  func apply(scope: MappingScope) {
    guard scope != lastAppliedScope else { return }
    let wasTerminal = lastAppliedScope == .terminal
    lastAppliedScope = scope
    if wasTerminal || scope == .terminal { reconcileAllMappings() }
    reconcileScopedMappings(for: scope)
  }

  private func reconcileAllMappings() {
    let desired =
      lastAppliedScope == .terminal ? [] : Config.Mode.resolveMappings(configuredMode.all)
    reconcile(desired, with: allHotkeys, label: "all")
  }

  private func reconcileScopedMappings(for mappingScope: MappingScope) {
    lastAppliedScope = mappingScope
    activeMappings = Dictionary(
      uniqueKeysWithValues:
        Self.nativeMappings(in: configuredMode, scope: mappingScope).compactMap { mapping in
          mapping.nativeHotkey.map { ($0, mapping) }
        })
    reconcile(
      Self.scopedNativeMappings(in: configuredMode, scope: mappingScope), with: scopedHotkeys,
      label: "\(mappingScope)")
  }

  private func reconcile(_ mappings: [ModeMapping], with hotkeys: HotKeyManager, label: String) {
    var keysByChord: [ParsedHotkey: String] = [:]
    for mapping in mappings {
      if let chord = mapping.nativeHotkey { keysByChord[chord] = mapping.key }
    }
    let result = hotkeys.reconcile(desired: Set(keysByChord.keys)) { [weak self] chord in
      self?.handle(hotkey: chord)
    }
    for chord in result.refused {
      FlashLog.warn(
        "[mappings] could not register \"\(keysByChord[chord] ?? "?")\" — "
          + "another app may already own this hotkey")
    }
    if result.added > 0 || result.removed > 0 {
      FlashLog.debug(
        "[mappings] \(label) registrations added=\(result.added) removed=\(result.removed) "
          + "active=\(hotkeys.registeredChords.count)")
    }
  }

  static func scopeIsActive(_ scope: ModeScope, for mappingScope: MappingScope) -> Bool {
    switch mappingScope {
    case .terminal: return false
    case .command: return scope == .all || scope == .command
    case .normal: return scope == .all || scope == .normal
    case .insert: return scope == .all || scope == .insert
    }
  }

  static func nativeMappings(in mode: Config.Mode, scope: MappingScope) -> [ModeMapping] {
    let scopes: [(ModeScope, [ModeMapping])] = [
      (.normal, mode.normal), (.insert, mode.insert), (.command, mode.command), (.all, mode.all),
    ]
    let mappings = scopes.filter { scopeIsActive($0.0, for: scope) }.flatMap(\.1)
    return Config.Mode.resolveMappings(mappings).filter { $0.nativeHotkey != nil }
  }

  /// All-scope chords already have a persistent Carbon registration, even
  /// when a mode-specific entry overrides the action or spells the key differently.
  static func scopedNativeMappings(in mode: Config.Mode, scope: MappingScope) -> [ModeMapping] {
    let allChords = Set(mode.all.compactMap(\.nativeHotkey))
    return nativeMappings(in: mode, scope: scope).filter {
      guard let chord = $0.nativeHotkey else { return false }
      return !allChords.contains(chord)
    }
  }

  // MARK: - Hot path

  func handle(event: NSEvent) -> Bool {
    handle(
      hotkey: ParsedHotkey(
        modifiers: Self.carbonModifiers(from: event.modifierFlags),
        virtualKey: UInt32(event.keyCode)))
  }

  /// Whether a raw event matches the same resolved chord used by Carbon and
  /// panel dispatch, without allocating an NSEvent on the tap hot path.
  func hasMapping(virtualKey: UInt32, cgFlags: CGEventFlags) -> Bool {
    activeMappings[
      ParsedHotkey(
        modifiers: Self.carbonModifiers(fromCG: cgFlags), virtualKey: virtualKey)] != nil
  }

  @discardableResult
  private func handle(hotkey: ParsedHotkey) -> Bool {
    guard let mapping = activeMappings[hotkey] else { return false }
    fire(mapping, parsed: hotkey)
    return true
  }

  private func fire(_ mapping: ModeMapping, parsed: ParsedHotkey) {
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

}
