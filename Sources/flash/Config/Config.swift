import Foundation

struct Config {
    struct Hints {
        var keys: String = "<colemak>"
        var shiftMeansRightClick: Bool = true
        var minLength: Int = 1
    }
    struct Overlay {
        var fontSize: Double = 14
        var hintBG: String = "#FFD400"
        var hintFG: String = "#1B1B1B"
        var dimBackground: Bool = true
        var exitKey: String = "escape"
    }
    struct Providers {
        var disabled: [String] = []
        var deadlineMsHot: Int = 80
        var deadlineMsCold: Int = 300
        // OCR is opt-in: it forces a Screen Recording permission prompt on first use.
        // Default empty; users who want hints in terminals / Electron apps add the bundle.
        var visionEnabledBundles: [String] = []
    }

    var hints = Hints()
    var overlay = Overlay()
    var providers = Providers()
    var perAppRoles: [String: [String]] = [:]
    var warnings: [String] = []

    static let `default` = Config()

    var resolvedAlphabet: [Character] {
        let (chars, _) = Alphabet.resolve(hints.keys)
        return chars
    }
}
