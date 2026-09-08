import XCTest

@testable import flash

final class StatusPopupConfigTests: XCTestCase {
  func testLaterGlobalDefaultsApplyToInheritedSources() {
    let config = ConfigLoader.parseLayers([
      .init(text: "[statusbar.sources.clock]\ncommand = [\"date\"]"),
      .init(text: "[statusbar]\ninterval = 30\ncommand_timeout = 12"),
    ])
    XCTAssertEqual(config.statusBar.sources["clock"]?.intervalSeconds, 30)
    XCTAssertEqual(config.statusBar.sources["clock"]?.timeoutSeconds, 12)
  }

  func testTerminalDeclarationsAreIndependentOfStatusBarVisibility() {
    let config = ConfigLoader.parse(
      """
      [statusbar]
      enabled = false
      [statusbar.popup.system]
      command = ["ytop"]
      """)
    XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
    XCTAssertEqual(config.statusBar.terminalPopups["system"]?.command, ["ytop"])
    XCTAssertEqual(config.statusBar.terminalPopups["system"]?.columns, 80)
    XCTAssertEqual(config.statusBar.terminalPopups["system"]?.rows, 24)
    XCTAssertNil(config.statusBar.popups["system"])
  }

  func testTerminalPathsFollowTheirDefiningLayer() {
    let config = ConfigLoader.parseLayers([
      .init(
        text: """
          [statusbar.popup.system]
          command = ["./monitor", "--label", "CPU"]
          working_directory = "./work"
          columns = 100
          rows = 30
          env = { LANG = "en_US.UTF-8" }
          """, sourceURL: URL(fileURLWithPath: "/tmp/base/flash.toml")),
      .init(
        text: "[statusbar]\nenabled = true",
        sourceURL: URL(fileURLWithPath: "/tmp/user/flash.toml")),
    ])
    let popup = config.statusBar.terminalPopups["system"]
    XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
    XCTAssertEqual(popup?.command, ["/tmp/base/monitor", "--label", "CPU"])
    XCTAssertEqual(popup?.workingDirectory, "/tmp/base/work")
    XCTAssertEqual(popup?.environment, ["LANG": "en_US.UTF-8"])
    XCTAssertEqual(popup?.columns, 100)
    XCTAssertEqual(popup?.rows, 30)
  }

  func testInvalidTerminalReplacementIsMarkedForLastGoodRetention() {
    for body in [
      "command = []", "command = [\"ytop\"]\nrows = 0",
      "command = [\"ytop\"]\nenv = { PATH = 1 }",
      "command = [\"ytop\"]\nunknown = true",
    ] {
      let config = ConfigLoader.parse("[statusbar.popup.system]\n" + body)
      XCTAssertFalse(config.diagnostics.isEmpty, body)
      XCTAssertNil(config.statusBar.terminalPopups["system"], body)
      XCTAssertTrue(config.statusBar.invalidTerminalPopupNames.contains("system"), body)
    }
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
