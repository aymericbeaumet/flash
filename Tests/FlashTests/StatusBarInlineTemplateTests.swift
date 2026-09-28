import XCTest

@testable import flash

/// The bar's format is written inline in `[statusbar] template`: no
/// `[statusbar.options]`. A multi-line template draws exactly what the
/// options it replaces drew through `#{E:@…}` and `#{T:@…}`.
final class StatusBarInlineTemplateTests: XCTestCase {
  /// A status bar as it was written with options, fragment by fragment.
  private static let optionsTemplate =
    "#[align=left]#{E:@left}#[align=absolute-centre]#{E:@centre}#[align=right]#{T:@right}"
  private static let options = [
    "@left": """
    #[pill]#{flash.mode}#[nopill]#[fg=colour245] · #[popup=feed]#[link=https://aggr.example]#{flash.plugin.feed.label}#[nolink]#[nopopup]

    """,
    "@centre": """
    #[popup=active-app]#{=/23/…:flash.active_app_name}#[nopopup]

    """,
    "@right": """
    #{?flash.plugin.caffeinate.state,#[fg=#EBCB8B]AWAKE#[default] ,}
    #[popup=claude]#[link=https://claude.ai/settings/usage]#{flash.plugin.aiproviders.claude_label}#[nolink]#[nopopup] #[popup=codex]#[link=https://chatgpt.com/codex/settings/usage]#{flash.plugin.aiproviders.codex_label}#[nolink]#[nopopup]
    #[fg=colour245] · #[popup=btop]#{flash.plugin.cpu.label} #{flash.plugin.memory.label} #{flash.plugin.disks.label} #{flash.plugin.network.label} #{flash.plugin.power.label}#[nopopup]
    #[fg=colour245] · #[popup=date]#{?flash.plugin.caffeinate.state,,%a %b %-d }#[default]%H:%M#[nopopup]

    """,
  ]

  /// The same bar written inline, one lane per line.
  private static let inlineConfig = #"""
    [statusbar]
    enabled = true
    template = """
    #[align=left]#[pill]#{flash.mode}#[nopill]#[fg=colour245] · #[popup=feed]#[link=https://aggr.example]#{flash.plugin.feed.label}#[nolink]#[nopopup]
    #[align=absolute-centre]#[popup=active-app]#{=/23/…:flash.active_app_name}#[nopopup]
    #[align=right]#{?flash.plugin.caffeinate.state,#[fg=#EBCB8B]AWAKE#[default] ,}
    #[popup=claude]#[link=https://claude.ai/settings/usage]#{flash.plugin.aiproviders.claude_label}#[nolink]#[nopopup] #[popup=codex]#[link=https://chatgpt.com/codex/settings/usage]#{flash.plugin.aiproviders.codex_label}#[nolink]#[nopopup]
    #[fg=colour245] · #[popup=btop]#{flash.plugin.cpu.label} #{flash.plugin.memory.label} #{flash.plugin.disks.label} #{flash.plugin.network.label} #{flash.plugin.power.label}#[nopopup]
    #[fg=colour245] · #[popup=date]#{?flash.plugin.caffeinate.state,,%a %b %-d }#[default]%H:%M#[nopopup]
    """
    """#

  private func context(app: String) -> FlashStatusBarContext {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
    return FlashStatusBarContext(
      activeAppName: app, modeLabel: "NORMAL", now: Date(timeIntervalSince1970: 1_790_600_000),
      calendar: calendar)
  }

  /// Spans name where a run was written (an option or the template); the
  /// drawing is everything else.
  private func drawn(_ runs: [FlashStatusTextSegment]) -> [FlashStatusTextSegment] {
    runs.map {
      var run = $0
      run.origin = nil
      return run
    }
  }

  func testTheInlineTemplateDrawsExactlyWhatItsOptionsDrew() throws {
    let config = ConfigLoader.parse(Self.inlineConfig)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    XCTAssertEqual(
      config.statusBar.shownPopupNames,
      ["feed", "active-app", "claude", "codex", "btop", "date"])
    let inline = config.statusBar.template
    let optionsTemplate = FlashStatusBarTemplate(template: Self.optionsTemplate)
    let apps = ["Firefox", "Microsoft Visual Studio Code Insiders", ""]
    let values: [[String: String]] = [
      [:],
      [
        "flash.plugin.feed.label": "#[fg=#88C0D0]HN#[default] A #[bold]rich#[nobold] headline",
        "flash.plugin.aiproviders.claude_label": "Cld 42% 3d",
        "flash.plugin.aiproviders.codex_label": "Cdx 7% 1d",
        "flash.plugin.cpu.label": "CPU  3%", "flash.plugin.memory.label": "MEM 61%",
        "flash.plugin.disks.label": "DSK 40%", "flash.plugin.network.label": "NET 1.2k",
        "flash.plugin.power.label": "BAT 80%", "flash.plugin.caffeinate.state": "1",
      ],
    ]
    for app in apps {
      for dynamic in values {
        let context = context(app: app)
        var native = FlashStatusBarTemplateEngine.formatContext(context, dynamicValues: dynamic)
        let new = FlashStatusBarTemplateEngine.evaluate(
          template: inline, context: context, nativeContext: native
        ).model
        native.options = Self.options
        let old = FlashStatusBarTemplateEngine.evaluate(
          template: optionsTemplate, context: context, nativeContext: native
        ).model
        XCTAssertEqual(drawn(new.modeDocument), drawn(old.modeDocument), app)
        XCTAssertEqual(drawn(new.appDocument), drawn(old.appDocument), app)
        XCTAssertEqual(drawn(new.rightDocument), drawn(old.rightDocument), app)
        XCTAssertEqual(drawn(new.document.runs), drawn(old.document.runs), app)
        XCTAssertFalse(new.document.runs.contains { $0.text.contains("\n") })
        XCTAssertTrue(new.rightText.contains("14:53"), "strftime expands in the template")
      }
    }
  }

  func testStrftimeExpandsDirectlyInTheBarTemplate() throws {
    let config = ConfigLoader.parse(
      """
      [statusbar]
      template = "#[align=right]%a %H:%M %%"
      """)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    let model = FlashStatusBarTemplateEngine.render(
      template: config.statusBar.template, context: context(app: "App"))
    XCTAssertEqual(model.rightDocument.map(\.text).joined(), "Mon 14:53 %")
  }

  /// A newline separates tokens inside a style marker, in the template as it
  /// did in an expanded option value.
  func testANewlineInsideAStyleMarkerSeparatesItsTokens() throws {
    let config = ConfigLoader.parse(
      #"""
      [statusbar]
      template = """
      #[align=left fg=red
      bold]x
      """
      """#)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    let model = FlashStatusBarTemplateEngine.render(
      template: config.statusBar.template, context: context(app: "App"))
    let run = try XCTUnwrap(model.modeDocument.first { $0.text == "x" })
    XCTAssertTrue(run.bold)
    XCTAssertEqual(run.foreground, .red)
  }

  func testOptionsTablesAreRejected() {
    let config = ConfigLoader.parse(
      """
      [statusbar]
      template = "#{E:@left}"
      [statusbar.options]
      "@left" = "#{flash.mode}"
      """)
    XCTAssertEqual(
      config.loadingDiagnostics.map(\.message),
      ["[statusbar.options] is not read; write its formats inline in [statusbar] template"])
    XCTAssertEqual(
      FlashStatusBarTemplateEngine.render(
        template: config.statusBar.template, context: context(app: "App")
      ).modeText, "", "no option is set")
  }
}
