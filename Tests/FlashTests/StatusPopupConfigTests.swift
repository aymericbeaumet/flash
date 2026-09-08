import XCTest

@testable import flash

final class StatusPopupConfigTests: XCTestCase {
  func testPopupCommandTablesAreRejectedWithCanonicalTerminalGuidance() {
    let config = ConfigLoader.parse("[statusbar.popup.system]\ncommand = [\"btm\"]")
    XCTAssertTrue(
      config.diagnostics.contains { $0.message.contains("declare commands in [terminal.system]") })
    XCTAssertTrue(config.terminals.isEmpty)
    XCTAssertNil(config.statusBar.popups["system"])
  }

  func testTerminalNamesTakePrecedenceOverDocumentsAcrossLayers() {
    let document = ConfigLoader.Layer(text: "[statusbar.popup]\nsystem = \"A document\"")
    for definition in ["command = [\"btm\"]\npersistent = true", "command = []"] {
      let terminal = ConfigLoader.Layer(text: "[terminal.system]\n" + definition)
      for layers in [[document, terminal], [terminal, document]] {
        let config = ConfigLoader.parseLayers(layers)
        XCTAssertNil(config.statusBar.popups["system"])
        XCTAssertTrue(
          config.diagnostics.contains { $0.message.contains("already a terminal name") })
      }
    }
  }

  func testLaterGlobalDefaultsApplyToInheritedSources() {
    let config = ConfigLoader.parseLayers([
      .init(text: "[statusbar.sources.clock]\ncommand = [\"date\"]"),
      .init(text: "[statusbar]\ninterval = 30\ncommand_timeout = 12"),
    ])
    XCTAssertEqual(config.statusBar.sources["clock"]?.intervalSeconds, 30)
    XCTAssertEqual(config.statusBar.sources["clock"]?.timeoutSeconds, 12)
  }

  func testNamedPopupDocumentsRemainTemplateStrings() {
    let config = ConfigLoader.parse(
      """
      [statusbar.popup]
      article = "#[bold]Opening#[nobold]\\nFirst lines"
      """)
    XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
    XCTAssertEqual(
      config.statusBar.popups["article"]?.template, "#[bold]Opening#[nobold]\nFirst lines")
    XCTAssertTrue(config.terminals.isEmpty)
  }

  func testInvalidDocumentReplacementRetainsPreviousLayer() {
    let config = ConfigLoader.parseLayers([
      .init(text: "[statusbar.popup]\narticle = \"Opening\""),
      .init(text: "[statusbar.popup]\narticle = 42"),
    ])
    XCTAssertFalse(config.diagnostics.isEmpty)
    XCTAssertEqual(config.statusBar.popups["article"]?.template, "Opening")
    XCTAssertTrue(config.terminals.isEmpty)
  }

  func testNativeOptionsAndExplicitSourceCadence() {
    let config = ConfigLoader.parse(
      """
      [statusbar.options]
      "@left" = "#{flash.mode}"
      [statusbar.sources.news]
      command = ["./news", "--plain"]
      interval = 300
      cycle_interval = 60
      """, sourceURL: URL(fileURLWithPath: "/tmp/config/flash.toml"))
    XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
    XCTAssertEqual(config.statusBar.options["@left"], "#{flash.mode}")
    XCTAssertEqual(config.statusBar.sources["news"]?.command, ["/tmp/config/news", "--plain"])
    XCTAssertEqual(config.statusBar.sources["news"]?.intervalSeconds, 300)
    XCTAssertEqual(config.statusBar.sources["news"]?.cycleIntervalSeconds, 60)
  }
}
