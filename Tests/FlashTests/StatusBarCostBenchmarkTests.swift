import AppKit
import XCTest

@testable import flash

/// What one bar publish costs: evaluating a busy template (the shape of a
/// metrics bar with a clock, popups and links) and laying out and drawing
/// the result. Values change every iteration, as a 1 Hz metrics bar's do.
/// Opt-in, so the suite stays fast: `FLASH_BENCH=1 swift test --filter
/// StatusBarCostBenchmarkTests`; compare like for like (the same build
/// configuration, the same machine at rest).
final class StatusBarCostBenchmarkTests: XCTestCase {
  static let template = """
    #[align=left]#[pill]#{flash.mode}#[nopill] · #[popup=feed]#[link=https://example.com]#[label]aggr#[default]#[nolink] #{flash.plugin.feed.label}#[nopopup]

    #[align=centre]#[popup=active-app]#[shrink]#{flash.focused_app_name}#[noshrink]#[nopopup]

    #[align=right]#[popup=ai]#[link=https://example.com/a]#[label]Cld#[default] #{flash.plugin.aiproviders.claude}#[nolink] #[link=https://example.com/b]#[label]Cdx#[default] #{flash.plugin.aiproviders.codex}#[nolink]#[nopopup] · #[popup=btop]#[label]CPU#[default] #{p-3:flash.plugin.sysinfo.cpu_label} #[label]MEM#[default] #{p-3:flash.plugin.sysinfo.memory_label} #[label]NET#[default] #{p-4:flash.plugin.sysinfo.network_label} #[label]BAT#[default] #{flash.plugin.sysinfo.power_label}#[nopopup] · #[popup=date]%a %b %-d %H:%M#[nopopup]
    """

  private func values(_ i: Int) -> [String: String] {
    [
      "flash.plugin.feed.label": "Headline number \(i % 7) from the feed",
      "flash.plugin.aiproviders.claude": "\(40 + i % 9)%",
      "flash.plugin.aiproviders.codex": "\(10 + i % 5)%",
      "flash.plugin.sysinfo.cpu_label": "\(i % 100)%",
      "flash.plugin.sysinfo.memory_label": "\(50 + i % 30)%",
      "flash.plugin.sysinfo.network_label": "\(i % 900)K",
      "flash.plugin.sysinfo.power_label": "87%",
    ]
  }

  func testOnePublishCost() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["FLASH_BENCH"] == "1")
    let config = ConfigLoader.parse(
      "[statusbar]\nenabled = true\ntemplate = '''\n\(Self.template)\n'''\n")
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    let template = config.statusBar.template
    let context = FlashStatusBarContext(focusedAppName: "Firefox", modeLabel: "NORMAL")
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let surface = NativeStatusBarSurface()
    let iterations = 300
    var documents: [StatusFormatDocument] = []
    let evaluateStart = DispatchTime.now().uptimeNanoseconds
    for i in 0..<iterations {
      documents.append(
        FlashStatusBarTemplateEngine.evaluate(
          template: template, context: context, dynamicValues: values(i)
        ).model.document)
    }
    let evaluateNs = DispatchTime.now().uptimeNanoseconds - evaluateStart
    let renderStart = DispatchTime.now().uptimeNanoseconds
    for document in documents {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      surface.render(
        document: document,
        barFrame: CGRect(x: 0, y: 0, width: 1728, height: 32),
        screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        scale: 2, notch: CGRect(x: 771, y: 0, width: 185, height: 32), font: font,
        labels: .init(normal: "NORMAL", insert: "INSERT", command: "COMMAND"),
        palette: OverlayPanel.normalPalette, modeStyle: .normal, modeText: "NORMAL")
      _ = surface.interactionRects(panelFrame: .zero, popupTexts: [:], popupDocuments: [:])
      CATransaction.commit()
    }
    let renderNs = DispatchTime.now().uptimeNanoseconds - renderStart
    let evaluateMs = Double(evaluateNs) / Double(iterations) / 1e6
    let renderMs = Double(renderNs) / Double(iterations) / 1e6
    print(
      String(
        format: "[bench] statusbar evaluate=%.3fms render=%.3fms per publish", evaluateMs, renderMs)
    )
  }
}
