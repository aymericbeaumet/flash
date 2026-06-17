import AppKit
import FlashCore

extension AppDelegate {
  /// Recompute the effective mapping tables for the active-window selector
  /// context (config defaults + the plugin mappings applicable to that app/URL)
  /// and hand them to the two consumers: the overlay's normal-mode interpreter
  /// (`normalModeMappings`) and the Carbon `MappingsCoordinator`. The
  /// coordinator is re-applied only when the effective mappings actually
  /// changed, so an ordinary app switch doesn't churn global-hotkey
  /// registrations.
  func refreshEffectiveMappings(for bundleID: String?) {
    let effective = effectiveMode(for: pluginSelectorContext(fallbackBundleID: bundleID))
    overlay?.normalModeMappings = effective.compiledNormal
    if mappingModeChanged(from: lastAppliedMappingMode, to: effective) {
      mappings.apply(mode: effective)
      lastAppliedMappingMode = effective
    }
  }

  /// Drop cached effective modes and force the next refresh to re-apply the
  /// coordinator. Called when the base config or any plugin's mappings change.
  func invalidateEffectiveMappings() {
    effectiveMappingCache.removeAll()
    lastAppliedMappingMode = nil
  }

  func pluginSelectorContext(
    for context: AppContext? = nil,
    fallbackBundleID: String? = nil
  ) -> PluginSelectorContext {
    let resolved = context ?? currentNonFlashContext()
    let bundleID = resolved?.bundleIdentifier ?? fallbackBundleID
    let url =
      pluginManager.needsURLSelectorContext()
      ? resolved.flatMap { NormalModeDispatcher.documentURL(pid: $0.processID) }
      : nil
    return PluginSelectorContext(bundleID: bundleID, url: url)
  }

  private func effectiveMode(for context: PluginSelectorContext) -> Config.Mode {
    let key = context.cacheKey
    if let cached = effectiveMappingCache[key] { return cached }
    let pluginMappings = pluginManager.mappings(in: context)
    let effective = EffectiveMappings.merge(base: config.mode, plugin: pluginMappings)
    effectiveMappingCache[key] = effective
    return effective
  }

  private func mappingModeChanged(from old: Config.Mode?, to new: Config.Mode) -> Bool {
    guard let old else { return true }
    return old.all != new.all || old.normal != new.normal || old.insert != new.insert
  }
}
