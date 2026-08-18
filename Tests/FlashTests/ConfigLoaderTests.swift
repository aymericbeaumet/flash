import AppKit
import Carbon.HIToolbox
import FlashCore
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
    assertSendKey(
      c.mode.normal.first(where: { $0.key == "j" })?.action.command,
      keys: "down",
      keyCode: CGKeyCode(kVK_DownArrow))
    assertSendKey(
      c.mode.normal.first(where: { $0.key == "k" })?.action.command,
      keys: "up",
      keyCode: CGKeyCode(kVK_UpArrow))
    XCTAssertEqual(c.mode.normalLeader, "\\")
    XCTAssertEqual(c.mode.normalPassthroughKeys, ["escape"])
    XCTAssertEqual(c.mode.normalPassthroughKeyCodes, [UInt32(kVK_Escape)])
    XCTAssertEqual(c.mode.normalPassthroughModifiers, ["cmd", "ctrl", "shift", "alt"])
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("\\<space>") })?.action.command,
      .enterCommand(input: "flashlight ", restoreMode: false))
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("sf") })?.action.command,
      .mouseTarget(.click(.rightClick, modifiers: [])))
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("Df") })?.action.command,
      .mouseTarget(.click(.doubleClick, modifiers: [])))
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("mf") })?.action.command,
      .mouseTarget(.move))
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == "F" })?.action.command,
      .mouseTarget(.click(.leftClick, modifiers: [.command, .shift])))
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("ctrl+f") })?.action.command,
      .mouseGrid(.click(.leftClick, modifiers: [])))
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("ctrl+shift+f") })?.action.command,
      .mouseGrid(.click(.leftClick, modifiers: [.command, .shift])))
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("mF") })?.action.command,
      .mouseGrid(.move))
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("yy") })?.action.command,
      .copyURL)
    for insertKey in ["a", "A", "i", "o", "O"] {
      XCTAssertEqual(
        c.mode.normal.first(where: { $0.key == insertKey })?.action.command,
        .insertMode)
    }
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == "I" })?.action.command,
      .lockedInsertMode)
    XCTAssertNil(c.mode.normal.first(where: { $0.key == "cmd+space" }))
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("g4") })?.action.command,
      .tabSelect(index: 4))
    XCTAssertNil(c.mode.normal.first(where: { $0.key == key("gN") }))
    // Vimium `n` cycles find matches — Flash drives the app's native
    // find-again (⌘G). New windows stay on ⌘N.
    guard
      case .sendKey(let nKeys, _, _) =
        c.mode.normal.first(where: { $0.key == "n" })?.action.command
    else { return XCTFail("expected send_key for n") }
    XCTAssertEqual(nKeys, "cmd+g")
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == "t" })?.action.command,
      .tabNew)
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == "ctrl-o" })?.action.command,
      .movementBack)
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == "ctrl-i" })?.action.command,
      .movementForward)
    // History: `H`/`L` with `[h`/`]h` as unimpaired-style aliases.
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("[h") })?.action.command,
      .historyBack)
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("]h") })?.action.command,
      .historyForward)
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == "H" })?.action.command,
      .historyBack)
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == "L" })?.action.command,
      .historyForward)
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("[t") })?.action.command,
      .tabPrev)
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("]t") })?.action.command,
      .tabNext)
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("[a") })?.action.command,
      .appPrev)
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("]a") })?.action.command,
      .appNext)
    for rawKey in [
      "[t", "]t", "[h", "]h", "[b", "]b", "[B", "]B", "[m", "]m", "[e", "]e", "[a",
      "]a", "[w", "]w", "[[", "]]",
    ] {
      XCTAssertEqual(
        c.mode.normal.first(where: { $0.key == key(rawKey) })?.repeatsOnFinalKey,
        true,
        "expected default bracket mapping \(rawKey) to repeat")
    }
    XCTAssertEqual(c.mode.labels.normal, "NORMAL")
    XCTAssertEqual(c.mode.labels.insert, "INSERT")
    XCTAssertEqual(c.mode.labels.command, "COMMAND")
    XCTAssertTrue(c.mode.all.isEmpty)
    XCTAssertTrue(c.mode.insert.isEmpty)
    XCTAssertTrue(c.open.ignoredApps.isEmpty)
    XCTAssertTrue(c.plugins.thirdParty.isEmpty)
    XCTAssertEqual(
      c.statusBar.template.template,
      "#[align=left]#{mode}#[align=right]#{date}")
    XCTAssertEqual(c.statusBar.template.variables.count, 2)
    XCTAssertTrue(c.flashlight.aliases.isEmpty)
    XCTAssertEqual(c.flashlight.suggestionCount, 10)
    XCTAssertTrue(c.flashlight.precedence.isEmpty)
    XCTAssertEqual(c.flashlight.precedenceAliveBonus, 10)
    XCTAssertFalse(c.debug.httpInspectorEnabled)
    XCTAssertEqual(c.debug.httpInspectorHost, "localhost")
    XCTAssertEqual(c.debug.httpInspectorPort, 4242)
  }

  func testDefaultNormalModeOmitsCmdChords() {
    // The ⌘-based system/browser chords are intentionally NOT bound in normal
    // mode — they belong to the OS / focused app. Only their vim-style siblings
    // and the ⌃Tab pair are bound.
    let c = ConfigLoader.parse("")
    func command(_ raw: String) -> URLCommand? {
      c.mode.normal.first(where: { $0.key == key(raw) })?.action.command
    }
    for chord in [
      "cmd+tab", "cmd+shift+tab", "cmd+1", "cmd+9", "cmd+r", "cmd+shift+r",
      "cmd+<lbracket>", "cmd+<rbracket>", "cmd+shift+<lbracket>",
      "cmd+shift+<rbracket>", "cmd+t", "cmd+shift+t", "cmd+w", "cmd+n", "cmd+f",
    ] {
      XCTAssertNil(command(chord), "expected no default ⌘ binding for \(chord)")
    }
    XCTAssertEqual(command("ctrl+tab"), .tabNext)
    XCTAssertEqual(command("ctrl+shift+tab"), .tabPrev)
  }

  func testParsesNormalPassthroughModifiers() {
    XCTAssertEqual(
      ConfigLoader.parse("").mode.normalPassthroughModifiers,
      ["cmd", "ctrl", "shift", "alt"])
    let c = ConfigLoader.parse(
      """
      [mode.normal]
      passthrough_modifiers = ["cmd", "shift"]
      """)
    XCTAssertEqual(c.mode.normalPassthroughModifiers, ["cmd", "shift"])

    let invalid = ConfigLoader.parse(
      """
      [mode.normal]
      passthrough_modifiers = ["cmd", "hyper"]
      """)
    XCTAssertEqual(invalid.mode.normalPassthroughModifiers, ["cmd", "hyper"])
    XCTAssertTrue(
      invalid.diagnostics.contains {
        $0.message.contains("passthrough_modifiers: unknown modifier \"hyper\"")
      })
  }

  func testParsesNormalPassthroughKeys() {
    XCTAssertEqual(ConfigLoader.parse("").mode.normalPassthroughKeys, ["escape"])
    let c = ConfigLoader.parse(
      """
      [mode.normal]
      passthrough_keys = ["escape", "tab"]
      """)
    XCTAssertEqual(c.mode.normalPassthroughKeys, ["escape", "tab"])
    XCTAssertEqual(c.mode.normalPassthroughKeyCodes, [UInt32(kVK_Escape), UInt32(kVK_Tab)])

    let disabled = ConfigLoader.parse(
      """
      [mode.normal]
      passthrough_keys = []
      """)
    XCTAssertTrue(disabled.mode.normalPassthroughKeys.isEmpty)
    XCTAssertTrue(disabled.mode.normalPassthroughKeyCodes.isEmpty)

    let invalid = ConfigLoader.parse(
      """
      [mode.normal]
      passthrough_keys = ["escape", "hyper"]
      """)
    XCTAssertEqual(invalid.mode.normalPassthroughKeys, ["escape", "hyper"])
    XCTAssertEqual(invalid.mode.normalPassthroughKeyCodes, [UInt32(kVK_Escape)])
    XCTAssertTrue(
      invalid.diagnostics.contains {
        $0.message.contains("passthrough_keys: unknown key \"hyper\"")
      })
  }

  func testParsesStatusBarTemplate() {
    let c = ConfigLoader.parse(
      """
      [statusbar]
      template = "#[align=left]#{active_bundle_identifier} #{mode}#[align=right]#{plugin:ready_count} | #{plugin:system.battery} | #{script:~/bin/right-status.sh} | #{command:date +%H:%M}"
      """)

    let template = c.statusBar.template
    XCTAssertEqual(
      template.template,
      "#[align=left]#{active_bundle_identifier} #{mode}#[align=right]"
        + "#{plugin:ready_count} | #{plugin:system.battery} | "
        + "#{script:~/bin/right-status.sh} | "
        + "#{command:date +%H:%M}")
    XCTAssertEqual(
      template.variables.map(\.token),
      [
        "active_bundle_identifier",
        "mode",
        "plugin:ready_count",
        "plugin:system.battery",
        "script:~/bin/right-status.sh",
        "command:date +%H:%M",
      ])
    XCTAssertTrue(c.loadingDiagnostics.isEmpty)

    XCTAssertEqual(template.variables[0].source, .sdk(.activeBundleIdentifier))
    XCTAssertEqual(template.variables[1].source, .sdk(.modeLabel))
    XCTAssertEqual(template.variables[2].source, .plugin(.readyCount))
    XCTAssertEqual(
      template.variables[3].source,
      .plugin(.statusSegment(pluginID: "system", name: "battery")))
    XCTAssertEqual(
      template.variables[4].source,
      .command(FlashStatusBarCommand(argv: ["/bin/sh", "~/bin/right-status.sh"])))
    XCTAssertEqual(
      template.variables[5].source,
      .command(FlashStatusBarCommand(argv: ["/bin/sh", "-lc", "date +%H:%M"])))
  }

  func testStatusBarEnabledIsTheSoleVisibilitySwitch() {
    // Off by default, and a template alone does NOT imply visibility —
    // `enabled` is the only condition for the bar to appear.
    XCTAssertFalse(ConfigLoader.parse("").statusBar.enabled)
    XCTAssertFalse(
      ConfigLoader.parse(
        """
        [statusbar]
        template = "#{mode}"
        """
      ).statusBar.enabled)

    let on = ConfigLoader.parse(
      """
      [statusbar]
      enabled = true
      """)
    XCTAssertTrue(on.statusBar.enabled)
    XCTAssertTrue(on.loadingDiagnostics.isEmpty)

    // Non-boolean values are rejected with a diagnostic and leave the
    // default (off) in place.
    let bad = ConfigLoader.parse(
      """
      [statusbar]
      enabled = "yes"
      """)
    XCTAssertFalse(bad.statusBar.enabled)
    XCTAssertFalse(bad.loadingDiagnostics.isEmpty)
  }

  func testParsesStatusBarTemplateAsTripleQuotedMultiline() {
    let c = ConfigLoader.parse(
      """
      [statusbar]
      template = \"\"\"
        #[align=left]#{mode}\\
        #[align=right]#{plugin:ready_count} | #{date}
        \"\"\"
      """)

    let t = c.statusBar.template
    // Status templates ignore newlines before rendering, so multi-line TOML
    // strings become one continuous template.
    XCTAssertEqual(
      t.template.trimmingCharacters(in: .whitespacesAndNewlines),
      "#[align=left]#{mode}#[align=right]#{plugin:ready_count} | #{date}")
    XCTAssertEqual(t.variables.map(\.token), ["mode", "plugin:ready_count", "date"])
    XCTAssertTrue(c.loadingDiagnostics.isEmpty)
  }

  func testStatusBarTemplateIgnoresNewlines() {
    let c = ConfigLoader.parse(
      """
      [statusbar]
      template = \"\"\"
      #[align=left]#{mode}
      #[align=center]#{active_app_name}
      #[align=right]#{date}
      \"\"\"
      """)

    XCTAssertEqual(
      c.statusBar.template.template,
      "#[align=left]#{mode}#[align=center]#{active_app_name}#[align=right]#{date}")
    XCTAssertEqual(
      c.statusBar.template.variables.map(\.token),
      ["mode", "active_app_name", "date"])
    XCTAssertTrue(c.loadingDiagnostics.isEmpty)
  }

  func testParsesTmuxStatusBarVariables() {
    let c = ConfigLoader.parse(
      """
      [statusbar]
      template = "#[align=left]#S@#H #{host_short} #{window_name}"
      """)

    XCTAssertEqual(
      c.statusBar.template.variables.map(\.token),
      ["session_name", "host", "host_short", "window_name"])
    XCTAssertEqual(c.statusBar.template.variables[0].source, .tmux("session_name"))
    XCTAssertEqual(c.statusBar.template.variables[1].source, .tmux("host"))
    XCTAssertEqual(c.statusBar.template.variables[2].source, .tmux("host_short"))
    XCTAssertEqual(c.statusBar.template.variables[3].source, .tmux("window_name"))
    XCTAssertTrue(c.loadingDiagnostics.isEmpty)
  }

  func testInvalidStatusBarTemplateReportsDiagnostics() {
    let c = ConfigLoader.parse(
      """
      [statusbar]
      template = "#{nope}#[align=right]#{plugin:nope}"
      """)

    XCTAssertTrue(
      c.loadingDiagnostics.contains {
        $0.message.contains("statusbar.template template variable")
      })
  }

  func testParsesModeLabelsInlineTable() {
    let c = ConfigLoader.parse(
      """
      [mode]
      labels = { normal = "N", insert = "I", command = "C" }
      """)

    XCTAssertEqual(c.mode.labels.normal, "N")
    XCTAssertEqual(c.mode.labels.insert, "I")
    XCTAssertEqual(c.mode.labels.command, "C")
    XCTAssertTrue(c.loadingDiagnostics.isEmpty)
  }

  func testInvalidModeLabelsReportDiagnostic() {
    let c = ConfigLoader.parse(
      """
      [mode]
      labels = { normal = "N", insert = "I" }
      """)

    XCTAssertEqual(c.mode.labels.normal, "NORMAL")
    XCTAssertTrue(
      c.loadingDiagnostics.contains {
        $0.message.contains("mode.labels must be")
      })
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

  func testParsesOpenIgnoredApps() {
    let c = ConfigLoader.parse(
      """
      [open]
      ignored_apps = ["Flash", "com.flash.app", "/Applications/Flash.app"]
      """)

    XCTAssertEqual(
      c.open.ignoredApps,
      ["Flash", "com.flash.app", "/Applications/Flash.app"])
  }

  func testParsesMultilineOpenIgnoredApps() {
    let c = ConfigLoader.parse(
      """
      [open]
      ignored_apps = [
        "com.flash.app",
        "com.flash.native-fixture",
        "com.flash.native-oracle",
        "com.flash.vimium-oracle",
      ]
      """)

    XCTAssertEqual(
      c.open.ignoredApps,
      [
        "com.flash.app",
        "com.flash.native-fixture",
        "com.flash.native-oracle",
        "com.flash.vimium-oracle",
      ])
    XCTAssertTrue(c.loadingDiagnostics.isEmpty)
  }

  func testParsesPluginReferences() throws {
    let source = URL(fileURLWithPath: "/Users/test/.config/flash/flash.toml")
    let sha = "1234567890abcdef1234567890abcdef12345678"
    let c = ConfigLoader.parse(
      """
      [plugins]
      disabled = ["defaults", "TMUX"]
      third_party = ["github:user/project@\(sha)", "file:../plugins/spotify"]
      """,
      sourceURL: source)

    XCTAssertEqual(c.plugins.disabled, Set(["defaults", "tmux"]))
    XCTAssertEqual(c.plugins.thirdParty.count, 2)
    XCTAssertEqual(c.plugins.thirdParty[0].raw, "github:user/project@\(sha)")
    if case .github(let owner, let repository, let commit) = c.plugins.thirdParty[0].kind {
      XCTAssertEqual(owner, "user")
      XCTAssertEqual(repository, "project")
      XCTAssertEqual(commit, sha)
    } else {
      XCTFail("expected github plugin reference")
    }
    if case .file(let path) = c.plugins.thirdParty[1].kind {
      XCTAssertEqual(path, "/Users/test/.config/plugins/spotify")
    } else {
      XCTFail("expected file plugin reference")
    }
    XCTAssertTrue(c.loadingDiagnostics.isEmpty)
  }

  func testGithubPluginRequiresCommitSHA() throws {
    // Branch / tag references are rejected: only a full 40-char commit SHA
    // pin protects against silent upstream-controlled updates.
    XCTAssertNil(PluginReference.parse("github:user/project"))
    XCTAssertNil(PluginReference.parse("github:user/project@main"))
    XCTAssertNil(PluginReference.parse("github:user/project@v1.2.3"))
    XCTAssertNil(PluginReference.parse("github:user/project@1234567"))  // short SHA
    XCTAssertNotNil(
      PluginReference.parse("github:user/project@1234567890abcdef1234567890abcdef12345678"))
    // Uppercase hex is normalized to lowercase so users can paste straight
    // from any tool without surprises.
    let upper = PluginReference.parse(
      "github:user/project@1234567890ABCDEF1234567890ABCDEF12345678")
    if case .github(_, _, let commit)? = upper?.kind {
      XCTAssertEqual(commit, "1234567890abcdef1234567890abcdef12345678")
    } else {
      XCTFail("expected normalized lowercase commit")
    }
  }

  func testParsesFlashlightAliasesAndPrecedence() {
    let c = ConfigLoader.parse(
      #"""
      [flashlight.aliases]
      "!g" = "!google"
      "@ft" = "@firefox.tabs"
      gh = "!github"

      [flashlight.precedence]
      Tmux = 200
      "firefox.tabs" = 120
      "notes.notes" = -10

      [flashlight]
      suggestion_count = 12
      precedence_alive_bonus = 25
      """#)

    XCTAssertEqual(c.flashlight.aliases["!g"], "!google")
    XCTAssertEqual(c.flashlight.aliases["@ft"], "@firefox.tabs")
    XCTAssertEqual(c.flashlight.aliases["gh"], "!github")
    XCTAssertEqual(c.flashlight.precedence["tmux"], 200)
    XCTAssertEqual(c.flashlight.precedence["firefox.tabs"], 120)
    XCTAssertEqual(c.flashlight.precedence["notes.notes"], -10)
    XCTAssertEqual(c.flashlight.suggestionCount, 12)
    XCTAssertEqual(c.flashlight.precedenceAliveBonus, 25)
    XCTAssertTrue(c.loadingDiagnostics.isEmpty)
  }

  func testInvalidFlashlightConfigReportsDiagnosticsAndKeepsDefaults() {
    let c = ConfigLoader.parse(
      #"""
      [flashlight.aliases]
      "!g" = ""
      "@ft" = 42

      [flashlight.precedence]
      firefox = "high"

      [flashlight]
      suggestion_count = 0
      precedence_alive_bonus = -1
      """#)

    XCTAssertTrue(c.flashlight.aliases.isEmpty)
    XCTAssertEqual(c.flashlight.suggestionCount, 10)
    XCTAssertNil(c.flashlight.precedence["firefox"])
    XCTAssertEqual(c.flashlight.precedenceAliveBonus, 10)
    XCTAssertTrue(
      c.loadingDiagnostics.contains {
        $0.message.contains("flashlight.aliases.!g must be a non-empty quoted string")
      })
    XCTAssertTrue(
      c.loadingDiagnostics.contains {
        $0.message.contains("flashlight.aliases.@ft must be a non-empty quoted string")
      })
    XCTAssertTrue(
      c.loadingDiagnostics.contains {
        $0.message.contains("flashlight.precedence.firefox must be an integer")
      })
    XCTAssertTrue(
      c.loadingDiagnostics.contains {
        $0.message.contains("flashlight.suggestion_count must be a positive integer")
      })
    XCTAssertTrue(
      c.loadingDiagnostics.contains {
        $0.message.contains("flashlight.precedence_alive_bonus must be a non-negative integer")
      })
  }

  func testParsesPluginSettingsTables() throws {
    let c = ConfigLoader.parse(
      """
      [plugin.slack]
      cli = "/opt/homebrew/bin/slack"
      retries = 3
      verbose = true

      [plugin.searchengines]
      engines = ["google", "ddg"]
      """)

    XCTAssertEqual(c.plugins.settings["slack"]?["cli"], .string("/opt/homebrew/bin/slack"))
    XCTAssertEqual(c.plugins.settings["slack"]?["retries"], .int(3))
    XCTAssertEqual(c.plugins.settings["slack"]?["verbose"], .bool(true))
    XCTAssertEqual(
      c.plugins.settings["searchengines"]?["engines"], .stringArray(["google", "ddg"]))

    let slackJSON = c.pluginConfigJSON(for: "slack")
    let data = try XCTUnwrap(slackJSON.data(using: .utf8))
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["cli"] as? String, "/opt/homebrew/bin/slack")
    XCTAssertEqual(object["retries"] as? Int, 3)
    XCTAssertEqual(object["verbose"] as? Bool, true)
    XCTAssertEqual(c.pluginConfigJSON(for: "absent"), "{}")
  }

  func testInvalidPluginReferenceReportsDiagnostic() {
    let c = ConfigLoader.parse(
      """
      [plugins]
      third_party = ["github:user", "https://example.com/plugin"]
      """)

    XCTAssertTrue(c.plugins.thirdParty.isEmpty)
    XCTAssertTrue(
      c.loadingDiagnostics.contains {
        $0.message.contains("plugins.third_party entries must be")
      })
  }

  func testParsesInspectorEnabledHostPort() {
    let cfg = ConfigLoader.parse(
      """
      [debug]
      http_inspector_enabled = true
      http_inspector_host = "127.0.0.1"
      http_inspector_port = 4343
      """)
    XCTAssertTrue(cfg.debug.httpInspectorEnabled)
    XCTAssertEqual(cfg.debug.httpInspectorHost, "127.0.0.1")
    XCTAssertEqual(cfg.debug.httpInspectorPort, 4343)
    XCTAssertTrue(cfg.loadingDiagnostics.isEmpty)
  }

  func testRejectsNonLoopbackInspectorHost() {
    let cfg = ConfigLoader.parse(
      """
      [debug]
      http_inspector_host = "example.com"
      """)
    XCTAssertEqual(cfg.debug.httpInspectorHost, "localhost")
    XCTAssertTrue(
      cfg.loadingDiagnostics.contains { $0.message.contains("http_inspector_host") })
  }

  func testRejectsOutOfRangeInspectorPort() {
    let cfg = ConfigLoader.parse(
      """
      [debug]
      http_inspector_port = 70000
      """)
    XCTAssertEqual(cfg.debug.httpInspectorPort, 4242)
    XCTAssertTrue(
      cfg.loadingDiagnostics.contains { $0.message.contains("http_inspector_port") })
  }

  func testParsesMultilineStringArrayComments() {
    let c = ConfigLoader.parse(
      """
      [hints]
      magic_modifiers = [
        "cmd",
        "alt", # keep option-click support
      ]
      """)

    XCTAssertEqual(c.hints.magicModifiers, ["cmd", "alt"])
    XCTAssertTrue(c.loadingDiagnostics.isEmpty)
  }

  func testInvalidOpenIgnoredAppsReportDiagnostic() {
    let c = ConfigLoader.parse(
      """
      [open]
      ignored_apps = "Flash"
      """)

    XCTAssertTrue(c.open.ignoredApps.isEmpty)
    XCTAssertTrue(
      c.loadingDiagnostics.contains {
        $0.message == "open.ignored_apps must be an array of strings"
      })
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
      [mode.all.mappings]
      "alt+shift+c" = ["sh", "~/.dotfiles/scripts/toggle-colors"]
      [debug]
      log_level = "debug"
      """)
    let json = c.resolvedConfigJSON
    XCTAssertFalse(json.contains("\n"))
    let root = try XCTUnwrap(Self.parseJSONObject(json))
    let hints = try XCTUnwrap(root["hints"] as? [String: Any])
    let overlay = try XCTUnwrap(root["overlay"] as? [String: Any])
    let debug = try XCTUnwrap(root["debug"] as? [String: Any])
    let flashlight = try XCTUnwrap(root["flashlight"] as? [String: Any])
    let mode = try XCTUnwrap(root["mode"] as? [String: Any])
    let open = try XCTUnwrap(root["open"] as? [String: Any])
    let plugins = try XCTUnwrap(root["plugins"] as? [String: Any])
    let statusBar = try XCTUnwrap(root["statusbar"] as? [String: Any])
    let allMappings = try XCTUnwrap(mode["all"] as? [[String: Any]])
    XCTAssertEqual(hints["keys"] as? String, "<qwerty_homerow+qwerty_toprow>")
    XCTAssertEqual(hints["min_length"] as? Int, 1)
    XCTAssertEqual(hints["magic_modifiers"] as? [String], ["shift"])
    XCTAssertEqual(overlay["font_size"] as? Double, 12)
    XCTAssertEqual(debug["log_level"] as? String, "debug")
    XCTAssertTrue(debug.keys.contains("http_inspector_enabled"))
    XCTAssertTrue(debug.keys.contains("http_inspector_host"))
    XCTAssertTrue(debug.keys.contains("http_inspector_port"))
    XCTAssertEqual(flashlight["suggestion_count"] as? Int, 10)
    XCTAssertEqual(flashlight["precedence_alive_bonus"] as? Int, 10)
    XCTAssertNotNil(mode["normal"] as? [[String: Any]])
    XCTAssertEqual(mode["normal_passthrough_keys"] as? [String], ["escape"])
    XCTAssertEqual(
      mode["normal_passthrough_modifiers"] as? [String],
      ["cmd", "ctrl", "shift", "alt"])
    XCTAssertEqual(
      allMappings.first?["action"] as? [String],
      ["sh", "~/.dotfiles/scripts/toggle-colors"])
    XCTAssertEqual(allMappings.first?["repeat"] as? Bool, false)
    XCTAssertEqual(open["ignored_apps"] as? [String], [])
    XCTAssertEqual(plugins["disabled"] as? [String], [])
    XCTAssertEqual(plugins["third_party"] as? [String], [])
    XCTAssertEqual(
      statusBar["template"] as? String, "#[align=left]#{mode}#[align=right]#{date}")
  }

  func testResolvedConfigJSONNeverIncludesPluginSettingValues() throws {
    let config = ConfigLoader.parse(
      """
      [plugin.calculator]
      target_currencies = ["USD"]
      api_token = "top-secret"
      """)

    XCTAssertFalse(config.resolvedConfigJSON.contains("top-secret"))
    let root = try XCTUnwrap(Self.parseJSONObject(config.resolvedConfigJSON))
    let plugins = try XCTUnwrap(root["plugins"] as? [String: Any])
    XCTAssertEqual(plugins["configured"] as? [String], ["calculator"])
    XCTAssertNil(plugins["settings"])
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
      "--open-ignored-apps=Flash,com.flash.app",
      "--overlay-font-size=20",
      "--overlay-hint-fg=#FFFFFF",
      "--overlay-hint-bg-top=#000000",
      "--overlay-hint-bg-bottom=#111111",
      "--overlay-hint-border=#222222",
      "--flashlight-suggestion-count=14",
      "--debug-show-bounds=true",
      "--debug-bounds-bg=#11223344",
      "--debug-bounds-fg=#55667788",
      "--debug-log-level=debug",
    ]
    let c = ConfigLoader.applyOverrides(to: base, arguments: args, environment: [:])
    XCTAssertEqual(c.hints.keys, "asdf")
    XCTAssertEqual(String(c.resolvedAlphabet.chars), "asdf")
    XCTAssertEqual(c.hints.minLength, 3)
    XCTAssertEqual(c.hints.magicModifiers, ["cmd", "alt"])
    XCTAssertEqual(c.open.ignoredApps, ["Flash", "com.flash.app"])
    XCTAssertEqual(c.overlay.fontSize, 20)
    XCTAssertEqual(c.overlay.hintFG, "#FFFFFF")
    XCTAssertEqual(c.overlay.hintBGTop, "#000000")
    XCTAssertEqual(c.overlay.hintBGBottom, "#111111")
    XCTAssertEqual(c.overlay.hintBorder, "#222222")
    XCTAssertEqual(c.flashlight.suggestionCount, 14)
    XCTAssertTrue(c.debug.showHintsBounds)
    XCTAssertEqual(c.debug.hintsBoundsBG, "#11223344")
    XCTAssertEqual(c.debug.hintsBoundsFG, "#55667788")
    XCTAssertEqual(c.debug.logLevel, .debug)
  }

  func testEnvOverridesEveryField() {
    let base = Config()
    let env = [
      "FLASH_HINTS_KEYS": "qwer",
      "FLASH_HINTS_MIN_LENGTH": "2",
      "FLASH_HINTS_MAGIC_MODIFIERS": "ctrl,alt",
      "FLASH_OPEN_IGNORED_APPS": "[\"Flash\", \"com.flash.app\"]",
      "FLASH_OVERLAY_FONT_SIZE": "18",
      "FLASH_OVERLAY_HINT_FG": "#DDEEFF",
      "FLASH_OVERLAY_HINT_BG_TOP": "#AABBCC",
      "FLASH_OVERLAY_HINT_BG_BOTTOM": "#998877",
      "FLASH_OVERLAY_HINT_BORDER": "#665544",
      "FLASH_FLASHLIGHT_SUGGESTION_COUNT": "13",
      "FLASH_DEBUG_SHOW_BOUNDS": "yes",
      "FLASH_DEBUG_BOUNDS_BG": "#11111111",
      "FLASH_DEBUG_BOUNDS_FG": "#22222222",
      "FLASH_DEBUG_LOG_LEVEL": "fatal",
    ]
    let c = ConfigLoader.applyOverrides(to: base, arguments: ["flash"], environment: env)
    XCTAssertEqual(c.hints.keys, "qwer")
    XCTAssertEqual(String(c.resolvedAlphabet.chars), "qwer")
    XCTAssertEqual(c.hints.minLength, 2)
    XCTAssertEqual(c.hints.magicModifiers, ["ctrl", "alt"])
    XCTAssertEqual(c.open.ignoredApps, ["Flash", "com.flash.app"])
    XCTAssertEqual(c.overlay.fontSize, 18)
    XCTAssertEqual(c.overlay.hintFG, "#DDEEFF")
    XCTAssertEqual(c.overlay.hintBGTop, "#AABBCC")
    XCTAssertEqual(c.overlay.hintBGBottom, "#998877")
    XCTAssertEqual(c.overlay.hintBorder, "#665544")
    XCTAssertEqual(c.flashlight.suggestionCount, 13)
    XCTAssertTrue(c.debug.showHintsBounds)
    XCTAssertEqual(c.debug.hintsBoundsBG, "#11111111")
    XCTAssertEqual(c.debug.hintsBoundsFG, "#22222222")
    XCTAssertEqual(c.debug.logLevel, .fatal)
  }

  func testInvalidMappingValueProducesWarning() {
    let toml = """
      [mode.all.mappings]
      "cmd+ctrl+b" = "https://example.com"
      """
    let c = ConfigLoader.parse(toml)
    XCTAssertEqual(c.warnings.count, 1)
    XCTAssertTrue(c.warnings[0].contains("cmd+ctrl+b"))
    XCTAssertTrue(c.warnings[0].contains("mapping"))
  }

  func testParsesModeCommandArrayMapping() {
    let toml = """
      [mode.all.mappings]
      "alt+shift+c" = ["sh", "~/.dotfiles/scripts/toggle-colors"]
      """
    let c = ConfigLoader.parse(toml)
    XCTAssertTrue(c.warnings.isEmpty)
    XCTAssertEqual(c.mode.all.count, 1)
    XCTAssertEqual(c.mode.all[0].key, "alt+shift+c")
    XCTAssertEqual(
      c.mode.all[0].action, .shellCommand(["sh", "~/.dotfiles/scripts/toggle-colors"]))
    XCTAssertFalse(c.mode.containsAdvancedModeMapping)
  }

  func testRelativeCommandArrayPathsResolveFromConfigLocation() {
    let sourceURL = URL(fileURLWithPath: "/tmp/dotfiles/.config/flash/flash.toml")
    let toml = """
      [mode.normal.mappings]
      "<leader>c" = ["../../scripts/toggle_caffeinate.sh"]
      [mode.normal]
      leader = "<space>"
      """
    let c = ConfigLoader.parse(toml, sourceURL: sourceURL)
    let mapping = c.mode.normal.first { $0.key == key("<space>c") }
    XCTAssertEqual(
      mapping?.action,
      .shellCommand(["/tmp/dotfiles/scripts/toggle_caffeinate.sh"]))
  }

  func testFlashExecutablePathMappingsResolveInProcess() {
    let sourceURL = URL(fileURLWithPath: "/tmp/flash/config/flash.toml")
    let toml = """
      [mode.normal.mappings]
      "]t" = ["../../bin/flash", "tab_next"]
      "r" = ["~/.local/bin/flash", "app_reload", "--force"]
      "o" = ["/Applications/Flash.app/Contents/MacOS/flash", "app_open", "--name=/Applications/Safari.app"]
      """
    let c = ConfigLoader.parse(toml, sourceURL: sourceURL)
    XCTAssertEqual(c.mode.normal.first(where: { $0.key == key("]t") })?.action.command, .tabNext)
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == "r" })?.action.command,
      .reload(force: true))
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == "o" })?.action.command,
      .openApp(name: "/Applications/Safari.app"))
  }

  func testRejectsEmptyModeCommandArrayMapping() {
    let toml = """
      [mode.all.mappings]
      "cmd+ctrl+b" = []
      """
    let c = ConfigLoader.parse(toml)
    XCTAssertEqual(c.warnings.count, 1)
    XCTAssertTrue(c.warnings[0].contains("cmd+ctrl+b"))
    XCTAssertTrue(c.warnings[0].contains("non-empty string array"))
  }

  func testRejectsStringMappingValueAndProducesArrayDiagnostic() {
    // Strings — quoted or bare — are NOT a valid mapping value. The array
    // form is the only accepted shape (`["flash", "<verb>", "k=v"...]` for
    // in-process verbs or `[<argv>...]` for external commands). The
    // diagnostic must teach the user the array form so a port from the
    // pre-removal `flash://` syntax surfaces a clear error.
    let stringForm = ConfigLoader.parse(
      """
      [mode.all.mappings]
      "cmd+ctrl+space" = "flash://emojis"
      """)
    XCTAssertEqual(stringForm.warnings.count, 1)
    XCTAssertTrue(stringForm.warnings[0].contains("cmd+ctrl+space"))
    XCTAssertTrue(stringForm.warnings[0].contains("non-empty string array"))
    XCTAssertTrue(stringForm.mode.all.isEmpty)

    let bareVerb = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "j" = "scroll_down"
      """)
    XCTAssertEqual(bareVerb.warnings.count, 1)
    XCTAssertTrue(bareVerb.warnings[0].contains("\"j\""))
    // The built-in default for `j` survives because the user's invalid
    // override never installs.
    assertSendKey(
      bareVerb.mode.normal.first(where: { $0.key == "j" })?.action.command,
      keys: "down",
      keyCode: CGKeyCode(kVK_DownArrow))
  }

  func testParsesModeMappings() {
    let toml = """
      [mode.insert.mappings]
      "ctrl+alt+n" = [\"flash\", \"enter_normal_mode\"]
      [mode.normal.mappings]
      "j" = [\"flash\", \"scroll_up\"]
      """
    let c = ConfigLoader.parse(toml)
    XCTAssertEqual(c.mode.insert.count, 1)
    XCTAssertEqual(c.mode.insert[0].action.command, .normalMode)
    XCTAssertEqual(c.mode.normal.first(where: { $0.key == "j" })?.action.command, .scroll(.up))
    XCTAssertTrue(c.mode.containsNormalModeMapping)
    XCTAssertFalse(c.mode.containsAdvancedModeMapping)
  }

  func testParsesRepeatableModeMappingInlineTable() {
    let c = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "[a" = { action = ["flash", "app_previous"], repeat = true }
      "zz" = { action = ["sh", "-c", "echo ok"] }
      """)

    let previous = c.mode.normal.first(where: { $0.key == key("[a") })
    XCTAssertEqual(previous?.action.command, .appPrev)
    XCTAssertEqual(previous?.repeatsOnFinalKey, true)
    let shell = c.mode.normal.first(where: { $0.key == key("zz") })
    XCTAssertEqual(shell?.action, .shellCommand(["sh", "-c", "echo ok"]))
    XCTAssertEqual(shell?.repeatsOnFinalKey, false)
    XCTAssertTrue(c.warnings.isEmpty)
  }

  func testRejectsInvalidRepeatableModeMappingMetadata() {
    let invalidRepeat = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "[a" = { action = ["flash", "app_previous"], repeat = "yes" }
      """)
    XCTAssertTrue(invalidRepeat.warnings.contains { $0.contains(".repeat must be true or false") })

    let unknownOption = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "[a" = { action = ["flash", "app_previous"], repeats = true }
      """)
    XCTAssertTrue(
      unknownOption.warnings.contains {
        $0.contains("unknown option 'repeats'") && $0.contains("action and repeat")
      })
  }

  func testAdvancedModeMappingIsDetectedOnlyFromAllScope() {
    let inAll = ConfigLoader.parse(
      """
      [mode.all.mappings]
      "cmd+ctrl+n" = [\"flash\", \"enter_normal_mode\"]
      """)
    XCTAssertTrue(inAll.mode.containsAdvancedModeMapping)

    let inInsert = ConfigLoader.parse(
      """
      [mode.insert.mappings]
      "cmd+ctrl+n" = [\"flash\", \"enter_normal_mode\"]
      """)
    XCTAssertFalse(inInsert.mode.containsAdvancedModeMapping)

    let inNormalOnly = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "cmd+ctrl+n" = [\"flash\", \"enter_normal_mode\"]
      """)
    XCTAssertFalse(inNormalOnly.mode.containsAdvancedModeMapping)
  }

  func testModeTableExtendsDefaultMappingsAndOverridesSameKey() {
    let toml = """
      [mode.normal.mappings]
      "j" = [\"flash\", \"scroll_up\"]
      """
    let c = ConfigLoader.parse(toml)
    XCTAssertEqual(c.mode.normal.first(where: { $0.key == "j" })?.action.command, .scroll(.up))
    XCTAssertEqual(c.mode.normal.first(where: { $0.key == "i" })?.action.command, .insertMode)
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == "I" })?.action.command,
      .lockedInsertMode)
    XCTAssertEqual(c.mode.normal.filter { $0.key == "j" }.count, 1)
  }

  func testNormalLeaderExpandsMappingsAfterParsingAllTables() {
    let toml = """
      [mode.normal.mappings]
      "<leader>c" = [\"flash\", \"app_reload\"]
      [mode.normal]
      leader = "<space>"
      """
    let c = ConfigLoader.parse(toml)
    XCTAssertEqual(c.mode.normalLeader, "<space>")
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("<space>c") })?.action.command,
      .reload(force: false))
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("<space><space>") })?.action.command,
      .enterCommand(input: "flashlight ", restoreMode: false))
    XCTAssertNil(
      c.mode.normal.first(where: {
        $0.key == key("\\<space>")
          && $0.action.command == .enterCommand(input: "flashlight ", restoreMode: false)
      }))
    XCTAssertNil(c.mode.normal.first(where: { $0.key == "<leader>c" }))
    XCTAssertTrue(c.warnings.isEmpty)
  }

  func testNormalLeaderAcceptsBackslashFullname() {
    let toml = #"""
      [mode.normal.mappings]
      "<leader><space>" = ["flash", "enter_command_mode", "--input=flashlight "]
      [mode.normal]
      leader = "<backslash>"
      """#
    let c = ConfigLoader.parse(toml)
    XCTAssertEqual(c.mode.normalLeader, "<backslash>")
    XCTAssertEqual(
      c.mode.normal.first(where: { $0.key == key("\\<space>") })?.action.command,
      .enterCommand(input: "flashlight ", restoreMode: false))
    XCTAssertTrue(c.warnings.isEmpty)
  }

  func testLeaderMappingsRequireNormalScope() {
    let toml = """
      [mode.all.mappings]
      "<leader>c" = [\"flash\", \"app_reload\"]
      """
    let c = ConfigLoader.parse(toml)
    XCTAssertTrue(c.warnings.contains { $0.contains("uses <leader>") })
    XCTAssertNil(c.mode.normal.first(where: { $0.key == "<leader>c" }))
  }

  func testOldModeMappingTablesAreRejected() {
    let toml = """
      [mode.normal]
      "j" = [\"flash\", \"scroll_up\"]
      """
    let c = ConfigLoader.parse(toml)
    XCTAssertTrue(c.warnings.contains { $0.contains("[mode.normal.mappings]") })
    assertSendKey(
      c.mode.normal.first(where: { $0.key == "j" })?.action.command,
      keys: "down",
      keyCode: CGKeyCode(kVK_DownArrow))
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
      XCTAssertTrue(c.debug.showHintsBounds, "expected `\(v)` to parse as true")
    }
    for v in ["false", "0", "no", "off", "FALSE"] {
      var b = base
      b.debug.showHintsBounds = true
      let c = ConfigLoader.applyOverrides(
        to: b, arguments: ["flash", "--debug-show-bounds=\(v)"], environment: [:])
      XCTAssertFalse(c.debug.showHintsBounds, "expected `\(v)` to parse as false")
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

  func testCandidatePathsDefaultToCanonicalConfigOnly() {
    // No XDG -> only the home-rooted canonical path.
    let args = ["flash"]
    let env: [String: String] = [:]
    let paths = ConfigLoader.candidatePaths(arguments: args, environment: env)
      .map { $0.path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    XCTAssertEqual(
      paths,
      [
        "\(home)/.config/flash/flash.toml"
      ])
  }

  func testLoadingErrorAlertIncludesResolvedAlphabetWarning() {
    let c = ConfigLoader.parse("[hints]\nkeys = \"<colemak_toprow|colemak_homerow>\"")
    let message = c.loadingErrorAlertMessage
    XCTAssertNotNil(message)
    XCTAssertEqual(message?.components(separatedBy: "\n").first, "[Flash]")
    XCTAssertTrue(message?.contains("\nConfig error\n") == true)
    XCTAssertTrue(message?.contains("line 2, col 8") == true)
    XCTAssertTrue(message?.contains("Unknown hints.keys preset") == true)
    XCTAssertTrue(message?.contains("colemak_toprow|colemak_homerow") == true)
  }

  func testLoadingErrorAlertIncludesMappingWarnings() {
    let c = ConfigLoader.parse(
      """
      [mode.all.mappings]
      "cmd+ctrl+b" = "mouse_target"
      """)
    let message = c.loadingErrorAlertMessage
    XCTAssertNotNil(message)
    XCTAssertEqual(message?.components(separatedBy: "\n").first, "[Flash]")
    XCTAssertTrue(message?.contains("line 2, col 16") == true)
    XCTAssertTrue(message?.contains("cmd+ctrl+b") == true)
  }

  func testLoadingErrorAlertIsNilForValidConfig() {
    let c = ConfigLoader.parse("[hints]\nkeys = \"<colemak_homerow+colemak_toprow>\"")
    XCTAssertNil(c.loadingErrorAlertMessage)
  }

  func testMalformedKnownConfigValueReportsLineAndColumn() {
    let c = ConfigLoader.parse("[hints]\nmin_length = \"big\"")
    XCTAssertEqual(c.warnings.count, 1)
    XCTAssertEqual(c.loadingDiagnostics.first?.location, ConfigLocation(line: 2, column: 14))
    XCTAssertTrue(
      c.loadingErrorAlertMessage?.contains("hints.min_length must be an integer") == true)
  }

  func testUnknownTopLevelSectionWarnsWithSuggestion() {
    let c = ConfigLoader.parse(
      """
      [hint]
      keys = "asdf"
      """)
    XCTAssertTrue(
      c.loadingDiagnostics.contains {
        $0.message.contains("unknown config key 'hint'")
          && $0.message.contains("did you mean 'hints'")
      },
      "expected an unknown-section diagnostic with a suggestion, got: "
        + "\(c.loadingDiagnostics.map(\.message))")
  }

  func testUnknownKeyWithinSectionWarnsWithSuggestionAndLocation() {
    let c = ConfigLoader.parse(
      """
      [hints]
      mouse_grid_step = 3
      """)
    let diag = c.loadingDiagnostics.first {
      $0.message.contains("unknown config key 'hints.mouse_grid_step'")
    }
    XCTAssertNotNil(diag, "got: \(c.loadingDiagnostics.map(\.message))")
    XCTAssertTrue(diag?.message.contains("did you mean 'mouse_grid_steps'") == true)
    XCTAssertEqual(diag?.location?.line, 2)
  }

  func testUserDefinedPluginSettingsAreNotFlaggedAsUnknown() {
    // [plugin.<id>] tables carry user-defined keys; they must not trip the
    // unknown-key check.
    let c = ConfigLoader.parse(
      """
      [plugin.spotify]
      client_id = "abc"
      anything_goes = true
      """)
    XCTAssertFalse(
      c.loadingDiagnostics.contains { $0.message.contains("unknown config key") },
      "plugin settings should not be flagged: \(c.loadingDiagnostics.map(\.message))")
  }

  func testDefaultConfigHasNoUnknownKeyDiagnostics() {
    // The shipped default config must parse with zero unknown-key warnings —
    // a guard against the schema map drifting away from config.default.toml.
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // FlashTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("config.default.toml")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      return XCTFail("could not read config.default.toml at \(url.path)")
    }
    let unknown = ConfigLoader.parse(text).loadingDiagnostics
      .filter { $0.message.contains("unknown config key") }
      .map(\.message)
    XCTAssertTrue(unknown.isEmpty, "default config produced unknown-key diagnostics: \(unknown)")
  }

  func testUnknownCLIFlagWarns() {
    let c = ConfigLoader.applyOverrides(
      to: ConfigLoader.parse(""),
      arguments: ["flash", "--hints-min-lenght=2"],
      environment: [:])
    XCTAssertTrue(
      c.loadingDiagnostics.contains {
        $0.message.contains("unknown command-line flag '--hints-min-lenght")
      },
      "expected an unknown-flag diagnostic, got: \(c.loadingDiagnostics.map(\.message))")
  }

  func testKnownCLIFlagsDoNotWarn() {
    let c = ConfigLoader.applyOverrides(
      to: ConfigLoader.parse(""),
      arguments: ["flash", "--hints-min-length=3", "--config=/tmp/x.toml"],
      environment: [:])
    XCTAssertEqual(c.hints.minLength, 3)
    XCTAssertFalse(
      c.loadingDiagnostics.contains { $0.message.contains("unknown command-line flag") },
      "known flags must not warn (--config is consumed elsewhere): "
        + "\(c.loadingDiagnostics.map(\.message))")
  }

  private func key(_ raw: String) -> String {
    NormalModeInterpreter.canonicalizeMappingKey(raw)!
  }

  private func assertSendKey(
    _ command: URLCommand?,
    keys: String,
    keyCode: CGKeyCode,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case .sendKey(let actualKeys, let actualKeyCode, let flagsRawValue) = command else {
      return XCTFail("expected send_key \(keys)", file: file, line: line)
    }
    XCTAssertEqual(actualKeys, keys, file: file, line: line)
    XCTAssertEqual(actualKeyCode, keyCode, file: file, line: line)
    XCTAssertEqual(flagsRawValue, 0, file: file, line: line)
  }

  private static func parseJSONObject(_ json: String) throws -> [String: Any]? {
    let data = Data(json.utf8)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  /// Guard against defaults drift: `config.default.toml` is the canonical
  /// user-facing reference and every value it sets is documented as the
  /// built-in default, so parsing it must reproduce `Config()`'s defaults.
  /// This is the exact class of bug that let `debug.http_inspector_enabled`
  /// diverge (code `true`, reference `false`). When you add a scalar field,
  /// set it to its default in config.default.toml and it stays covered here.
  func testConfigDefaultTOMLMatchesBuiltinDefaults() {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // FlashTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("config.default.toml")
    guard let toml = try? String(contentsOf: url, encoding: .utf8) else {
      return XCTFail("config.default.toml not found at \(url.path)")
    }
    let d = Config()
    let c = ConfigLoader.parse(toml)

    XCTAssertEqual(c.hints.keys, d.hints.keys)
    XCTAssertEqual(c.hints.minLength, d.hints.minLength)
    XCTAssertEqual(c.hints.magicModifiers, d.hints.magicModifiers)
    XCTAssertEqual(c.hints.mouseGridSteps, d.hints.mouseGridSteps)
    XCTAssertEqual(c.hints.mouseGridOpacity, d.hints.mouseGridOpacity)
    XCTAssertEqual(c.overlay.fontSize, d.overlay.fontSize)
    XCTAssertEqual(c.statusBar.enabled, d.statusBar.enabled)
    XCTAssertEqual(c.statusBar.template.template, d.statusBar.template.template)
    XCTAssertEqual(c.statusBar.monitor, d.statusBar.monitor)
    XCTAssertEqual(c.flashlight.suggestionCount, d.flashlight.suggestionCount)
    XCTAssertEqual(c.flashlight.precedenceAliveBonus, d.flashlight.precedenceAliveBonus)
    XCTAssertEqual(c.mode.labels, d.mode.labels)
    XCTAssertEqual(c.mode.sequenceTimeoutMs, d.mode.sequenceTimeoutMs)
    XCTAssertEqual(c.debug.showHintsBounds, d.debug.showHintsBounds)
    XCTAssertEqual(c.debug.logLevel, d.debug.logLevel)
    XCTAssertEqual(c.debug.httpInspectorEnabled, d.debug.httpInspectorEnabled)
    XCTAssertEqual(c.debug.httpInspectorHost, d.debug.httpInspectorHost)
    XCTAssertEqual(c.debug.httpInspectorPort, d.debug.httpInspectorPort)
  }
}
