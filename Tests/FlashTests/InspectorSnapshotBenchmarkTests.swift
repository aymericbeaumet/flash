import AppKit
import XCTest

@testable import flash

/// Opt-in (`FLASH_BENCH=1`): what one inspector snapshot costs on main, and
/// its parts, over the bundled default configuration.
final class InspectorSnapshotBenchmarkTests: XCTestCase {
  private func ms(_ iterations: Int, _ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { body() }
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / Double(iterations)
  }

  func testOneSnapshotCost() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["FLASH_BENCH"] == "1")
    _ = NSApplication.shared
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(
      contentsOf: root.appendingPathComponent("config.default.toml"), encoding: .utf8)
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.overlay.statusPopupController = StatusPopupController(
      terminals: delegate.overlay.statusTerminals, windowActionsEnabled: false)
    defer { delegate.overlay.statusTerminals.shutdown() }
    delegate.config = ConfigLoader.parse(text)
    let config = delegate.config
    _ = delegate.debugStateJSON()
    let n = 20
    var lines: [String] = []
    lines.append(String(format: "snapshot %.2f ms", ms(n) { _ = delegate.debugStateJSON() }))
    lines.append(
      String(
        format: "config_json %.2f ms",
        ms(n) {
          _ = try? JSONSerialization.jsonObject(with: Data(config.resolvedConfigJSON.utf8))
        }))
    lines.append(
      String(format: "resolved_config_json_string %.2f ms", ms(n) { _ = config.resolvedConfigJSON })
    )
    lines.append(
      String(format: "config_sources %.2f ms", ms(n) { _ = config.resolvedConfigSources() }))
    lines.append(
      String(
        format: "core_commands %.2f ms", ms(n) { _ = NormalModeDispatcher.coreCommandCatalog() }))
    lines.append(
      String(
        format: "mappings_rows %.2f ms",
        ms(n) { _ = NormalModeDispatcher.mappingsJSON(mode: config.mode) }))
    lines.append(String(format: "keyboard %.2f ms", ms(n) { _ = delegate.keyboardStateJSON() }))
    lines.append(String(format: "monitors %.2f ms", ms(n) { _ = delegate.monitorsJSON() }))
    lines.append(String(format: "telemetry %.2f ms", ms(n) { _ = delegate.telemetryStateJSON() }))
    print("INSPECTOR_BENCH " + lines.joined(separator: " | "))
  }
}
