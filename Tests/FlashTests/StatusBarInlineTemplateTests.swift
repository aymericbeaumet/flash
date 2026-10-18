import XCTest

@testable import flash

/// The bar's format is written inline in `[statusbar] template`: no
/// `[statusbar.options]`. A multi-line template draws exactly what the
/// options it replaces drew through `#{E:@…}` and `#{T:@…}`.
final class StatusBarInlineTemplateTests: XCTestCase {
  /// A status bar as it was written with options, fragment by fragment.
  private static let optionsTemplate =
    "#[align=left]#{E:@left}#[align=notch]#{E:@centre}#[align=right]#{T:@right}"
  private static let options = [
    "@left": """
    #[pill]#{flash.mode}#[nopill]#[fg=colour245] · #[popup=feed]#[link=https://aggr.example]#[label]aggr#[default] #{flash.plugin.feed.label}#[nolink]#[nopopup]

    """,
    "@centre": """
    #[popup=active-app]#{=/23/…:flash.active_app_name}#[nopopup]

    """,
    "@right": """
    #{?flash.plugin.caffeinate.state,#[fg=#EBCB8B]AWAKE#[default] ,}
    #[popup=ai-usage]#[link=https://claude.ai/settings/usage]#[label]Cld#[default] #{flash.source.cld}#[nolink] #[link=https://chatgpt.com/codex/settings/usage]#[label]Cdx#[default] #{flash.source.cdx}#[nolink]#[nopopup]
    #[fg=colour245] · #[popup=btop]#[label]CPU#[default] #{p-3:flash.plugin.cpu.label} #[label]MEM#[default] #{p-3:flash.plugin.memory.label} #[label]DSK#[default] #{p-3:flash.plugin.disks.label} #[label]NET#[default] #{p-4:flash.plugin.network.label} #[label]BAT#[default] #{flash.plugin.power.label}#[nopopup]
    #[fg=colour245] · #[popup=date]#{?flash.plugin.caffeinate.state,,%a %b %-d }#[default]%H:%M#[nopopup]

    """,
  ]

  /// The same bar written inline, one lane per line.
  private static let inlineConfig = #"""
    [statusbar]
    enabled = true
    template = """
    #[align=left]#[pill]#{flash.mode}#[nopill]#[fg=colour245] · #[popup=feed]#[link=https://aggr.example]#[label]aggr#[default] #{flash.plugin.feed.label}#[nolink]#[nopopup]
    #[align=notch]#[popup=active-app]#{=/23/…:flash.active_app_name}#[nopopup]
    #[align=right]#{?flash.plugin.caffeinate.state,#[fg=#EBCB8B]AWAKE#[default] ,}
    #[popup=ai-usage]#[link=https://claude.ai/settings/usage]#[label]Cld#[default] #{flash.source.cld}#[nolink] #[link=https://chatgpt.com/codex/settings/usage]#[label]Cdx#[default] #{flash.source.cdx}#[nolink]#[nopopup]
    #[fg=colour245] · #[popup=btop]#[label]CPU#[default] #{p-3:flash.plugin.cpu.label} #[label]MEM#[default] #{p-3:flash.plugin.memory.label} #[label]DSK#[default] #{p-3:flash.plugin.disks.label} #[label]NET#[default] #{p-4:flash.plugin.network.label} #[label]BAT#[default] #{flash.plugin.power.label}#[nopopup]
    #[fg=colour245] · #[popup=date]#{?flash.plugin.caffeinate.state,,%a %b %-d }#[default]%H:%M#[nopopup]
    """

    [statusbar.sources.cld]
    command = ["echo", "42%↻3d"]
    interval = 60

    [statusbar.sources.cdx]
    command = ["echo", "7%↻1d"]
    interval = 60
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
      ["feed", "active-app", "ai-usage", "btop", "date"])
    let inline = config.statusBar.template
    let optionsTemplate = FlashStatusBarTemplate(template: Self.optionsTemplate)
    let apps = ["Firefox", "Microsoft Visual Studio Code Insiders", ""]
    let values: [[String: String]] = [
      [:],
      [
        "flash.plugin.feed.label": "A #[bold]rich#[nobold] headline",
        "flash.source.cld": "42%↻3d",
        "flash.source.cdx": "7%↻1d",
        "flash.plugin.cpu.label": "3%", "flash.plugin.memory.label": "61%",
        "flash.plugin.disks.label": "40%", "flash.plugin.network.label": "1.2k",
        "flash.plugin.power.label": "80%", "flash.plugin.caffeinate.state": "1",
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
        if dynamic["flash.plugin.cpu.label"] == "3%" {
          let right = new.rightDocument.map(\.text).joined()
          XCTAssertTrue(right.contains("CPU  3%"), right)
          XCTAssertTrue(right.contains("MEM 61%"), right)
          XCTAssertTrue(right.contains("NET 1.2k"), right)
          let left = new.modeDocument.map(\.text).joined()
          XCTAssertTrue(left.contains("aggr"), left)
        }
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

}
