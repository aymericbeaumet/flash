import XCTest

@testable import flash

final class EffectiveMappingsTests: XCTestCase {
  /// A `Config.Mode` carrying only the supplied scope arrays — the default
  /// normal mappings are cleared so each case asserts on exactly what it sets.
  private func mode(
    all: [ModeMapping] = [],
    normal: [ModeMapping] = [],
    insert: [ModeMapping] = []
  ) -> Config.Mode {
    var mode = Config().mode
    mode.all = all
    mode.normal = normal
    mode.insert = insert
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

  func testConfigAllBeatsConfigNormalAmongPriorityZeroEntries() {
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
    // `all`-scope config entry still wins for the shared key (first-writer-wins
    // over the `all + normal` concat), and the plugin's own key is present.
    XCTAssertEqual(effective.compiledNormal.mapping(for: "q")?.action.command, .undo)
    XCTAssertEqual(effective.compiledNormal.mapping(for: "z")?.action.command, .insertMode)
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
}
