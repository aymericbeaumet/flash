import Foundation

/// Data selects a fixed host template. Plugin strings are always literals,
/// never source, application terminology, property names or commands.
enum PluginAppleScriptOperation {
  struct Refusal: Error, Equatable { let message: String }

  private static let chromium = Set([
    "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
    "com.google.Chrome.dev", "org.chromium.Chromium", "com.brave.Browser",
    "com.brave.Browser.beta", "com.brave.Browser.nightly", "com.microsoft.edgemac",
    "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
    "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    "com.operasoftware.OperaNext", "com.operasoftware.OperaDeveloper",
  ])
  private static let safari = Set(["com.apple.Safari", "com.apple.SafariTechnologyPreview"])

  static func script(_ params: [String: Any], targets: [String]) -> Result<String, Refusal> {
    do { return .success(try build(params, targets: targets)) } catch let error as Refusal {
      return .failure(error)
    } catch { return .failure(Refusal(message: "invalid AppleScript operation")) }
  }

  static func quote(_ text: String) -> String {
    "\""
      + text.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\r", with: "\\r")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\t", with: "\\t") + "\""
  }

  private static func build(_ params: [String: Any], targets: [String]) throws -> String {
    func refuse(_ message: String) -> Refusal { Refusal(message: message) }
    guard let operation = params["operation"] as? String else {
      throw refuse("host.applescript requires a supported operation")
    }
    let fields: [String: Set<String>] = [
      "browser_tabs": ["bundle_id"],
      "browser_select": ["bundle_id", "url", "title", "window", "tab"],
      "browser_tab_index": ["bundle_id", "index"],
      "browser_tab_move": ["bundle_id", "forward"],
      "shortcuts_list": [], "shortcut_run": ["name"], "chat_submit": ["bundle_id"],
    ]
    guard let allowed = fields[operation],
      Set(params.keys).isSubset(of: allowed.union(["operation", "timeout_ms"]))
    else { throw refuse("unsupported AppleScript operation or field") }
    func string(_ key: String, required: Bool = true) throws -> String? {
      guard let raw = params[key] else {
        if required { throw refuse("operation requires \(key)") }
        return nil
      }
      guard let value = raw as? String, !value.contains("\0"),
        value.utf8.count <= PluginProtocol.maxAppleScriptScriptBytes
      else { throw refuse("invalid operation string: \(key)") }
      return value
    }
    func integer(_ key: String) throws -> Int {
      guard let raw = params[key], let value = PluginJSON.integer(raw), value > 0,
        value <= 1_000_000
      else { throw refuse("operation requires a positive integer \(key)") }
      return value
    }
    let target: String
    if operation == "shortcuts_list" || operation == "shortcut_run" {
      target = "com.apple.shortcuts.events"
    } else if operation == "chat_submit" {
      target = "com.apple.systemevents"
    } else {
      target = try string("bundle_id")!
      guard chromium.contains(target) || safari.contains(target) else {
        throw refuse("unsupported browser bundle_id")
      }
    }
    guard targets.contains(where: { $0.caseInsensitiveCompare(target) == .orderedSame }) else {
      throw refuse("operation target is outside apple_events_targets")
    }
    let isSafari = safari.contains(target)
    let title = isSafari ? "name" : "title"
    let active = isSafari ? "index of current tab of w" : "active tab index of w"
    let select = isSafari ? "set current tab of w to t" : "set active tab index of w to i"
    let app = quote(target)
    switch operation {
    case "shortcuts_list":
      return """
        tell application id \(app)
          set output to name of every shortcut
        end tell
        set AppleScript's text item delimiters to linefeed
        return output as text
        """
    case "shortcut_run":
      guard let name = try string("name"), !name.isEmpty else {
        throw refuse("empty shortcut name")
      }
      return "tell application id \(app) to run shortcut named \(quote(name))"
    case "chat_submit":
      let bundle = try string("bundle_id")!
      let gecko = Set([
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
      ])
      guard chromium.contains(bundle) || safari.contains(bundle) || gecko.contains(bundle) else {
        throw refuse("chat_submit requires a supported browser bundle_id")
      }
      return
        "tell application id \(app) to if bundle identifier of (first application process whose frontmost is true) is \(quote(bundle)) then key code 36"
    case "browser_tabs":
      return """
        set out to ""
        set sep to character id 9
        tell application id \(app)
          set windowIndex to 0
          repeat with w in windows
            set windowIndex to windowIndex + 1
            set activeIndex to 0
            try
              set activeIndex to \(active)
            end try
            set tabIndex to 0
            repeat with t in tabs of w
              set tabIndex to tabIndex + 1
              try
                set isCurrent to "0"
                if windowIndex is 1 and tabIndex is activeIndex then set isCurrent to "1"
                set out to out & (windowIndex as text) & sep & (tabIndex as text) & sep & isCurrent & sep & (URL of t as text) & sep & (\(title) of t as text) & linefeed
              end try
            end repeat
          end repeat
        end tell
        return out
        """
    case "browser_select":
      let url = try string("url", required: false)
      let value = try string("title", required: false)
      guard url?.isEmpty == false || value?.isEmpty == false else {
        throw refuse("browser_select requires a URL or title")
      }
      var targets = ""
      var conditions: [String] = []
      if let url {
        targets += "\nset targetURL to \(quote(url))"
        conditions.append("((URL of t as text) is targetURL)")
      }
      if let value {
        targets += "\nset targetTitle to \(quote(value))"
        conditions.append("((\(title) of t as text) is targetTitle)")
      }
      let window: Int?
      let tab: Int?
      if params["window"] != nil || params["tab"] != nil {
        window = try integer("window")
        tab = try integer("tab")
      } else {
        window = nil
        tab = nil
      }
      var passes = [conditions.joined(separator: " and ")]
      if url != nil, value != nil { passes.append(conditions[0]) }
      let searches = passes.map { search($0, select: select, window: window, tab: tab) }.joined(
        separator: "\n")
      return """
        tell application id \(app)
          activate\(targets)
          considering case
        \(searches)
          end considering
        end tell
        return "missing"
        """
    case "browser_tab_index":
      let index = try integer("index")
      let nth =
        isSafari
        ? "set current tab of w to tab tabIndex of w" : "set active tab index of w to tabIndex"
      return """
        tell application id \(app)
          activate
          set tabIndex to \(index)
          repeat with w in windows
            if (count of tabs of w) >= tabIndex then
              \(nth)
              set index of w to 1
              return "ok"
            end if
            set tabIndex to tabIndex - (count of tabs of w)
          end repeat
        end tell
        return "missing"
        """
    case "browser_tab_move":
      guard isSafari, let forward = PluginJSON.boolean(params["forward"]) else {
        throw refuse("browser_tab_move requires Safari and boolean forward")
      }
      let swap =
        forward
        ? "if i < n then move tab (i + 1) of w to before tab i of w"
        : "if i > 1 then move tab (i - 1) of w to after tab i of w"
      return """
        tell application id \(app)
          if (count of windows) is 0 then return "missing"
          set w to front window
          set i to \(active)
          set n to count of tabs of w
          \(swap)
          return "ok"
        end tell
        """
    default: throw refuse("unsupported AppleScript operation")
    }
  }

  private static func search(_ condition: String, select: String, window: Int?, tab: Int?) -> String
  {
    let commit = """
      if \(condition) then
        \(select)
        set index of w to 1
        return "ok"
      end if
      """
    var source = ""
    if let window, let tab {
      source += """
        try
          set w to window \(window)
          set i to \(tab)
          set t to tab i of w
          \(commit)
        end try
        try
          set w to window \(window)
          repeat with i from 1 to (count of tabs of w)
            set t to tab i of w
            try
              \(commit)
            end try
          end repeat
        end try

        """
    }
    return source + """
      repeat with wi from 1 to (count of windows)
        if wi is not \(window ?? 0) then
          set w to window wi
          repeat with i from 1 to (count of tabs of w)
            set t to tab i of w
            try
              \(commit)
            end try
          end repeat
        end if
      end repeat
      """
  }
}
