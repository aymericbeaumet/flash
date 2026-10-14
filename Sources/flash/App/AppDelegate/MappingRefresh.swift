import AppKit
import FlashCore

extension AppDelegate {
  /// Recompute the effective mapping tables for the active-window selector
  /// context (config defaults + the plugin mappings applicable to that app)
  /// and hand them to the two consumers: the overlay's normal-mode interpreter
  /// (`normalModeMappings`) and the Carbon `MappingsCoordinator`. The
  /// coordinator is re-applied only when the effective mappings actually
  /// changed, so an ordinary app switch doesn't churn global-hotkey
  /// registrations.
  func refreshEffectiveMappings(for bundleID: String?) {
    MainThreadActivity.note("effective_mappings")
    let context = pluginSelectorContext(fallbackBundleID: bundleID)
    let effective = effectiveMode(for: context)
    overlay?.normalModeMappings =
      modeStore.mode.isVisual ? effective.compiledVisual : effective.compiledNormal
    overlay?.hyperModeMappings = effective.compiledHyper
    // The cache hands back one value per selector key, so a focus change
    // that lands on the key already applied skips the six-table compare.
    let selectorChanged = lastAppliedMappingKey != context.cacheKey || lastAppliedMappingMode == nil
    guard selectorChanged else { return }
    lastAppliedMappingKey = context.cacheKey
    // A half-typed sequence and the timeout armed for it were resolved
    // against the table this replaces; neither may complete against this one.
    resetPendingNormalSequence(reason: "mappings_refreshed")
    if mappingModeChanged(from: lastAppliedMappingMode, to: effective) {
      terminalInputMappings?.replaceMappings(
        effective.compiledTerminal,
        timeoutMs: config.mode.sequenceTimeoutMs)
      mappings.apply(mode: effective)
      lastAppliedMappingMode = effective
      debugStateDidChange()
    }
  }

  /// The NORMAL interpreter's table for `scope`: VISUAL's entries over
  /// NORMAL's while a button is held, NORMAL's otherwise. A half-typed
  /// sequence belongs to the table it was typed against, so a switch drops it.
  func applyInterpreterTable(for scope: MappingScope) {
    guard let overlay, let effective = lastAppliedMappingMode else { return }
    let table = scope == .visual ? effective.compiledVisual : effective.compiledNormal
    guard overlay.normalModeMappings != table else { return }
    overlay.normalModeMappings = table
    resetPendingNormalSequence(reason: "mapping_scope")
  }

  /// Drop cached effective modes and force the next refresh to re-apply the
  /// coordinator. Called when the base config or any plugin's mappings change.
  func invalidateEffectiveMappings() {
    effectiveMappingCache.removeAll()
    lastAppliedMappingMode = nil
    lastAppliedMappingKey = nil
  }

  /// Selectors only need a bundle id. A caller that already knows the
  /// frontmost app passes it as `fallbackBundleID` and skips the WindowServer
  /// snapshot behind `currentNonFlashContext()`; Flash's own bundle still
  /// resolves through the non-Flash context so the About window or a terminal
  /// popup never becomes the selector target.
  func pluginSelectorContext(
    for context: AppContext? = nil,
    fallbackBundleID: String? = nil
  ) -> PluginSelectorContext {
    if let context { return PluginSelectorContext(bundleID: context.bundleIdentifier) }
    if let fallbackBundleID, fallbackBundleID != Bundle.main.bundleIdentifier {
      return PluginSelectorContext(bundleID: fallbackBundleID)
    }
    return PluginSelectorContext(
      bundleID: currentNonFlashRunningApplication()?.bundleIdentifier ?? fallbackBundleID)
  }

  func effectiveMode(for context: PluginSelectorContext) -> Config.Mode {
    let key = context.cacheKey
    if let cached = effectiveMappingCache[key] { return cached }
    let pluginMappings = pluginManager.mappings(in: context)
    let effective = EffectiveMappings.merge(
      base: config.mode, plugin: pluginMappings, bundleID: context.bundleID)
    effectiveMappingCache[key] = effective
    return effective
  }

  private func mappingModeChanged(from old: Config.Mode?, to new: Config.Mode) -> Bool {
    guard let old else { return true }
    return old.all != new.all || old.normal != new.normal || old.insert != new.insert
      || old.command != new.command || old.terminal != new.terminal || old.hyper != new.hyper
      || old.visual != new.visual
  }
}
