import XCTest

@testable import flash

final class EffectiveMappingsTests: XCTestCase {
  /// A `Config.Mode` carrying only the supplied scope arrays — the default
  /// normal mappings are cleared so each case asserts on exactly what it sets.
  private func mode(
    all: [ModeMapping] = [],
    normal: [ModeMapping] = [],
    insert: [ModeMapping] = [],
    command: [ModeMapping] = []
  ) -> Config.Mode {
    var mode = Config().mode
    mode.all = all
    mode.normal = normal
    mode.insert = insert
    mode.command = command
    mode.recompileMappings()
    return mode
  }

  func testPluginPriorityOverridesBuiltinDefault() {
    let base = mode(normal: [ModeMapping(key: "q", action: .flashCommand(.undo))])
    let effective = EffectiveMappings.merge(
      base: base,
      plugin: [
        (priority: 25, scope: .normal, mapping: ModeMapping(key: "q", action: .flashCommand(.redo)))
      ])
    XCTAssertEqual(effective.compiledNormal.mapping(for: "q")?.action.command, .redo)
  }

  func testNegativePriorityDefersToBuiltinDefault() {
    let base = mode(normal: [ModeMapping(key: "q", action: .flashCommand(.undo))])
    let effective = EffectiveMappings.merge(
      base: base,
      plugin: [
        (priority: -1, scope: .normal, mapping: ModeMapping(key: "q", action: .flashCommand(.redo)))
      ])
    XCTAssertEqual(effective.compiledNormal.mapping(for: "q")?.action.command, .undo)
  }

  func testEmptyPluginListReturnsBaseUnchanged() {
    let base = mode(
      all: [ModeMapping(key: "x", action: .flashCommand(.close))],
      normal: [ModeMapping(key: "q", action: .flashCommand(.undo))],
      insert: [ModeMapping(key: "z", action: .flashCommand(.insertMode))])
    let effective = EffectiveMappings.merge(base: base, plugin: [])
    XCTAssertEqual(effective.all, base.all)
    XCTAssertEqual(effective.normal, base.normal)
    XCTAssertEqual(effective.insert, base.insert)
  }

  func testConfigNormalOverridesAllAmongPriorityZeroEntries() {
    // Same lhs in `all` and `normal`; an unrelated plugin entry forces the
    // merge path so this exercises mergeScope, not the empty-plugin shortcut.
    let base = mode(
      all: [ModeMapping(key: "q", action: .flashCommand(.undo))],
      normal: [ModeMapping(key: "q", action: .flashCommand(.redo))])
    let effective = EffectiveMappings.merge(
      base: base,
      plugin: [
        (
          priority: 25, scope: .normal,
          mapping: ModeMapping(key: "z", action: .flashCommand(.insertMode))
        )
      ])
    // A mode-specific binding overrides the all-mode fallback.
    XCTAssertEqual(effective.compiledNormal.mapping(for: "q")?.action.command, .redo)
    XCTAssertEqual(effective.compiledNormal.mapping(for: "z")?.action.command, .insertMode)
  }

  func testInsertOverridesAllWhileNormalInheritsFallback() {
    let config = mode(
      all: [ModeMapping(key: "q", action: .flashCommand(.undo))],
      insert: [ModeMapping(key: "q", action: .flashCommand(.redo))])
    XCTAssertEqual(config.compiledNormal.mapping(for: "q")?.action.command, .undo)
    XCTAssertEqual(config.compiledInsert.mapping(for: "q")?.action.command, .redo)
  }

  func testEqualPriorityTieFavorsPlugin() {
    // A plugin entry at the same priority as another plugin entry for the same
    // key resolves to whichever was placed first; config sits at priority 0, so
    // a priority-0 plugin entry still beats the config default (tie → plugin).
    let base = mode(normal: [ModeMapping(key: "q", action: .flashCommand(.undo))])
    let effective = EffectiveMappings.merge(
      base: base,
      plugin: [
        (priority: 0, scope: .normal, mapping: ModeMapping(key: "q", action: .flashCommand(.redo)))
      ])
    XCTAssertEqual(effective.compiledNormal.mapping(for: "q")?.action.command, .redo)
  }

  func testNativeScopeOverridesAllUsingPhysicalChordAliases() {
    let config = mode(
      all: [ModeMapping(key: "cmd+shift+]", action: .flashCommand(.undo))],
      normal: [ModeMapping(key: "cmd+shift+}", action: .flashCommand(.redo))],
      command: [ModeMapping(key: "cmd+shift+]", action: .flashCommand(.insertMode))])
    XCTAssertEqual(
      MappingsCoordinator.nativeMappings(in: config, scope: .normal).map(\.action.command), [.redo])
    XCTAssertEqual(
      MappingsCoordinator.nativeMappings(in: config, scope: .insert).map(\.action.command), [.undo])
    XCTAssertEqual(
      MappingsCoordinator.nativeMappings(in: config, scope: .command).map(\.action.command),
      [.insertMode])
    XCTAssertEqual(config.compiledNormal.ordered.count, 1)
    XCTAssertEqual(config.compiledNormal.ordered.first?.action.command, .redo)
    for scope in [MappingScope.normal, .insert, .command] {
      XCTAssertTrue(
        MappingsCoordinator.scopedNativeMappings(in: config, scope: scope).isEmpty,
        "The existing all-mode registration serves every scoped override")
    }
  }

  func testCommandOnlyChordIsRegisteredOnlyForCommandScope() {
    let mapping = ModeMapping(key: "cmd+ctrl+i", action: .flashCommand(.insertMode))
    let config = mode(command: [mapping])
    XCTAssertEqual(MappingsCoordinator.scopedNativeMappings(in: config, scope: .command), [mapping])
    XCTAssertTrue(MappingsCoordinator.nativeMappings(in: config, scope: .normal).isEmpty)
    XCTAssertTrue(MappingsCoordinator.nativeMappings(in: config, scope: .insert).isEmpty)
  }

}
