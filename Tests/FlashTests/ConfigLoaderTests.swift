import XCTest
@testable import flash

final class ConfigLoaderTests: XCTestCase {
    func testDefaultsWhenEmpty() {
        let c = ConfigLoader.parse("")
        XCTAssertEqual(c.hints.keys, "<qwerty>")
        XCTAssertEqual(c.hints.minLength, 1)
        XCTAssertEqual(c.overlay.fontSize, 14)
        XCTAssertEqual(c.providers.deadlineMsHot, 80)
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

    func testParsesArray() {
        let toml = """
        [providers]
        disabled = ["whatsapp", "slack"]
        """
        let c = ConfigLoader.parse(toml)
        XCTAssertEqual(c.providers.disabled, ["whatsapp", "slack"])
    }

    func testParsesPerApp() {
        let toml = """
        [per_app."com.apple.Notes"]
        roles = ["AXButton", "AXRow"]
        """
        let c = ConfigLoader.parse(toml)
        XCTAssertEqual(c.perAppRoles["com.apple.Notes"], ["AXButton", "AXRow"])
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
}
