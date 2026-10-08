import XCTest

@testable import flash

final class LogicalKeyboardTests: XCTestCase {
  func testNavigationFollowsThePhysicalHjklColumns() {
    assertNavigation("qwerty", halves: "hjkl", wasd: "aswd", quadrants: ["yu", "bn"])
    assertNavigation("colemak", halves: "hnei", wasd: "arws", quadrants: ["jl", "bk"])
    assertNavigation("dvorak", halves: "dhtn", wasd: "ao,e", quadrants: ["fg", "xb"])
    assertNavigation("bepo", halves: "ctsr", wasd: "auéi", quadrants: ["^v", "k'"])
  }

  func testDefaultHyperPostsQwertyArrowsBesideTheFunctionRow() throws {
    let config = Config.default
    XCTAssertEqual(config.keyboard.layout, "qwerty")
    XCTAssertTrue(config.diagnostics.isEmpty, config.diagnostics.map(\.message).joined())
    let byKey = Dictionary(
      uniqueKeysWithValues: config.mode.hyper.map { ($0.key, $0.action.diagnosticDescription) })
    XCTAssertNil(byKey["h"])
    XCTAssertNil(byKey["j"])
    XCTAssertNil(byKey["k"])
    XCTAssertNil(byKey["l"])
    XCTAssertNil(byKey["shift+h"])
    XCTAssertEqual(byKey["w"], "flash arrow --direction=up")
    XCTAssertEqual(byKey["a"], "flash arrow --direction=left")
    XCTAssertEqual(byKey["s"], "flash arrow --direction=down")
    XCTAssertEqual(byKey["d"], "flash arrow --direction=right")
    XCTAssertEqual(byKey["shift+w"], "flash arrow --direction=up --shift")
    XCTAssertEqual(byKey["shift+a"], "flash arrow --direction=left --shift")
    XCTAssertEqual(byKey["shift+s"], "flash arrow --direction=down --shift")
    XCTAssertEqual(byKey["shift+d"], "flash arrow --direction=right --shift")
    XCTAssertEqual(byKey["1"], "flash system_key --key=brightness_down")
    XCTAssertEqual(byKey["="], "flash system_key --key=volume_up")
    XCTAssertEqual(byKey["shift+="], "flash function_key --key=f12")
  }

  func testBundledHintKeysFollowANonQwertyLayout() {
    let config = ConfigLoader.parse(
      """
      [keyboard]
      layout = "colemak"
      """)
    XCTAssertTrue(config.diagnostics.isEmpty, config.diagnostics.map(\.message).joined())
    XCTAssertEqual(config.hints.keys, Alphabet.defaultKeys)
    XCTAssertEqual(config.effectiveHintKeys(), "<colemak>")
    XCTAssertEqual(config.resolvedAlphabet.chars, Alphabet.resolve("<colemak>").chars)
    XCTAssertEqual(config.resolvedAlphabet.layoutName, "colemak")
    let byKey = arrows(config)
    XCTAssertNil(byKey["h"])
    XCTAssertNil(byKey["n"])
    XCTAssertNil(byKey["e"])
    XCTAssertNil(byKey["i"])
    XCTAssertNil(byKey["shift+h"])
    XCTAssertNil(byKey["shift+j"])
    XCTAssertNil(byKey["shift+d"])
    XCTAssertEqual(byKey["w"], "flash arrow --direction=up")
    XCTAssertEqual(byKey["a"], "flash arrow --direction=left")
    XCTAssertEqual(byKey["r"], "flash arrow --direction=down")
    XCTAssertEqual(byKey["s"], "flash arrow --direction=right")
    XCTAssertEqual(byKey["shift+w"], "flash arrow --direction=up --shift")
    XCTAssertEqual(byKey["shift+a"], "flash arrow --direction=left --shift")
    XCTAssertEqual(byKey["shift+r"], "flash arrow --direction=down --shift")
    XCTAssertEqual(byKey["shift+s"], "flash arrow --direction=right --shift")
    XCTAssertNil(byKey["j"])
    XCTAssertNil(byKey["k"])
    XCTAssertNil(byKey["l"])
    // Physical S types r. An input source keeps key code S; a remapper sends R.
    let typed = interpretHyper(config, key: "s", character: "r", shift: false)
    XCTAssertEqual(typed.command, .arrow(direction: .down, shift: false))
    let remapped = interpretHyper(config, key: "r", character: "r", shift: false)
    XCTAssertEqual(remapped.command, .arrow(direction: .down, shift: false))
    let shiftedPhysical = interpretHyper(config, key: "s", character: "R", shift: true)
    XCTAssertEqual(shiftedPhysical.command, .arrow(direction: .down, shift: true))
    let shiftedLetter = interpretHyper(config, key: "r", character: "R", shift: true)
    XCTAssertEqual(shiftedLetter.command, .arrow(direction: .down, shift: true))
    let right = interpretHyper(config, key: "s", character: "S", shift: true)
    XCTAssertEqual(right.command, .arrow(direction: .right, shift: true))
  }

  func testBundledDefaultKeysDoNotPinQwertyOverTheLogicalLayout() throws {
    let defaults = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("config.default.toml")
    let config = ConfigLoader.parseLayers([
      ConfigLoader.Layer(
        text: try String(contentsOf: defaults, encoding: .utf8),
        sourceURL: defaults,
        diagnosticLabel: "config.default.toml"),
      ConfigLoader.Layer(
        text: """
          [keyboard]
          layout = "colemak"
          """,
        valueSource: ConfigValueSource(layer: "config", detail: "flash.toml")),
    ])
    XCTAssertTrue(config.diagnostics.isEmpty, config.diagnostics.map(\.message).joined())
    XCTAssertNil(config.valueSources["hints.keys"])
    XCTAssertEqual(config.hints.keys, Alphabet.defaultKeys)
    XCTAssertEqual(config.effectiveHintKeys(), "<colemak>")
    XCTAssertEqual(config.resolvedAlphabet.chars, Alphabet.resolve("<colemak>").chars)
    let qwerty = ConfigLoader.parseLayers([
      ConfigLoader.Layer(
        text: try String(contentsOf: defaults, encoding: .utf8),
        sourceURL: defaults,
        diagnosticLabel: "config.default.toml")
    ])
    XCTAssertEqual(qwerty.effectiveHintKeys(), Alphabet.defaultKeys)
  }

  func testAnExplicitHintSelectorWinsOverTheLogicalLayout() {
    let colemak = userLayer(
      """
      [keyboard]
      layout = "dvorak"
      [hints]
      keys = "<colemak>"
      """)
    XCTAssertEqual(colemak.hints.keys, "<colemak>")
    XCTAssertEqual(colemak.effectiveHintKeys(), "<colemak>")
    XCTAssertNil(arrows(colemak)["n"])
    XCTAssertEqual(arrows(colemak)["r"], "flash arrow --direction=down")
    XCTAssertNil(arrows(colemak)[","])
    XCTAssertNil(arrows(colemak)["o"])

    let qwerty = userLayer(
      """
      [keyboard]
      layout = "colemak"
      [hints]
      keys = "<qwerty_homerow+qwerty_toprow>"
      """)
    XCTAssertEqual(qwerty.effectiveHintKeys(), Alphabet.defaultKeys)
    XCTAssertNil(arrows(qwerty)["j"])
    XCTAssertEqual(arrows(qwerty)["s"], "flash arrow --direction=down")
    XCTAssertNil(arrows(qwerty)["n"])
    XCTAssertNil(arrows(qwerty)["r"])
  }

  func testAUserHyperMappingOrRemovalWinsOverADerivedArrow() {
    let config = ConfigLoader.parse(
      """
      [keyboard]
      layout = "qwerty"
      [mode.hyper.mappings]
      "h" = ["flash", "hints_dismiss"]
      "j" = false
      "a" = false
      """)
    XCTAssertTrue(config.diagnostics.isEmpty, config.diagnostics.map(\.message).joined())
    let byKey = arrows(config)
    XCTAssertEqual(byKey["h"], "flash hints_dismiss")
    XCTAssertNil(byKey["j"])
    XCTAssertNil(byKey["shift+j"])
    XCTAssertNil(byKey["k"])
    XCTAssertNil(byKey["a"])
    XCTAssertEqual(byKey["shift+a"], "flash arrow --direction=left --shift")
    XCTAssertEqual(byKey["w"], "flash arrow --direction=up")
    XCTAssertEqual(byKey["s"], "flash arrow --direction=down")
  }

  func testAnUnknownLayoutIsDiagnosedAndStaysQwerty() {
    let config = ConfigLoader.parse(
      """
      [keyboard]
      layout = "azerty"
      """)
    XCTAssertEqual(config.diagnostics.count, 1)
    XCTAssertTrue(config.diagnostics[0].message.contains("keyboard.layout"))
    XCTAssertEqual(config.keyboard.layout, "qwerty")
    XCTAssertNil(arrows(config)["j"])
    XCTAssertEqual(arrows(config)["s"], "flash arrow --direction=down")
  }

  func testInstallingArrowsTwiceDoesNotDuplicateThem() {
    var config = ConfigLoader.parse(
      """
      [keyboard]
      layout = "qwerty"
      """)
    config.prepareDerivedValues()
    XCTAssertEqual(config.mode.hyper.filter { $0.key == "h" }.count, 0)
    XCTAssertEqual(config.mode.hyper.filter { $0.key == "shift+h" }.count, 0)
    XCTAssertEqual(config.mode.hyper.filter { $0.key == "w" }.count, 1)
    XCTAssertEqual(config.mode.hyper.filter { $0.key == "shift+w" }.count, 1)
  }

  func testBepoResolvesWithoutAnAmbiguousShiftWarning() {
    let config = ConfigLoader.parse("[hints]\nkeys = \"<bepo>\"")
    XCTAssertEqual(config.resolvedAlphabet.layoutName, "bepo")
    XCTAssertNil(config.resolvedAlphabet.warning)
    XCTAssertFalse(config.diagnostics.contains { $0.message.contains("magic_modifiers") })
    XCTAssertFalse(String(config.resolvedAlphabet.chars).contains("^"))
    XCTAssertNil(arrows(config)["c"])
    XCTAssertNil(arrows(config)["t"])
    XCTAssertEqual(arrows(config)["é"], "flash arrow --direction=up")
    XCTAssertEqual(arrows(config)["a"], "flash arrow --direction=left")
    XCTAssertEqual(arrows(config)["u"], "flash arrow --direction=down")
    XCTAssertEqual(arrows(config)["i"], "flash arrow --direction=right")
    XCTAssertEqual(arrows(config)["shift+é"], "flash arrow --direction=up --shift")
    XCTAssertNil(arrows(config)["shift+w"])
    XCTAssertNil(arrows(config)["shift+h"])
    XCTAssertNil(arrows(config)["shift+c"])
    let up = interpretHyper(config, key: "w", character: "é", shift: false)
    XCTAssertEqual(up.command, .arrow(direction: .up, shift: false))
    let shifted = interpretHyper(config, key: "w", character: "É", shift: true)
    XCTAssertEqual(shifted.command, .arrow(direction: .up, shift: true))
  }

  func testColemakBisectUsesHneiAndTheYuBnColumns() {
    let navigation = Alphabet.navigation(layoutName: "colemak")
    let shape = MouseGrid.Shape.bisect(navigation)
    XCTAssertEqual(shape.keys.map { String($0) }, ["jl", "bk"])
    XCTAssertEqual(grid("h", shape: shape), .half(.left, []))
    XCTAssertEqual(grid("n", shape: shape), .half(.down, []))
    XCTAssertEqual(grid("e", shape: shape), .half(.up, []))
    XCTAssertEqual(grid("i", shape: shape), .half(.right, []))
    XCTAssertEqual(grid("j", shape: shape), .cell("j", []))
    XCTAssertEqual(grid("k", shape: shape), .cell("k", []))
  }

  func testColemakPointerAndAdjustmentUseTheSameCluster() {
    let arrows = Alphabet.navigation(layoutName: "colemak")
    XCTAssertEqual(
      PointerModeInterpreter.command(
        keyCode: 0, charactersIgnoringModifiers: "n", modifierFlags: [], arrows: arrows),
      .move(dx: 0, dy: -1, fine: false))
    XCTAssertEqual(
      PointerModeInterpreter.command(
        keyCode: 0, charactersIgnoringModifiers: "h", modifierFlags: [.shift], arrows: arrows),
      .move(dx: -1, dy: 0, fine: true))
    XCTAssertEqual(
      PointerModeInterpreter.command(
        keyCode: 0, charactersIgnoringModifiers: "m", modifierFlags: [], arrows: arrows),
      .clickLeft)
    XCTAssertEqual(
      HintAdjustmentInterpreter.command(
        keyCode: 0, charactersIgnoringModifiers: "n", arrows: arrows),
      .snapBottom)
    XCTAssertNil(
      PointerModeInterpreter.command(
        keyCode: 0, charactersIgnoringModifiers: "w", modifierFlags: [], arrows: arrows))
  }

  func testDvorakWasdUsesTheCommaOnTheWKey() {
    let config = ConfigLoader.parse(
      """
      [keyboard]
      layout = "dvorak"
      """)
    let byKey = arrows(config)
    XCTAssertEqual(byKey[","], "flash arrow --direction=up")
    XCTAssertEqual(byKey["a"], "flash arrow --direction=left")
    XCTAssertEqual(byKey["o"], "flash arrow --direction=down")
    XCTAssertEqual(byKey["e"], "flash arrow --direction=right")
    XCTAssertNil(byKey["d"])
    XCTAssertEqual(byKey["shift+w"], "flash arrow --direction=up --shift")
    XCTAssertNil(byKey["shift+,"])
    let up = interpretHyper(config, key: "w", character: ",", shift: false)
    XCTAssertEqual(up.command, .arrow(direction: .up, shift: false))
    let shifted = interpretHyper(config, key: "w", character: "<", shift: true)
    XCTAssertEqual(shifted.command, .arrow(direction: .up, shift: true))
  }

  private func assertNavigation(
    _ layout: String, halves: String, wasd: String, quadrants: [String],
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let navigation = Alphabet.navigation(layoutName: layout)
    let cluster = String([navigation.left, navigation.down, navigation.up, navigation.right])
    XCTAssertEqual(cluster, halves, layout, file: file, line: line)
    let wasdCluster = String([
      navigation.wasd.left.character, navigation.wasd.down.character,
      navigation.wasd.up.character, navigation.wasd.right.character,
    ])
    XCTAssertEqual(wasdCluster, wasd, layout, file: file, line: line)
    XCTAssertEqual(
      navigation.quadrants.map { String($0) }, quadrants, layout, file: file, line: line)
  }

  private func interpretHyper(
    _ config: Config, key: String, character: String, shift: Bool
  ) -> NormalModeTransition {
    let code = HotkeySyntax.parseKey(key) ?? 0
    return NormalModeInterpreter.interpret(
      pending: "",
      keyCode: UInt16(code),
      modifierFlags: shift ? .shift : [],
      characters: character,
      charactersIgnoringModifiers: character.lowercased(),
      mappings: config.mode.compiledHyper)
  }

  private func arrows(_ config: Config) -> [String: String] {
    Dictionary(
      config.mode.hyper.map { ($0.key, $0.action.diagnosticDescription) },
      uniquingKeysWith: { _, last in last })
  }

  private func userLayer(_ text: String) -> Config {
    ConfigLoader.parseLayers([
      ConfigLoader.Layer(
        text: text,
        valueSource: ConfigValueSource(layer: "config", detail: "flash.toml"))
    ])
  }

  private func grid(_ key: Character, shape: MouseGrid.Shape) -> MouseGridKeyCommand {
    MouseGridInputInterpreter.command(
      keyCode: 0, modifierFlags: [], typed: String(key), shape: shape, magicModifiers: [])
  }
}
