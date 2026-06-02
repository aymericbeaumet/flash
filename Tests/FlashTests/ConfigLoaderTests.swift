import XCTest
@testable import flash

final class ConfigLoaderTests: XCTestCase {
    func testDefaultsWhenEmpty() {
        let c = ConfigLoader.parse("")
        XCTAssertEqual(c.hints.keys, "<colemak>")
        XCTAssertEqual(c.hints.minLength, 1)
        XCTAssertEqual(c.hints.shiftMeansRightClick, true)
        XCTAssertEqual(c.overlay.fontSize, 14)
        XCTAssertEqual(c.providers.deadlineMsHot, 80)
    }

    func testParsesHintsSection() {
        let toml = """
        [hints]
        keys = "<qwerty>"
        shift_means_right_click = false
        min_length = 2
        """
        let c = ConfigLoader.parse(toml)
        XCTAssertEqual(c.hints.keys, "<qwerty>")
        XCTAssertEqual(c.hints.shiftMeansRightClick, false)
        XCTAssertEqual(c.hints.minLength, 2)
    }

    func testParsesLiteralKeys() {
        let c = ConfigLoader.parse("[hints]\nkeys = \"asdfghjkl\"")
        XCTAssertEqual(c.hints.keys, "asdfghjkl")
        XCTAssertEqual(String(c.resolvedAlphabet), "asdfghjkl")
    }

    func testParsesArray() {
        let toml = """
        [providers.vision]
        enabled_for_bundles = ["org.alacritty", "net.whatsapp.WhatsApp"]
        """
        let c = ConfigLoader.parse(toml)
        XCTAssertEqual(c.providers.visionEnabledBundles, ["org.alacritty", "net.whatsapp.WhatsApp"])
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
