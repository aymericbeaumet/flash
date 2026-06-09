import AppKit
import FlashCore

extension AppDelegate {
  /// Recompute the effective mapping tables for `bundleID` (config defaults +
  /// the plugin mappings applicable to that app) and hand them to the two
  /// consumers: the overlay's normal-mode interpreter (`normalModeMappings`)
  /// and the Carbon `MappingsCoordinator`. The coordinator is re-applied only
  /// when the effective mappings actually changed, so an ordinary app switch
  /// doesn't churn global-hotkey registrations.
  func refreshEffectiveMappings(for bundleID: String?) {
    let effective = effectiveMode(for: bundleID)
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

  private func effectiveMode(for bundleID: String?) -> Config.Mode {
    let key = bundleID ?? ""
    if let cached = effectiveMappingCache[key] { return cached }
    let pluginMappings = bundleID.map { pluginManager.mappings(forBundleID: $0) } ?? []
    let effective = EffectiveMappings.merge(base: config.mode, plugin: pluginMappings)
    effectiveMappingCache[key] = effective
    return effective
  }

  private func mappingModeChanged(from old: Config.Mode?, to new: Config.Mode) -> Bool {
    guard let old else { return true }
    return old.all != new.all || old.normal != new.normal || old.insert != new.insert
  }
}
