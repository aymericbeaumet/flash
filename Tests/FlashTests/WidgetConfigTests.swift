import XCTest

@testable import flash

/// `[widgets.<name>]` tables and the source `history` they read.
final class WidgetConfigTests: XCTestCase {
  private func messages(_ config: Config) -> [String] {
    config.loadingDiagnostics.map(\.message)
  }

  func testEveryWidgetKeyParses() throws {
    let config = ConfigLoader.parse(
      #"""
      [widgets.clock]
      enabled = false
      template = """
      #[align=right]%H:%M\
       #{flash.widget.name}
      second line
      """
      screen = 2
      anchor = "bottom_centre"
      gap_x = 10
      gap_y = 12.5
      columns = 30
      max_columns = 60
      font = "Menlo"
      font_size = 18
      line_spacing = 2
      fg = "#A3BE8C"
      bg = "#00000080"
      border = "#4C566A"
      border_size = 1
      corner_radius = 12
      padding = 6
      interval = 1
      hide_from_capture = true
      [widgets.clock.options]
      "@x" = "local"
      """#)
    XCTAssertEqual(messages(config), [])
    let widget = try XCTUnwrap(config.widgets["clock"])
    XCTAssertFalse(widget.enabled)
    XCTAssertEqual(
      widget.template.template, "#[align=right]%H:%M#{flash.widget.name}\nsecond line\n",
      "a trailing backslash joins lines")
    XCTAssertEqual(widget.screen, .index(2))
    XCTAssertEqual(widget.anchor, .bottomCentre)
    XCTAssertEqual(widget.gapX, 10)
    XCTAssertEqual(widget.gapY, 12.5)
    XCTAssertEqual(widget.columns, 30)
    XCTAssertEqual(widget.maxColumns, 60)
    XCTAssertEqual(widget.font, "Menlo")
    XCTAssertEqual(widget.fontSize, 18)
    XCTAssertEqual(widget.lineSpacing, 2)
    XCTAssertEqual(widget.foreground, "#A3BE8C")
    XCTAssertEqual(widget.background, "#00000080")
    XCTAssertEqual(widget.border, "#4C566A")
    XCTAssertEqual(widget.borderSize, 1)
    XCTAssertEqual(widget.cornerRadius, 12)
    XCTAssertEqual(widget.padding, 6)
    XCTAssertEqual(widget.intervalSeconds, 1)
    XCTAssertTrue(widget.hideFromCapture)
    XCTAssertEqual(widget.template.options["@x"], "local")
    XCTAssertEqual(widget.spec.columns, 30)
    XCTAssertEqual(config.enabledWidgets.count, 0)
  }

  func testDefaultsFitTheContentAndFollowTheBarInterval() throws {
    let widget = try XCTUnwrap(
      ConfigLoader.parse(
        """
        [widgets.w]
        template = "x"
        """
      ).widgets["w"])
    XCTAssertTrue(widget.enabled)
    XCTAssertEqual(widget.screen, .primary)
    XCTAssertEqual(widget.anchor, .topLeft)
    XCTAssertEqual(widget.columns, 0)
    XCTAssertEqual(widget.spec.columns, 120, "an auto-sized widget reports max_columns")
    XCTAssertEqual(widget.spec.intervalSeconds, 0)
    XCTAssertEqual(widget.background, "#2E344000")
  }

  func testInvalidValuesAreLocatedAndKeepTheirDefaults() throws {
    let config = ConfigLoader.parse(
      """
      [widgets.w]
      template = "x"
      anchr = "top_left"
      anchor = "middle"
      screen = 0
      font_size = 2
      fg = "#12345678"
      bg = "red"
      columns = -1
      [widgets."bad name"]
      template = "y"
      [widgets.v]
      enabled = true
      """)
    let text = messages(config).joined(separator: "\n")
    XCTAssertTrue(
      text.contains("unknown config key 'widgets.w.anchr' — did you mean 'anchor'?"), text)
    for key in ["anchor", "screen", "font_size", "fg", "bg", "columns"] {
      XCTAssertTrue(text.contains("widgets.w.\(key) must"), "\(key): \(text)")
    }
    XCTAssertTrue(text.contains("widget name 'bad name'"), text)
    XCTAssertTrue(text.contains("widgets.v.template is required"), text)
    let widget = try XCTUnwrap(config.widgets["w"])
    XCTAssertEqual(widget.anchor, .topLeft)
    XCTAssertEqual(widget.screen, .primary)
    XCTAssertEqual(widget.fontSize, 13)
    XCTAssertNil(config.widgets["bad name"])
    XCTAssertEqual(
      ConfigLoader.parse("[widgets.w]\ntemplate = \"x\"\nscreen = \"all\"").widgets["w"]?.screen,
      .all)
  }

  func testAProportionalOrMissingFontWarnsAndKeepsTheAuthoredName() {
    for font in ["Helvetica", "No Such Font 42"] {
      let config = ConfigLoader.parse("[widgets.w]\ntemplate = \"x\"\nfont = \"\(font)\"")
      XCTAssertEqual(config.widgets["w"]?.font, font)
      XCTAssertTrue(
        messages(config).contains { $0.contains("is not an installed monospaced font") }, font)
      XCTAssertTrue(StatusWidgetFont.font(name: font, size: 13).isFixedPitch)
    }
  }

  func testWidgetTemplatesReadWidgetAndHistoryValues() {
    let config = ConfigLoader.parse(
      """
      [statusbar]
      template = "#{E:@rule}"
      [statusbar.options]
      "@rule" = "#{R:-,#{flash.widget.columns}}"
      [statusbar.sources.load]
      command = ["/bin/load"]
      history = 30
      [statusbar.sources.plain]
      command = ["/bin/plain"]
      [widgets.w]
      template = "#{flash.widget.name} #{flash.widget.columns} #{flash.history.load} #{E:@rule}"
      """)
    XCTAssertEqual(messages(config), [], "a shared option may mention widget values")
    XCTAssertEqual(config.statusBar.sources["load"]?.historyLength, 30)
    XCTAssertNil(config.statusBar.sources["plain"]?.historyLength)

    let wrong = messages(
      ConfigLoader.parse(
        """
        [statusbar]
        template = "#{flash.widget.name}"
        [statusbar.sources.plain]
        command = ["/bin/plain"]
        [widgets.w]
        template = "#{flash.widget.size} #{flash.history.plain} #{flash.history.none}"
        """)
    ).joined(separator: "\n")
    XCTAssertTrue(wrong.contains("statusbar.template has unknown Flash value flash.widget.name"))
    XCTAssertTrue(wrong.contains("widgets.w.template has unknown Flash value flash.widget.size"))
    XCTAssertTrue(wrong.contains("statusbar.sources.plain sets no history"), wrong)
    XCTAssertTrue(wrong.contains("references undefined source none"), wrong)
  }

  func testHistoryIsBoundedAndExcludesCycling() {
    for (value, extra) in [("1", ""), ("513", ""), ("5", "cycle_interval = 10")] {
      let config = ConfigLoader.parse(
        """
        [statusbar.sources.s]
        command = ["/bin/s"]
        history = \(value)
        \(extra)
        """)
      XCTAssertNil(config.statusBar.sources["s"], value)
      XCTAssertFalse(messages(config).isEmpty, value)
    }
  }

  func testClickThroughWidgetsWarnAboutInteractiveMarkers() {
    let config = ConfigLoader.parse(
      """
      [widgets.w]
      template = "#[link=https://example.com]a#[nolink] #[range=user|x]b #{@p}"
      [widgets.w.options]
      "@p" = "#[popup=cpu]c#[nopopup]"
      """)
    let warnings = messages(config).filter { $0.contains("click-through") }
    XCTAssertEqual(warnings.count, 1)
    XCTAssertTrue(warnings[0].contains("link=, popup=, range="), warnings[0])
  }

  func testLocalOptionsOverrideTheSharedOnes() {
    let config = ConfigLoader.parse(
      """
      [statusbar.options]
      "@a" = "shared"
      "@b" = "shared"
      [widgets.w]
      template = "#{@a} #{@b}"
      [widgets.w.options]
      "@a" = "local"
      """)
    let template = config.widgets["w"]!.template
    XCTAssertEqual(template.options["@a"], "local")
    XCTAssertEqual(template.options["@b"], "shared")
    var native = FlashStatusBarTemplateEngine.formatContext(.init())
    native.options = config.statusBar.options.merging(template.options) { _, local in local }
    let runs = FlashStatusBarTemplateEngine.evaluateDocument(template, native: native).runs
    XCTAssertEqual(runs.map(\.text).joined(), "local shared")
  }

  func testObservedSegmentsUnionTheBarAndEnabledWidgets() {
    let toml = """
      [statusbar]
      enabled = false
      template = "#{flash.plugin.cpu.summary}"
      [widgets.top]
      template = "#{flash.plugin.processes.top_cpu} #{E:@mem}"
      [widgets.top.options]
      "@mem" = "#{flash.plugin.processes.top_mem}"
      [widgets.off]
      enabled = false
      template = "#{flash.plugin.memory.details}"
      """
    let config = ConfigLoader.parse(toml)
    XCTAssertEqual(config.observedStatusSegments, ["processes": ["top_cpu", "top_mem"]])
    let both = ConfigLoader.parse(
      toml.replacingOccurrences(
        of: "enabled = false\ntemplate = \"#{flash.plugin.cpu",
        with: "enabled = true\ntemplate = \"#{flash.plugin.cpu"))
    XCTAssertEqual(
      both.observedStatusSegments, ["processes": ["top_cpu", "top_mem"], "cpu": ["summary"]])
  }

  /// The commented example in `config.default.toml` is the reference a user
  /// uncomments: it must parse cleanly as written.
  func testTheDefaultConfigWidgetExampleParsesUncommented() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("config.default.toml")
    let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    let start = try XCTUnwrap(lines.firstIndex(of: "[widgets]"))
    let example = lines[(start + 1)...].prefix { $0.hasPrefix("#") }.map { line in
      line.hasPrefix("# ") ? String(line.dropFirst(2)) : String(line.dropFirst())
    }
    XCTAssertGreaterThan(example.count, 20)
    let config = ConfigLoader.parse(example.joined(separator: "\n"))
    XCTAssertEqual(config.loadingDiagnostics.map(\.logMessage), [])
    let widget = try XCTUnwrap(config.widgets["system"])
    XCTAssertEqual(widget.anchor, .topRight)
    XCTAssertEqual(widget.template.options["@sep"], " · ")
    XCTAssertEqual(config.observedStatusSegments["processes"], ["top_cpu"])
    XCTAssertEqual(ConfigLoader.parse(try String(contentsOf: url, encoding: .utf8)).widgets, [:])
  }
}
