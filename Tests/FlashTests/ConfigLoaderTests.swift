import Foundation
import XCTest

@testable import flash

final class ConfigLoaderTests: XCTestCase {
  func testDefaultsWhenEmpty() {
    let c = ConfigLoader.parse("")
    XCTAssertEqual(c.hints.keys, "<qwerty_homerow+qwerty_toprow>")
    XCTAssertEqual(c.resolvedAlphabet.layoutName, "qwerty")
    XCTAssertEqual(c.hints.minLength, 1)
    XCTAssertEqual(c.hints.magicModifiers, ["cmd", "ctrl", "alt", "shift"])
    XCTAssertEqual(c.overlay.fontSize, 12)
    XCTAssertEqual(c.overlay.hintFG, "#302505")
    XCTAssertEqual(c.overlay.hintBGTop, "#FFF785")
    XCTAssertEqual(c.overlay.hintBGBottom, "#FFC542")
    XCTAssertEqual(c.overlay.hintBorder, "#E3BE23")
    XCTAssertFalse(c.debug.profile)
    XCTAssertEqual(c.debug.slowMs, 100)
  }

  func testParsesHintsSection() {
    let toml = """
      [hints]
      keys = "<colemak_homerow+colemak_toprow>"
      min_length = 2
      magic_modifiers = ["cmd", "alt"]
      """
    let c = ConfigLoader.parse(toml)
    XCTAssertEqual(c.hints.keys, "<colemak_homerow+colemak_toprow>")
    XCTAssertEqual(c.resolvedAlphabet.layoutName, "colemak")
    XCTAssertEqual(c.hints.minLength, 2)
    XCTAssertEqual(c.hints.magicModifiers, ["cmd", "alt"])
  }

  func testParsesEmptyMagicModifiersArray() {
    let c = ConfigLoader.parse(
      """
      [hints]
      magic_modifiers = []
      """)
    XCTAssertEqual(c.hints.magicModifiers, [])
  }

  func testShiftMagicModifierIsRemovedWhenResolvedKeysContainNonLetters() {
    let c = ConfigLoader.parse(
      """
      [hints]
      keys = "as;d"
      """)
    XCTAssertEqual(String(c.resolvedAlphabet.chars), "as;d")
    XCTAssertEqual(c.hints.magicModifiers, ["cmd", "ctrl", "alt"])
    XCTAssertEqual(c.warnings.count, 1)
    XCTAssertTrue(c.warnings[0].contains("removed \"shift\""))
    XCTAssertTrue(c.warnings[0].contains("as;d"))
  }

  func testShiftMagicModifierWarningIsNotDuplicatedByOverrides() {
    let base = ConfigLoader.parse(
      """
      [hints]
      keys = "as;d"
      """)
    let c = ConfigLoader.applyOverrides(to: base, arguments: ["flash"], environment: [:])
    XCTAssertEqual(c.hints.magicModifiers, ["cmd", "ctrl", "alt"])
    XCTAssertEqual(c.warnings.filter { $0.contains("removed \"shift\"") }.count, 1)
  }

  func testResolvedConfigJSONIncludesDefaultsAndOverrides() throws {
    let c = ConfigLoader.parse(
      """
      [hints]
      magic_modifiers = ["shift"]
      [debug]
      log_level = "debug"
      """)
    let json = c.resolvedConfigJSON
    XCTAssertFalse(json.contains("\n"))
    let root = try XCTUnwrap(Self.parseJSONObject(json))
    let hints = try XCTUnwrap(root["hints"] as? [String: Any])
    let overlay = try XCTUnwrap(root["overlay"] as? [String: Any])
    let debug = try XCTUnwrap(root["debug"] as? [String: Any])
    XCTAssertEqual(hints["keys"] as? String, "<qwerty_homerow+qwerty_toprow>")
    XCTAssertEqual(hints["min_length"] as? Int, 1)
    XCTAssertEqual(hints["magic_modifiers"] as? [String], ["shift"])
    XCTAssertEqual(overlay["font_size"] as? Double, 12)
    XCTAssertEqual(debug["log_level"] as? String, "debug")
  }

  func testResolvedHintsKeysJSONIncludesDefaultAndResolvedAlphabet() throws {
    let c = ConfigLoader.parse(
      """
      [hints]
      keys = "<colemak_homerow>"
      """)
    let json = c.resolvedHintsKeysJSON
    XCTAssertFalse(json.contains("\n"))
    let root = try XCTUnwrap(Self.parseJSONObject(json))
    XCTAssertEqual(root["default"] as? String, "<qwerty_homerow+qwerty_toprow>")
    XCTAssertEqual(root["raw"] as? String, "<colemak_homerow>")
    XCTAssertEqual(root["layout"] as? String, "colemak")
    XCTAssertEqual(root["chars"] as? String, "arstnediho")
    XCTAssertEqual(root["left_hand"] as? String, "abcdfgpqrstvwxz")
  }

  func testParsesInvalidLayoutKeysIntoPreparedFallback() {
    let c = ConfigLoader.parse("[hints]\nkeys = \"<colemak_homerow+qwerty_toprow>\"")
    XCTAssertEqual(c.hints.keys, "<colemak_homerow+qwerty_toprow>")
    XCTAssertEqual(c.resolvedAlphabet.layoutName, "qwerty")
    XCTAssertEqual(String(c.resolvedAlphabet.chars), "sdfjklagheruiwtyoqp")
    XCTAssertNotNil(c.resolvedAlphabet.warning)
  }

  func testParsesValidLayoutCombinationIntoPreparedAlphabet() {
    let c = ConfigLoader.parse(
      """
      [hints]
      keys = "<dvorak_homerow_lefthand+dvorak_toprow_righthand>"
      """)
    XCTAssertEqual(c.resolvedAlphabet.layoutName, "dvorak")
    XCTAssertEqual(String(c.resolvedAlphabet.chars), "aoeuifcrlg")
    XCTAssertNil(c.resolvedAlphabet.warning)
  }

  func testParsesLiteralKeys() {
    let c = ConfigLoader.parse("[hints]\nkeys = \"asdfghjkl\"")
    XCTAssertEqual(c.hints.keys, "asdfghjkl")
    XCTAssertEqual(String(c.resolvedAlphabet.chars), "asdfghjkl")
    XCTAssertNil(c.resolvedAlphabet.layoutName)
    XCTAssertEqual(c.resolvedAlphabet.keyScores["a"], 9)
    XCTAssertEqual(c.resolvedAlphabet.keyScores["l"], 1)
  }

  func testLayoutIsInferredFromPresetKeys() {
    let c = ConfigLoader.parse("[hints]\nkeys = \"<colemak_homerow>\"")
    XCTAssertEqual(c.resolvedAlphabet.layoutName, "colemak")
  }

  func testResolvedAlphabetIsPreparedAndOnlyRefreshedExplicitly() {
    var c = ConfigLoader.parse("[hints]\nkeys = \"zsaq\"")
    XCTAssertEqual(String(c.resolvedAlphabet.chars), "zsaq")
    c.hints.keys = "<colemak_homerow>"
    XCTAssertEqual(
      String(c.resolvedAlphabet.chars),
      "zsaq",
      "direct mutation should not recompute hot-path derived data")
    c.prepareDerivedValues()
    XCTAssertEqual(c.resolvedAlphabet.layoutName, "colemak")
    XCTAssertEqual(String(c.resolvedAlphabet.chars), "arstnediho")
  }

  func testLayoutKeyIsNotAVisibleConfigProperty() {
    let c = ConfigLoader.parse(
      """
      [hints]
      keys = "<colemak_homerow>"
      layout = "<qwerty>"
      """)
    XCTAssertEqual(c.resolvedAlphabet.layoutName, "colemak")
  }

  func testParsesDebugProfiling() {
    let toml = """
      [debug]
      profile = true
      slow_ms = 42
      """
    let c = ConfigLoader.parse(toml)
    XCTAssertTrue(c.debug.profile)
    XCTAssertEqual(c.debug.slowMs, 42)
  }

  func testIgnoresComments() {
    let toml = """
      # a comment
      [hints]
      # another
      keys = "<dvorak>"  # inline
      """
    let c = ConfigLoader.parse(toml)
    XCTAssertEqual(c.hints.keys, "<dvorak>")
  }

  // MARK: CLI + env overrides

  func testCLIOverridesEveryField() {
    let base = Config()
    let args = [
      "flash",
      "--hints-keys=asdf",
      "--hints-min-length=3",
      "--hints-magic-modifiers=cmd,alt",
      "--overlay-font-size=20",
      "--overlay-hint-fg=#FFFFFF",
      "--overlay-hint-bg-top=#000000",
      "--overlay-hint-bg-bottom=#111111",
      "--overlay-hint-border=#222222",
      "--debug-show-bounds=true",
      "--debug-bounds-bg=#11223344",
      "--debug-bounds-fg=#55667788",
      "--debug-profile=true",
      "--debug-slow-ms=250",
      "--debug-dump-ax=true",
      "--debug-dump-logs=true",
      "--debug-log-level=debug",
    ]
    let c = ConfigLoader.applyOverrides(to: base, arguments: args, environment: [:])
    XCTAssertEqual(c.hints.keys, "asdf")
    XCTAssertEqual(String(c.resolvedAlphabet.chars), "asdf")
    XCTAssertEqual(c.hints.minLength, 3)
    XCTAssertEqual(c.hints.magicModifiers, ["cmd", "alt"])
    XCTAssertEqual(c.overlay.fontSize, 20)
    XCTAssertEqual(c.overlay.hintFG, "#FFFFFF")
    XCTAssertEqual(c.overlay.hintBGTop, "#000000")
    XCTAssertEqual(c.overlay.hintBGBottom, "#111111")
    XCTAssertEqual(c.overlay.hintBorder, "#222222")
    XCTAssertTrue(c.debug.showBounds)
    XCTAssertEqual(c.debug.boundsBG, "#11223344")
    XCTAssertEqual(c.debug.boundsFG, "#55667788")
    XCTAssertTrue(c.debug.profile)
    XCTAssertEqual(c.debug.slowMs, 250)
    XCTAssertTrue(c.debug.dumpAx)
    XCTAssertTrue(c.debug.dumpLogs)
    XCTAssertEqual(c.debug.logLevel, .debug)
  }

  func testEnvOverridesEveryField() {
    let base = Config()
    let env = [
      "FLASH_HINTS_KEYS": "qwer",
      "FLASH_HINTS_MIN_LENGTH": "2",
      "FLASH_HINTS_MAGIC_MODIFIERS": "ctrl,alt",
      "FLASH_OVERLAY_FONT_SIZE": "18",
      "FLASH_OVERLAY_HINT_FG": "#DDEEFF",
      "FLASH_OVERLAY_HINT_BG_TOP": "#AABBCC",
      "FLASH_OVERLAY_HINT_BG_BOTTOM": "#998877",
      "FLASH_OVERLAY_HINT_BORDER": "#665544",
      "FLASH_DEBUG_SHOW_BOUNDS": "yes",
      "FLASH_DEBUG_BOUNDS_BG": "#11111111",
      "FLASH_DEBUG_BOUNDS_FG": "#22222222",
      "FLASH_DEBUG_PROFILE": "on",
      "FLASH_DEBUG_SLOW_MS": "175",
      "FLASH_DEBUG_DUMP_AX": "true",
      "FLASH_DEBUG_DUMP_LOGS": "true",
      "FLASH_DEBUG_LOG_LEVEL": "warn",
    ]
    let c = ConfigLoader.applyOverrides(to: base, arguments: ["flash"], environment: env)
    XCTAssertEqual(c.hints.keys, "qwer")
    XCTAssertEqual(String(c.resolvedAlphabet.chars), "qwer")
    XCTAssertEqual(c.hints.minLength, 2)
    XCTAssertEqual(c.hints.magicModifiers, ["ctrl", "alt"])
    XCTAssertEqual(c.overlay.fontSize, 18)
    XCTAssertEqual(c.overlay.hintFG, "#DDEEFF")
    XCTAssertEqual(c.overlay.hintBGTop, "#AABBCC")
    XCTAssertEqual(c.overlay.hintBGBottom, "#998877")
    XCTAssertEqual(c.overlay.hintBorder, "#665544")
    XCTAssertTrue(c.debug.showBounds)
    XCTAssertEqual(c.debug.boundsBG, "#11111111")
    XCTAssertEqual(c.debug.boundsFG, "#22222222")
    XCTAssertTrue(c.debug.profile)
    XCTAssertEqual(c.debug.slowMs, 175)
    XCTAssertTrue(c.debug.dumpAx)
    XCTAssertTrue(c.debug.dumpLogs)
    XCTAssertEqual(c.debug.logLevel, .warn)
  }

  func testInvalidShortcutValueProducesWarning() {
    let toml = """
      [shortcuts]
      "cmd+ctrl+b" = "https://example.com"
      """
    let c = ConfigLoader.parse(toml)
    XCTAssertTrue(c.shortcuts.isEmpty)
    XCTAssertEqual(c.warnings.count, 1)
    XCTAssertTrue(c.warnings[0].contains("cmd+ctrl+b"))
  }

  func testShortcutRelativePathArgumentsResolveAgainstConfigFile() {
    let toml = """
      [shortcuts]
      "alt+shift+c" = ["sh", "../../scripts/toggle_caffeinate.sh"]
      "alt+shift+d" = ["sh", "~/.dotfiles/scripts/toggle_darkmode.sh"]
      "alt+shift+m" = ["sh", "$HOME/.dotfiles/scripts/toggle_mute.sh"]
      "alt+shift+w" = ["sh", "${HOME}/.dotfiles/scripts/toggle_wifi.sh"]
      "alt+shift+x" = ["sh", "-c", "echo /tmp/example", "https://example.com/a/b"]
      "alt+shift+y" = ["scripts/toggle_wifi.sh", "--flag=$HOME/path", "$NOPE/path"]
      """
    let sourceURL = URL(fileURLWithPath: "/Users/test/.dotfiles/.config/flash/config.toml")
    let c = ConfigLoader.parse(
      toml,
      sourceURL: sourceURL,
      environment: ["HOME": "/Users/envhome"])

    XCTAssertEqual(c.shortcuts.count, 6)

    guard case .shell(let caffeineArgv) = c.shortcuts[0].action else {
      return XCTFail("expected shell action")
    }
    XCTAssertEqual(
      caffeineArgv,
      ["sh", "/Users/test/.dotfiles/scripts/toggle_caffeinate.sh"])

    guard case .shell(let darkModeArgv) = c.shortcuts[1].action else {
      return XCTFail("expected shell action")
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    XCTAssertEqual(
      darkModeArgv,
      ["sh", "\(home)/.dotfiles/scripts/toggle_darkmode.sh"])

    guard case .shell(let muteArgv) = c.shortcuts[2].action else {
      return XCTFail("expected shell action")
    }
    XCTAssertEqual(
      muteArgv,
      ["sh", "/Users/envhome/.dotfiles/scripts/toggle_mute.sh"])

    guard case .shell(let wifiEnvArgv) = c.shortcuts[3].action else {
      return XCTFail("expected shell action")
    }
    XCTAssertEqual(
      wifiEnvArgv,
      ["sh", "/Users/envhome/.dotfiles/scripts/toggle_wifi.sh"])

    guard case .shell(let shellSnippetArgv) = c.shortcuts[4].action else {
      return XCTFail("expected shell action")
    }
    XCTAssertEqual(
      shellSnippetArgv,
      ["sh", "-c", "echo /tmp/example", "https://example.com/a/b"])

    guard case .shell(let relativeArgv) = c.shortcuts[5].action else {
      return XCTFail("expected shell action")
    }
    XCTAssertEqual(
      relativeArgv,
      [
        "/Users/test/.dotfiles/.config/flash/scripts/toggle_wifi.sh",
        "--flag=$HOME/path",
        "$NOPE/path",
      ])
  }

  func testCLIBeatsEnv() {
    // Both set; CLI must win.
    let base = Config()
    let args = ["flash", "--hints-min-length=3"]
    let env = ["FLASH_HINTS_MIN_LENGTH": "5"]
    let c = ConfigLoader.applyOverrides(to: base, arguments: args, environment: env)
    XCTAssertEqual(c.hints.minLength, 3)
  }

  func testCLIKeysBeatEnvAndRefreshPreparedAlphabet() {
    let base = ConfigLoader.parse("[hints]\nkeys = \"<qwerty_homerow>\"")
    let env = ["FLASH_HINTS_KEYS": "<colemak_homerow>"]
    let args = ["flash", "--hints-keys=zsaq"]
    let c = ConfigLoader.applyOverrides(to: base, arguments: args, environment: env)
    XCTAssertEqual(c.hints.keys, "zsaq")
    XCTAssertNil(c.resolvedAlphabet.layoutName)
    XCTAssertEqual(String(c.resolvedAlphabet.chars), "zsaq")
    XCTAssertEqual(c.resolvedAlphabet.keyScores["z"], 4)
    XCTAssertEqual(c.resolvedAlphabet.keyScores["q"], 1)
  }

  func testEnvBeatsTOML() {
    // Simulate "TOML produced 2; env says 5".
    var base = Config()
    base.hints.minLength = 2
    let env = ["FLASH_HINTS_MIN_LENGTH": "5"]
    let c = ConfigLoader.applyOverrides(to: base, arguments: ["flash"], environment: env)
    XCTAssertEqual(c.hints.minLength, 5)
  }

  func testInvalidCLIValueIsDropped() {
    var base = Config()
    base.hints.minLength = 2
    let args = ["flash", "--hints-min-length=garbage"]
    let c = ConfigLoader.applyOverrides(to: base, arguments: args, environment: [:])
    XCTAssertEqual(c.hints.minLength, 2)
  }

  func testUnknownCLIFlagIsIgnored() {
    let base = Config()
    let args = ["flash", "--nope=1", "--also-bad=foo"]
    let c = ConfigLoader.applyOverrides(to: base, arguments: args, environment: [:])
    XCTAssertEqual(c.hints.keys, base.hints.keys)
  }

  func testEnvVarOutsideFlashPrefixIsIgnored() {
    var base = Config()
    base.hints.keys = "<qwerty>"
    let env = [
      "HINTS_KEYS": "should-not-take",
      "FOO_BAR": "nope",
    ]
    let c = ConfigLoader.applyOverrides(to: base, arguments: ["flash"], environment: env)
    XCTAssertEqual(c.hints.keys, "<qwerty>")
  }

  func testBoolAcceptsCommonForms() {
    let base = Config()
    for v in ["true", "1", "yes", "on", "TRUE", "Yes"] {
      let c = ConfigLoader.applyOverrides(
        to: base, arguments: ["flash", "--debug-show-bounds=\(v)"], environment: [:])
      XCTAssertTrue(c.debug.showBounds, "expected `\(v)` to parse as true")
    }
    for v in ["false", "0", "no", "off", "FALSE"] {
      var b = base
      b.debug.showBounds = true
      let c = ConfigLoader.applyOverrides(
        to: b, arguments: ["flash", "--debug-show-bounds=\(v)"], environment: [:])
      XCTAssertFalse(c.debug.showBounds, "expected `\(v)` to parse as false")
    }
  }

  // MARK: Config path resolution

  func testResolvePathPrefersCLIConfigFlag() {
    let args = ["flash", "--config=/tmp/explicit.toml"]
    let env = ["FLASH_CONFIG": "/tmp/from-env.toml"]
    let url = ConfigLoader.resolvePath(arguments: args, environment: env)
    XCTAssertEqual(url.path, "/tmp/explicit.toml")
  }

  func testResolvePathFallsBackToEnv() {
    let args = ["flash"]
    let env = ["FLASH_CONFIG": "/tmp/from-env.toml"]
    let url = ConfigLoader.resolvePath(arguments: args, environment: env)
    XCTAssertEqual(url.path, "/tmp/from-env.toml")
  }

  func testCandidatePathsHonourXDGHome() {
    // First candidate when XDG_CONFIG_HOME is set is XDG-rooted.
    let args = ["flash"]
    let env = ["XDG_CONFIG_HOME": "/tmp/xdg"]
    let paths = ConfigLoader.candidatePaths(arguments: args, environment: env)
    XCTAssertEqual(paths.first?.path, "/tmp/xdg/flash/flash.toml")
  }

  func testCandidatePathsFallbackChain() {
    // No XDG → only the home-rooted paths, in priority order.
    let args = ["flash"]
    let env: [String: String] = [:]
    let paths = ConfigLoader.candidatePaths(arguments: args, environment: env)
      .map { $0.path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    XCTAssertEqual(
      paths,
      [
        "\(home)/.config/flash/flash.toml",
        "\(home)/.flash.toml",
      ])
  }

  private static func parseJSONObject(_ json: String) throws -> [String: Any]? {
    let data = Data(json.utf8)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
  }
}
