import FlashCore
import XCTest

@testable import flash

final class PluginAppleScriptOperationTests: XCTestCase {
  private let targets = [
    "com.apple.Safari", "com.google.Chrome", "com.apple.shortcuts.events", "com.apple.systemevents",
    "com.spotify.client", "com.apple.TV",
  ]
  private func script(
    _ params: [String: Any], browsers: BrowserEngineTable = .sample
  ) throws -> String {
    try PluginAppleScriptOperation.script(params, targets: targets, browsers: browsers).get()
  }

  func testRejectsSourceAndUnknownOperationsBeforeExecution() {
    for params: [String: Any] in [
      ["script": "do shell script \"touch /tmp/escape\""],
      ["operation": "run_script", "script": "return 1"],
      ["operation": "shortcuts_list", "script": "return 1"],
      ["operation": "shortcuts_list", "target": "com.apple.Finder"],
      ["operation": "browser_tabs", "bundle_id": "com.apple.Finder"],
      ["operation": "browser_tabs", "bundle_id": "x\" & do shell script \"id"],
      ["operation": "browser_tab_index", "bundle_id": "com.apple.Safari", "index": true],
      ["operation": "browser_tab_index", "bundle_id": "com.apple.Safari", "index": "1"],
      ["operation": "browser_tab_move", "bundle_id": "com.apple.Safari", "forward": 1],
      ["operation": "browser_select", "bundle_id": "com.apple.Safari", "url": "x", "window": 1],
      ["operation": "shortcut_run", "name": "x\0y"],
    ] { XCTAssertThrowsError(try script(params), "\(params)") }
    XCTAssertThrowsError(
      try PluginAppleScriptOperation.script(
        ["operation": "shortcuts_list"], targets: [], browsers: .sample
      ).get())
  }

  /// The host names no browser: an app is one, and speaks a dialect, because
  /// a manifest declares its engine.
  func testBrowserOperationsServeTheDeclaredEnginesInTheirDialect() throws {
    let tabs: [String: Any] = ["operation": "browser_tabs", "bundle_id": "com.google.Chrome"]
    XCTAssertTrue(try script(tabs).contains("active tab index of w"))
    XCTAssertTrue(
      try script(tabs, browsers: BrowserEngineTable(["com.google.Chrome": .webkit]))
        .contains("index of current tab of w"), "the declared engine picks the dialect")
    for undeclared in [
      BrowserEngineTable(), BrowserEngineTable(["com.google.Chrome": .gecko]),
    ] {
      XCTAssertThrowsError(try script(tabs, browsers: undeclared)) { error in
        XCTAssertEqual(
          error as? PluginAppleScriptOperation.Refusal,
          PluginAppleScriptOperation.Refusal(message: "unsupported browser bundle_id"))
      }
    }
    let submit: [String: Any] = ["operation": "chat_submit", "bundle_id": "com.google.Chrome"]
    XCTAssertThrowsError(try script(submit, browsers: BrowserEngineTable()))
    XCTAssertNoThrow(
      try script(submit, browsers: BrowserEngineTable(["com.google.Chrome": .gecko])))
    XCTAssertNoThrow(
      try script(["operation": "shortcuts_list"], browsers: BrowserEngineTable()),
      "operations that address no browser need no declaration")
  }

  func testUntrustedTextIsAlwaysAnEscapedLiteral() throws {
    let text = "x\"\nend tell\ndo shell script \"touch /tmp/escape\" --\\"
    let source = try script(["operation": "shortcut_run", "name": text])
    XCTAssertEqual(
      source,
      "tell application id \"com.apple.shortcuts.events\" to run shortcut named "
        + PluginAppleScriptOperation.quote(text))
    XCTAssertFalse(source.contains("\n"), "newlines remain inside an escaped string literal")
    XCTAssertThrowsError(try script(["operation": "chat_submit", "bundle_id": text]))
  }

  func testQuotedDataRemainsDataInTheAppleScriptRuntime() {
    let value = "quoted \" value\nreturn \"injected\" --\\ tail"
    let done = expectation(description: "quoted value evaluates")
    var output: AppleScriptOutput?
    DispatchQueue.global(qos: .userInitiated).async {
      output = AppleScriptRunner.run(
        "return " + PluginAppleScriptOperation.quote(value), timeout: 3)
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    XCTAssertTrue(output?.ok == true, output?.stderr ?? "no output")
    XCTAssertEqual(output?.stdout, value + "\n")
  }

  func testBrowserSelectionKeepsIdentityOrderAndPositionSemantics() throws {
    let source = try script([
      "operation": "browser_select", "bundle_id": "com.google.Chrome",
      "url": "https://example.com/\"q\"", "title": "Inbox", "window": 2, "tab": 3,
    ])
    XCTAssertTrue(source.contains("considering case"))
    XCTAssertTrue(
      source.contains("((URL of t as text) is targetURL) and ((title of t as text) is targetTitle)")
    )
    XCTAssertTrue(
      source.contains("if ((URL of t as text) is targetURL) then"),
      "retitled tabs fall back to URL identity")
    XCTAssertEqual(source.components(separatedBy: "set active tab index of w to i").count - 1, 6)
    XCTAssertFalse(source.contains("index of t"))
    XCTAssertLessThan(
      source.range(of: "set w to window 2")!.lowerBound,
      source.range(of: "repeat with wi")!.lowerBound)
    let titleOnly = try script([
      "operation": "browser_select", "bundle_id": "com.apple.Safari", "title": "Inbox",
    ])
    XCTAssertFalse(titleOnly.contains("targetURL"))
    XCTAssertTrue(titleOnly.contains("set current tab of w to t"))
  }

  func testChatSubmitIsConfinedToSupportedBrowsers() throws {
    for bundle in [
      "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox",
      "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
    ] {
      let source = try script(["operation": "chat_submit", "bundle_id": bundle])
      XCTAssertTrue(source.contains("whose frontmost is true"))
      XCTAssertTrue(
        source.contains("is " + PluginAppleScriptOperation.quote(bundle) + " then key code 36"))
    }
    for bundle in [
      "com.apple.Terminal", "com.apple.ScriptEditor2", "com.apple.finder", "unknown.browser",
    ] {
      XCTAssertThrowsError(try script(["operation": "chat_submit", "bundle_id": bundle]))
    }
  }

  /// `now_playing` asks the app the plugin names, held to its declared
  /// targets, and never launches it.
  func testNowPlayingAsksADeclaredPlayerWithoutLaunchingIt() throws {
    let spotify = try script([
      "operation": "now_playing", "bundle_id": "com.spotify.client", "artist": true,
    ])
    XCTAssertEqual(
      spotify,
      """
      if application id "com.spotify.client" is not running then return ""
      with timeout of 10 seconds
        tell application id "com.spotify.client"
          set playerState to player state as text
          set trackText to ""
          try
            set trackText to name of current track & " — " & artist of current track
          end try
          return playerState & linefeed & trackText
        end tell
      end timeout
      """)
    let tv = try script(["operation": "now_playing", "bundle_id": "com.apple.TV", "artist": false])
    XCTAssertTrue(tv.contains("set trackText to name of current track\n"))
    XCTAssertFalse(tv.contains("artist"))
    XCTAssertTrue(tv.hasPrefix("if application id \"com.apple.TV\" is not running then return"))
    let refusals: [([String: Any], String)] = [
      (
        ["operation": "now_playing", "bundle_id": "com.apple.Music", "artist": true],
        "operation target is outside apple_events_targets"
      ),
      (
        ["operation": "now_playing", "bundle_id": "com.apple.TV"],
        "now_playing requires boolean artist"
      ),
      (
        ["operation": "now_playing", "bundle_id": "com.apple.TV", "artist": "yes"],
        "now_playing requires boolean artist"
      ),
      (["operation": "now_playing", "artist": true], "operation requires bundle_id"),
      (
        ["operation": "now_playing", "bundle_id": "com.apple.TV", "artist": true, "track": 1],
        "unsupported AppleScript operation or field"
      ),
      (
        [
          "operation": "now_playing", "artist": true,
          "bundle_id": "com.apple.TV\" to quit\ntell application id \"com.apple.TV",
        ],
        "operation target is outside apple_events_targets"
      ),
    ]
    for (params, message) in refusals {
      XCTAssertThrowsError(try script(params), "\(params)") { error in
        XCTAssertEqual(
          error as? PluginAppleScriptOperation.Refusal,
          PluginAppleScriptOperation.Refusal(message: message), "\(params)")
      }
    }
  }

  func testTemplatesUseHostOwnedDialectsAndFocusGuards() throws {
    let listed = try script(["operation": "browser_tabs", "bundle_id": "com.apple.Safari"])
    XCTAssertLessThan(
      listed.range(of: "set sep to character id 9")!.lowerBound,
      listed.range(of: "tell application")!.lowerBound)
    XCTAssertTrue(listed.contains("index of current tab of w"))
    XCTAssertTrue(listed.contains("(name of t as text)"))
    let moved = try script([
      "operation": "browser_tab_move", "bundle_id": "com.apple.Safari", "forward": true,
    ])
    XCTAssertTrue(moved.contains("move tab (i + 1) of w to before tab i of w"))
    XCTAssertThrowsError(
      try script([
        "operation": "browser_tab_move", "bundle_id": "com.google.Chrome", "forward": true,
      ]))
    let submit = try script(["operation": "chat_submit", "bundle_id": "com.google.Chrome"])
    XCTAssertTrue(submit.contains("whose frontmost is true"))
    XCTAssertTrue(submit.contains("is \"com.google.Chrome\" then key code 36"))
  }
}
