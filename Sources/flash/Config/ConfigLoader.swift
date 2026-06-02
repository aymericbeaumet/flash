import Foundation

enum ConfigLoader {
    static var defaultPath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let envPath = ProcessInfo.processInfo.environment["FLASH_CONFIG"]
        if let p = envPath, !p.isEmpty { return URL(fileURLWithPath: p) }
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let base = xdg.flatMap { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        return base.appendingPathComponent("flash/config.toml")
    }

    static func load(from url: URL = defaultPath) -> Config {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return .default
        }
        return parse(text)
    }

    static func parse(_ text: String) -> Config {
        var config = Config()
        var currentTable: [String] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let hashIdx = unquotedCommentIndex(in: line) {
                line = String(line[..<hashIdx]).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let inner = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                currentTable = splitTablePath(inner)
                continue
            }
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eqIdx]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
            apply(table: currentTable, key: key, value: val, into: &config)
        }
        return config
    }

    private static func unquotedCommentIndex(in line: String) -> String.Index? {
        var inString = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "\"" { inString.toggle() }
            else if c == "#" && !inString { return i }
            i = line.index(after: i)
        }
        return nil
    }

    private static func splitTablePath(_ raw: String) -> [String] {
        var parts: [String] = []
        var buf = ""
        var inString = false
        for c in raw {
            if c == "\"" { inString.toggle(); continue }
            if c == "." && !inString { parts.append(buf); buf = ""; continue }
            buf.append(c)
        }
        if !buf.isEmpty { parts.append(buf) }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func apply(table: [String], key: String, value: String, into config: inout Config) {
        let path = table + [key]
        switch path {
        case ["hints", "keys"]:
            config.hints.keys = parseString(value) ?? config.hints.keys
        case ["hints", "shift_means_right_click"]:
            config.hints.shiftMeansRightClick = parseBool(value) ?? config.hints.shiftMeansRightClick
        case ["hints", "min_length"]:
            config.hints.minLength = parseInt(value) ?? config.hints.minLength

        case ["overlay", "font_size"]:
            config.overlay.fontSize = parseDouble(value) ?? config.overlay.fontSize
        case ["overlay", "hint_bg"]:
            config.overlay.hintBG = parseString(value) ?? config.overlay.hintBG
        case ["overlay", "hint_fg"]:
            config.overlay.hintFG = parseString(value) ?? config.overlay.hintFG
        case ["overlay", "dim_background"]:
            config.overlay.dimBackground = parseBool(value) ?? config.overlay.dimBackground
        case ["overlay", "exit_key"]:
            config.overlay.exitKey = parseString(value) ?? config.overlay.exitKey

        case ["providers", "disabled"]:
            config.providers.disabled = parseStringArray(value) ?? config.providers.disabled
        case ["providers", "deadline_ms_hot"]:
            config.providers.deadlineMsHot = parseInt(value) ?? config.providers.deadlineMsHot
        case ["providers", "deadline_ms_cold"]:
            config.providers.deadlineMsCold = parseInt(value) ?? config.providers.deadlineMsCold
        case ["providers", "vision", "enabled_for_bundles"]:
            config.providers.visionEnabledBundles = parseStringArray(value) ?? config.providers.visionEnabledBundles

        default:
            if path.count == 3, path[0] == "per_app", path[2] == "roles" {
                if let arr = parseStringArray(value) {
                    config.perAppRoles[path[1]] = arr
                }
            }
        }
    }

    private static func parseString(_ v: String) -> String? {
        guard v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 else { return nil }
        return String(v.dropFirst().dropLast())
    }
    private static func parseBool(_ v: String) -> Bool? {
        switch v { case "true": return true; case "false": return false; default: return nil }
    }
    private static func parseInt(_ v: String) -> Int? { Int(v) }
    private static func parseDouble(_ v: String) -> Double? { Double(v) }
    private static func parseStringArray(_ v: String) -> [String]? {
        guard v.hasPrefix("["), v.hasSuffix("]") else { return nil }
        let inner = v.dropFirst().dropLast()
        var out: [String] = []
        var buf = ""
        var inString = false
        for c in inner {
            if c == "\"" { inString.toggle(); continue }
            if c == "," && !inString {
                let trimmed = buf.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(trimmed) }
                buf = ""
                continue
            }
            if inString { buf.append(c) }
        }
        let trimmed = buf.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { out.append(trimmed) }
        return out
    }
}
