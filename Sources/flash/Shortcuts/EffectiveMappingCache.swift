/// The effective mapping tables per focused app (config defaults plus the
/// plugin mappings that apply to it), and which of them the Carbon
/// `MappingsCoordinator` last received. A focus change that lands on the
/// selector already applied costs one string compare; one that lands on
/// another selector with the same tables registers no hotkey.
struct EffectiveMappingCache {
  /// Keyed by `PluginSelectorContext.cacheKey` ("" for none/unknown).
  private var modes: [String: Config.Mode] = [:]
  /// The effective mode last handed to `MappingsCoordinator`.
  private(set) var applied: Config.Mode?
  /// The selector key `applied` was resolved for.
  private var appliedKey: String?

  /// The tables of `key`, resolved once until the next `invalidate`.
  mutating func mode(for key: String, resolve: () -> Config.Mode) -> Config.Mode {
    if let cached = modes[key] { return cached }
    let mode = resolve()
    modes[key] = mode
    return mode
  }

  /// Make `key` the applied selector. False when it already is and its
  /// tables were applied: the caller has nothing to refresh.
  mutating func select(_ key: String) -> Bool {
    guard appliedKey != key || applied == nil else { return false }
    appliedKey = key
    return true
  }

  /// Record `mode` as applied. False when its tables are the ones already
  /// applied, so the coordinator keeps its registrations.
  mutating func apply(_ mode: Config.Mode) -> Bool {
    guard Self.tablesDiffer(applied, mode) else { return false }
    applied = mode
    return true
  }

  /// Drop every resolved mode and force the next refresh to re-apply the
  /// coordinator: the base config or a plugin's mappings changed.
  mutating func invalidate() {
    modes.removeAll()
    applied = nil
    appliedKey = nil
  }

  private static func tablesDiffer(_ old: Config.Mode?, _ new: Config.Mode) -> Bool {
    guard let old else { return true }
    return old.all != new.all || old.normal != new.normal || old.insert != new.insert
      || old.command != new.command || old.terminal != new.terminal || old.hyper != new.hyper
      || old.hold != new.hold || old.layers != new.layers
  }
}
