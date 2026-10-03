import XCTest

@testable import flash

/// `[popup]` style keys, `[popup.<name>]` text popups, and the retired
/// popup keys.
final class StatusPopupConfigTests: XCTestCase {
  func testPopupStyleKeysShareTheTableWithNamedPopups() {
    let config = ConfigLoader.parse(
      """
      [popup]
      fg = "#ECEFF480"
      bg = "#242933F2"
      border = "#4C566A"
      border_size = 2
      corner_radius = 9
      padding = 10
      min_width = 300
      max_width = 420
      offset = 7

      [popup.date]
      text = "#{flash.calendar}"
      """)
    XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
    XCTAssertEqual(config.popupStyle.foreground, "#ECEFF480", "every colour takes an alpha")
    XCTAssertEqual(config.popupStyle.background, "#242933F2")
    XCTAssertEqual(config.popupStyle.borderColor, "#4C566A")
    XCTAssertEqual(config.popupStyle.borderWidth, 2)
    XCTAssertEqual(config.popupStyle.cornerRadius, 9)
    XCTAssertEqual(config.popupStyle.padding, 10)
    XCTAssertEqual(config.popupStyle.minWidth, 300)
    XCTAssertEqual(config.popupStyle.maxWidth, 420)
    XCTAssertEqual(config.popupStyle.offset, 7)
    XCTAssertEqual(config.textPopups["date"]?.template, "#{flash.calendar}")
  }

  func testInvalidAndUnknownStyleKeysAreDiagnosedAndKeepDefaults() {
    let config = ConfigLoader.parse(
      """
      [popup]
      fg = "colour178"
      bg = "242933"
      border_size = -1
      min_width = 2001
      max_width = 20
      paddin = 4
      date = "#{flash.calendar}"
      """)
    XCTAssertEqual(config.popupStyle, Config.PopupStyle())
    let messages = config.diagnostics.map(\.message)
    XCTAssertEqual(messages.count, 7, "\(messages)")
    XCTAssertTrue(
      messages.contains("popup.min_width must be a number between 80 and 2000 (points)"))
    XCTAssertTrue(messages.contains("unknown config key 'popup.paddin' — did you mean 'padding'?"))
    XCTAssertTrue(
      messages.contains {
        $0.hasPrefix("unknown config key 'popup.date'; a named popup is a table: [popup.date]")
      }, "\(messages)")
  }

  func testTranslucentForegroundIsMixedOverTheBackground() {
    var style = Config.PopupStyle()
    style.foreground = "#FFFFFF80"
    style.background = "#000000"
    let colors = StatusPopupColors(style)
    XCTAssertEqual(colors.foreground.alphaComponent, 1)
    XCTAssertEqual(colors.foreground.redComponent, 0.5, accuracy: 0.01)
  }

  func testTextPopupsAreStatusFormats() {
    let config = ConfigLoader.parse(
      """
      [popup.article]
      text = "#[bold]Opening#[nobold]\\nFirst lines"
      """)
    XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
    XCTAssertEqual(config.textPopups["article"]?.template, "#[bold]Opening#[nobold]\nFirst lines")
    XCTAssertEqual(Set(config.terminalPopups.keys), ["terminal"])
    XCTAssertFalse(config.terminalPopupNames.contains("article"))
  }

  func testTextPopupsTakeOnlyText() {
    for (body, expected) in [
      (
        "text = \"x\"\nsize = \"80x20\"",
        "popup.article: unknown key 'size' (size belongs to command popups; "
          + "a text popup takes only text)"
      ),
      ("text = 42", "popup.article.text must be a status format string"),
    ] {
      let config = ConfigLoader.parse("[popup.article]\n" + body)
      XCTAssertEqual(config.diagnostics.map(\.message), [expected], body)
      XCTAssertTrue(config.invalidPopupNames.contains("article"), body)
    }
  }

  func testInvalidTextReplacementRetainsPreviousLayer() {
    let config = ConfigLoader.parseLayers([
      .init(text: "[popup.article]\ntext = \"Opening\""),
      .init(text: "[popup.article]\ntext = 42"),
    ])
    XCTAssertFalse(config.diagnostics.isEmpty)
    XCTAssertEqual(config.textPopups["article"]?.template, "Opening")
    XCTAssertFalse(
      config.terminalPopupNames.contains("article"), "an invalid text popup keeps its text")
  }

  func testOneNamespaceALaterLayerChangesThePopupKind() {
    let text = ConfigLoader.Layer(text: "[popup.system]\ntext = \"A document\"")
    let terminal = ConfigLoader.Layer(text: "[popup.system]\ncommand = [\"btm\"]")
    let toTerminal = ConfigLoader.parseLayers([text, terminal])
    XCTAssertTrue(toTerminal.diagnostics.isEmpty, "\(toTerminal.diagnostics)")
    XCTAssertNil(toTerminal.textPopups["system"])
    XCTAssertEqual(toTerminal.terminalPopups["system"]?.command, ["btm"])
    let toText = ConfigLoader.parseLayers([terminal, text])
    XCTAssertNil(toText.terminalPopups["system"])
    XCTAssertEqual(toText.textPopups["system"]?.template, "A document")
  }

  func testRetiredPopupTablesAndKeysPointAtPopup() {
    let config = ConfigLoader.parse(
      """
      [statusbar]
      popup_fg = "#D8DEE9"
      popup_max_width = 480

      [statusbar.popup]
      date = "#{flash.calendar}"

      [terminal.feed]
      command = ["newsboat"]
      """)
    let messages = config.diagnostics.map(\.message)
    XCTAssertEqual(
      Set(messages),
      [
        "statusbar.popup_fg is not read; set fg in [popup]",
        "statusbar.popup_max_width is not read; set max_width in [popup]",
        "statusbar.popup.date is not read; declare it as [popup.date] with text = \"…\"",
        "[terminal.feed] is not read; declare it as [popup.feed] with command = [...] "
          + "(cwd, env, size = \"COLUMNSxROWS\" and persistent are its other keys)",
      ])
    XCTAssertTrue(config.diagnostics.allSatisfy { $0.location != nil }, "\(config.diagnostics)")
    XCTAssertEqual(Set(config.popups.keys), ["terminal"])
  }

  func testLaterGlobalDefaultsApplyToInheritedSources() {
    let config = ConfigLoader.parseLayers([
      .init(text: "[statusbar.sources.clock]\ncommand = [\"date\"]"),
      .init(text: "[statusbar]\ninterval = 30\ncommand_timeout = 12"),
    ])
    XCTAssertEqual(config.statusBar.sources["clock"]?.intervalSeconds, 30)
    XCTAssertEqual(config.statusBar.sources["clock"]?.timeoutSeconds, 12)
  }

  func testExplicitSourceCadence() {
    let config = ConfigLoader.parse(
      """
      [statusbar.sources.news]
      command = ["./news", "--plain"]
      interval = 300
      cycle_interval = 60
      """, sourceURL: URL(fileURLWithPath: "/tmp/config/flash.toml"))
    XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
    XCTAssertEqual(config.statusBar.sources["news"]?.command, ["/tmp/config/news", "--plain"])
    XCTAssertEqual(config.statusBar.sources["news"]?.intervalSeconds, 300)
    XCTAssertEqual(config.statusBar.sources["news"]?.cycleIntervalSeconds, 60)
  }

  func testPrewarmedPopupsAreTheFreshTerminalsAUserCanOpen() {
    let config = ConfigLoader.parse(
      """
      [statusbar]
      enabled = true
      template = "#[popup=feed]News#[nopopup] #[popup=date]%H:%M#[nopopup] #[range=user|chat]Chat#[norange]"
      [statusbar.click]
      chat = ["flash", "enter_terminal_mode", "--name=chat"]
      [popup.date]
      text = "#{flash.calendar}\\n#[popup=agenda]agenda#[nopopup]"
      [popup.feed]
      command = ["newsboat"]
      [popup.agenda]
      command = ["calcurse"]
      [popup.chat]
      command = ["weechat"]
      [popup.top]
      command = ["btop"]
      persistent = true
      [popup.bonsai]
      command = ["bonsai", "hq"]
      [popup.unused]
      command = ["true"]
      [mode.command.mappings]
      "cmd+b" = ["flash", "enter_terminal_mode", "--name=bonsai"]
      [mode.terminal.mappings]
      "alt+space" = ["flash", "enter_terminal_mode"]
      "alt+t" = ["flash", "enter_terminal_mode", "--name=top"]
      """)
    XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
    XCTAssertEqual(
      config.referencedPopupNames,
      ["feed", "date", "agenda", "chat", "bonsai", "terminal", "top"])
    XCTAssertEqual(config.prewarmedPopupNames, ["feed", "agenda", "chat", "bonsai", "terminal"])
    XCTAssertEqual(
      config.terminalPopupNames, ["feed", "agenda", "chat", "top", "bonsai", "unused", "terminal"])

    let hidden = ConfigLoader.parse(
      """
      [statusbar]
      enabled = false
      template = "#[popup=feed]News#[nopopup]"
      [popup.feed]
      command = ["newsboat"]
      """)
    XCTAssertTrue(hidden.prewarmedPopupNames.isEmpty, "a hidden bar opens nothing")
    XCTAssertTrue(Config().prewarmedPopupNames.isEmpty, "nothing maps the shell by default")
  }
}
