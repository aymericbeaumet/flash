import Foundation

/// Merges built-in (config) mappings with plugin-registered mappings for the
/// focused app into an effective `Config.Mode`.
///
/// Config mappings sit at baseline priority 0; plugin mappings carry the
/// priority that decides collisions (manifest default 25, so they override
/// defaults; a negative priority defers to them). Within each scope the
/// entries are stable-sorted by priority descending, so `CompiledMappings`'
/// first-writer-wins hands each key to the highest-priority claimant.
///
/// The merge is per scope (`all`/`normal`/`insert`): config's own order — and
/// the `all`-before-`normal` precedence baked into `Config.Mode.mappings(for:)`
/// — is preserved among the priority-0 entries. Cross-scope override of a
/// user's `all`-scope binding by a plugin's `normal` mapping is intentionally
/// out of scope.
enum EffectiveMappings {
  static func merge(
    base: Config.Mode,
    plugin: [(priority: Int, scope: ModeScope, mapping: ModeMapping)]
  ) -> Config.Mode {
    guard !plugin.isEmpty else { return base }
    var effective = base
    effective.all = mergeScope(base: base.all, plugin: plugin, scope: .all)
    effective.normal = mergeScope(base: base.normal, plugin: plugin, scope: .normal)
    effective.insert = mergeScope(base: base.insert, plugin: plugin, scope: .insert)
    effective.recompileMappings()
    return effective
  }

  private static func mergeScope(
    base: [ModeMapping],
    plugin: [(priority: Int, scope: ModeScope, mapping: ModeMapping)],
    scope: ModeScope
  ) -> [ModeMapping] {
    let pluginForScope = plugin.filter { $0.scope == scope }
    guard !pluginForScope.isEmpty else { return base }
    // Plugin entries first so an equal-priority tie favors the plugin; config
    // entries follow at priority 0. The `enumerated()` offset is a stable
    // tiebreaker (Swift's `sorted` isn't guaranteed stable), preserving each
    // group's internal order.
    let tagged: [(priority: Int, mapping: ModeMapping)] =
      pluginForScope.map { ($0.priority, $0.mapping) } + base.map { (0, $0) }
    return
      tagged
      .enumerated()
      .sorted { lhs, rhs in
        if lhs.element.priority != rhs.element.priority {
          return lhs.element.priority > rhs.element.priority
        }
        return lhs.offset < rhs.offset
      }
      .map { $0.element.mapping }
  }
}
