import Foundation

struct Config {
    struct Hints {
        var keys: String = "<qwerty>"
        var minLength: Int = 1
    }
    struct Overlay {
        var fontSize: Double = 14
        var hintBG: String = "#FFD400"
        var hintFG: String = "#1B1B1B"
        var exitKey: String = "escape"
    }
    struct Providers {
        var disabled: [String] = []
        var deadlineMsHot: Int = 80
        var deadlineMsCold: Int = 300
    }
    struct Debug {
        /// When true, every detected target is outlined alongside its hint chip.
        /// Useful for diagnosing missing or misplaced hints — you can see exactly
        /// which AX rect Flash decided to use.
        var showBounds: Bool = false
        /// Fill for the debug outline rectangle. Default transparent.
        var boundsBG: String = "#00000000"
        /// Stroke for the debug outline rectangle. Mirrors the `hint_fg` slot:
        /// it's the foreground colour of the bounds shape.
        var boundsFG: String = "#FF3B9A"
    }

    var hints = Hints()
    var overlay = Overlay()
    var providers = Providers()
    var debug = Debug()
    var perAppRoles: [String: [String]] = [:]
    var warnings: [String] = []

    static let `default` = Config()

    var resolvedAlphabet: Alphabet.Resolved {
        Alphabet.resolve(hints.keys)
    }

    /// Stable identity of the hint-generation inputs. Used as the alphabet
    /// component of the precompute cache key, so a config hot-reload that
    /// changes the alphabet or min-length invalidates labels but keeps the
    /// underlying target geometry valid through the next walk.
    var alphabetKey: String {
        "\(hints.keys)|\(hints.minLength)"
    }
}
