import XCTest
@testable import flash

final class ConfigLoaderTests: XCTestCase {
    func testDefaultsWhenEmpty() {
        let c = ConfigLoader.parse("")
        XCTAssertEqual(c.hints.keys, "<qwerty>")
        XCTAssertEqual(c.hints.minLength, 1)
        XCTAssertEqual(c.hints.scope, .activeApp)
        XCTAssertEqual(c.overlay.fontSize, 14)
        XCTAssertFalse(c.debug.profile)
        XCTAssertEqual(c.debug.slowMs, 100)
    }

    func testParsesHintsSection() {
        let toml = """
        [hints]
        keys = "<colemak>"
        min_length = 2
        """
        let c = ConfigLoader.parse(toml)
        XCTAssertEqual(c.hints.keys, "<colemak>")
        XCTAssertEqual(c.hints.minLength, 2)
    }

    func testParsesLiteralKeys() {
        let c = ConfigLoader.parse("[hints]\nkeys = \"asdfghjkl\"")
        XCTAssertEqual(c.hints.keys, "asdfghjkl")
        XCTAssertEqual(String(c.resolvedAlphabet.chars), "asdfghjkl")
    }

    func testParsesScopeActiveMonitor() {
        let c = ConfigLoader.parse("[hints]\nscope = \"active_monitor\"")
        XCTAssertEqual(c.hints.scope, .activeMonitor)
    }

    func testParsesScopeEverywhere() {
        let c = ConfigLoader.parse("[hints]\nscope = \"everywhere\"")
        XCTAssertEqual(c.hints.scope, .everywhere)
    }

    func testUnknownScopeFallsBackToDefault() {
        let c = ConfigLoader.parse("[hints]\nscope = \"wat\"")
        XCTAssertEqual(c.hints.scope, .activeApp)
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
            "--hints-scope=everywhere",
            "--overlay-font-size=20",
            "--overlay-hint-bg=#000000",
            "--overlay-hint-fg=#FFFFFF",
            "--overlay-exit-key=q",
            "--debug-show-bounds=true",
            "--debug-bounds-bg=#11223344",
            "--debug-bounds-fg=#55667788",
            "--debug-profile=true",
            "--debug-slow-ms=250",
        ]
        let c = ConfigLoader.applyOverrides(to: base, arguments: args, environment: [:])
        XCTAssertEqual(c.hints.keys, "asdf")
        XCTAssertEqual(c.hints.minLength, 3)
        XCTAssertEqual(c.hints.scope, .everywhere)
        XCTAssertEqual(c.overlay.fontSize, 20)
        XCTAssertEqual(c.overlay.hintBG, "#000000")
        XCTAssertEqual(c.overlay.hintFG, "#FFFFFF")
        XCTAssertEqual(c.overlay.exitKey, "q")
        XCTAssertTrue(c.debug.showBounds)
        XCTAssertEqual(c.debug.boundsBG, "#11223344")
        XCTAssertEqual(c.debug.boundsFG, "#55667788")
        XCTAssertTrue(c.debug.profile)
        XCTAssertEqual(c.debug.slowMs, 250)
    }

    func testEnvOverridesEveryField() {
        let base = Config()
        let env = [
            "FLASH_HINTS_KEYS": "qwer",
            "FLASH_HINTS_MIN_LENGTH": "2",
            "FLASH_HINTS_SCOPE": "active_monitor",
            "FLASH_OVERLAY_FONT_SIZE": "18",
            "FLASH_OVERLAY_HINT_BG": "#AABBCC",
            "FLASH_OVERLAY_HINT_FG": "#DDEEFF",
            "FLASH_OVERLAY_EXIT_KEY": "x",
            "FLASH_DEBUG_SHOW_BOUNDS": "yes",
            "FLASH_DEBUG_BOUNDS_BG": "#11111111",
            "FLASH_DEBUG_BOUNDS_FG": "#22222222",
            "FLASH_DEBUG_PROFILE": "on",
            "FLASH_DEBUG_SLOW_MS": "175",
        ]
        let c = ConfigLoader.applyOverrides(to: base, arguments: ["flash"], environment: env)
        XCTAssertEqual(c.hints.keys, "qwer")
        XCTAssertEqual(c.hints.minLength, 2)
        XCTAssertEqual(c.hints.scope, .activeMonitor)
        XCTAssertEqual(c.overlay.fontSize, 18)
        XCTAssertEqual(c.overlay.hintBG, "#AABBCC")
        XCTAssertEqual(c.overlay.hintFG, "#DDEEFF")
        XCTAssertEqual(c.overlay.exitKey, "x")
        XCTAssertTrue(c.debug.showBounds)
        XCTAssertEqual(c.debug.boundsBG, "#11111111")
        XCTAssertEqual(c.debug.boundsFG, "#22222222")
        XCTAssertTrue(c.debug.profile)
        XCTAssertEqual(c.debug.slowMs, 175)
    }

    func testCLIBeatsEnv() {
        // Both set; CLI must win.
        let base = Config()
        let args = ["flash", "--hints-scope=everywhere"]
        let env = ["FLASH_HINTS_SCOPE": "active_monitor"]
        let c = ConfigLoader.applyOverrides(to: base, arguments: args, environment: env)
        XCTAssertEqual(c.hints.scope, .everywhere)
    }

    func testEnvBeatsTOML() {
        // Simulate "TOML produced active_monitor; env says everywhere".
        var base = Config()
        base.hints.scope = .activeMonitor
        let env = ["FLASH_HINTS_SCOPE": "everywhere"]
        let c = ConfigLoader.applyOverrides(to: base, arguments: ["flash"], environment: env)
        XCTAssertEqual(c.hints.scope, .everywhere)
    }

    func testInvalidCLIValueIsDropped() {
        var base = Config()
        base.hints.scope = .activeApp
        let args = ["flash", "--hints-scope=garbage"]
        let c = ConfigLoader.applyOverrides(to: base, arguments: args, environment: [:])
        XCTAssertEqual(c.hints.scope, .activeApp)
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
            let c = ConfigLoader.applyOverrides(to: base, arguments: ["flash", "--debug-show-bounds=\(v)"], environment: [:])
            XCTAssertTrue(c.debug.showBounds, "expected `\(v)` to parse as true")
        }
        for v in ["false", "0", "no", "off", "FALSE"] {
            var b = base; b.debug.showBounds = true
            let c = ConfigLoader.applyOverrides(to: b, arguments: ["flash", "--debug-show-bounds=\(v)"], environment: [:])
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

    func testResolvePathFallsBackToXDGHome() {
        let args = ["flash"]
        let env = ["XDG_CONFIG_HOME": "/tmp/xdg"]
        let url = ConfigLoader.resolvePath(arguments: args, environment: env)
        XCTAssertEqual(url.path, "/tmp/xdg/flash/config.toml")
    }
}
