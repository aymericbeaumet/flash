import AppKit
import FlashCore
import XCTest

@testable import FlashTerminal
@testable import flash

/// Showing-latency instrumentation for popups: hover or standalone show to
/// the first frame the view draws, how stale that frame is, the main-thread
/// cost of showing and hiding, and the rows a re-show repaints. Every test
/// prints `[popup-bench]` lines and asserts only that the work happened, so it
/// stays green on loaded machines.
final class PopupLatencyBenchmarkTests: XCTestCase {
  private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
  private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)

  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  private static func report(_ name: String, _ value: Double, _ unit: String) {
    print("[popup-bench] \(name): \(String(format: "%.3f", value)) \(unit)")
  }

  private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
  private static func milliseconds(since start: UInt64) -> Double {
    Double(now() - start) / 1e6
  }
  private static func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
  }

  /// Spins the main run loop until `condition` holds; the elapsed time in ms.
  @discardableResult
  private func spin(timeout: TimeInterval = 5, until condition: () -> Bool) -> Double? {
    let start = Self.now()
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else { return nil }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.0005))
    }
    return Self.milliseconds(since: start)
  }

  private func pause(_ seconds: TimeInterval) { spin(timeout: seconds) { false } }

  private func registry() -> StatusTerminalRegistry {
    StatusTerminalRegistry(
      environment: FlashProcessEnvironment(seed: [
        "SHELL": "/bin/sh", "HOME": NSTemporaryDirectory(),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
      ]))
  }

  private func region(_ name: String, text: String) -> StatusBarPopupRegion {
    StatusBarPopupRegion(
      rect: CGRect(x: 700, y: 980, width: 100, height: 20), name: name, content: text,
      document: [FlashStatusTextSegment(text: text, foreground: .defaultForeground)])
  }

  private func preview(_ controller: StatusPopupController, _ region: StatusBarPopupRegion) {
    controller.preview(
      region, visibleFrame: screen, style: .init(), font: font)
  }

  private func running(_ session: TerminalSession?) -> Bool {
    if case .running = session?.state { return true }
    return false
  }

  /// A calendar-sized text popup: hover to the first frame showing the
  /// document, over repeated showings. Each showing starts its own pager.
  func testTextPopupHoverToFirstFrame() throws {
    let registry = registry()
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    let lines = (1...9).map { "row \($0) " + String(repeating: "·", count: 30) + " \($0)" }
    let popup = region("date", text: lines.joined(separator: "\n"))
    var previewCost: [Double] = []
    var toFirst: [Double] = []
    var toComplete: [Double] = []
    var dismissCost: [Double] = []
    var blankAtShow = 0
    var partialFirst = 0
    let showings = 12
    for _ in 0..<showings {
      let start = Self.now()
      preview(controller, popup)
      previewCost.append(Self.milliseconds(since: start))
      if controller.terminalView.terminalFrame?.text.contains("row") != true,
        !controller.isAwaitingFirstFrame
      {
        blankAtShow += 1
      }
      _ = try XCTUnwrap(
        spin { controller.terminalView.terminalFrame?.text.contains("row") == true })
      toFirst.append(Self.milliseconds(since: start))
      if controller.terminalView.terminalFrame?.text.contains("row 9 ") != true {
        partialFirst += 1
      }
      _ = try XCTUnwrap(
        spin { controller.terminalView.terminalFrame?.text.contains("row 9 ") == true })
      toComplete.append(Self.milliseconds(since: start))
      let hide = Self.now()
      controller.dismiss()
      dismissCost.append(Self.milliseconds(since: hide))
      pause(0.3)
    }
    Self.report("text_hover_preview_main", Self.median(previewCost), "ms")
    Self.report("text_hover_to_first_frame", Self.median(toFirst), "ms")
    Self.report("text_hover_to_complete_frame", Self.median(toComplete), "ms")
    Self.report("text_hover_blank_panel_shown", Double(blankAtShow), "of \(showings)")
    Self.report("text_hover_partial_first_frame", Double(partialFirst), "of \(showings)")
    Self.report("text_dismiss_main", Self.median(dismissCost), "ms")
  }

  /// A persistent popup whose program redraws a counter at 20 Hz, like btop's
  /// graphs: its first show, then re-shows after it ran hidden for a while.
  func testPersistentPopupFirstShowAndReshowFreshness() throws {
    let registry = registry()
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    let script =
      "i=0; while :; do i=$((i+1)); printf '\\033[H\\033[2Jtick %08d\\n' $i;"
      + " n=0; while [ $n -lt 20 ]; do printf 'row %02d\\n' $n; n=$((n+1)); done;"
      + " sleep 0.05; done"
    registry.apply(
      style: .init(),
      terminals: [
        "top": Config.Terminal(
          command: ["/bin/sh", "-c", script],
          size: Config.PopupSize(columns: .cells(120), rows: .cells(40)), lifecycle: .persistent)
      ])
    let session = try XCTUnwrap(registry.session(named: "top"))
    _ = try XCTUnwrap(spin { self.running(session) })
    pause(0.3)
    func tick(_ frame: TerminalFrame?) -> Int? {
      guard let text = frame?.text, let range = text.range(of: "tick ") else { return nil }
      return Int(text[range.upperBound...].prefix(8))
    }
    // First show: nothing was ever drawn for this session.
    var start = Self.now()
    preview(controller, region("top", text: "CPU"))
    let firstPreview = Self.milliseconds(since: start)
    let blankFirst =
      controller.terminalView.terminalFrame == nil && !controller.isAwaitingFirstFrame
    let heightAtShow = controller.frame.height
    _ = try XCTUnwrap(spin { tick(controller.terminalView.terminalFrame) != nil })
    let firstFrame = Self.milliseconds(since: start)
    // The next layout (a bar refresh) sizes the popup from its first frame.
    preview(controller, region("top", text: "CPU"))
    Self.report("persistent_first_show_preview_main", firstPreview, "ms")
    Self.report("persistent_first_show_blank_panel_shown", blankFirst ? 1 : 0, "bool")
    Self.report("persistent_first_show_to_frame", firstFrame, "ms")
    Self.report(
      "persistent_first_show_height_change", Double(heightAtShow - controller.frame.height), "pt")
    var previewCost: [Double] = []
    var dismissCost: [Double] = []
    var behind: [Double] = []
    var toCurrent: [Double] = []
    var repainted: [Double] = []
    let showings = 8
    for _ in 0..<showings {
      let hide = Self.now()
      controller.dismiss()
      dismissCost.append(Self.milliseconds(since: hide))
      pause(0.5)
      start = Self.now()
      preview(controller, region("top", text: "CPU"))
      previewCost.append(Self.milliseconds(since: start))
      // The frame the showing starts with, then the next one the view gets:
      // ticks are 50 ms apart, so a jump of many ticks at once means the
      // first frame was that far behind the program.
      let shown = tick(controller.terminalView.terminalFrame) ?? 0
      repainted.append(Double(controller.terminalView.rowsNeedingDisplay.count))
      _ = try XCTUnwrap(spin { (tick(controller.terminalView.terminalFrame) ?? 0) != shown })
      toCurrent.append(Self.milliseconds(since: start))
      behind.append(Double((tick(controller.terminalView.terminalFrame) ?? 0) - shown - 1) * 50)
    }
    Self.report("persistent_reshow_preview_main", Self.median(previewCost), "ms")
    Self.report("persistent_reshow_first_frame_behind", max(0, Self.median(behind)), "ms")
    Self.report("persistent_reshow_to_next_frame", Self.median(toCurrent), "ms")
    Self.report("persistent_reshow_rows_repainted", Self.median(repainted), "of 40 rows")
    Self.report("persistent_dismiss_main", Self.median(dismissCost), "ms")
    controller.dismiss()
  }

  /// `enter_terminal_mode` on a persistent popup: main-thread cost of the
  /// show and time until its first frame.
  func testStandaloneShowLatency() throws {
    let registry = registry()
    defer { registry.shutdown() }
    let controller = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    registry.apply(
      style: .init(),
      terminals: [
        "shell": Config.Terminal(
          command: ["/bin/sh", "-c", "printf 'ready\\n'; exec /bin/cat"],
          size: Config.PopupSize(columns: .percent(90), rows: .percent(85)),
          lifecycle: .persistent)
      ])
    let session = try XCTUnwrap(registry.session(named: "shell"))
    _ = try XCTUnwrap(spin { self.running(session) })
    pause(0.2)
    var showCost: [Double] = []
    var toFrame: [Double] = []
    for _ in 0..<8 {
      let start = Self.now()
      controller.show(name: "shell", visibleFrame: screen, style: .init(), font: font)
      showCost.append(Self.milliseconds(since: start))
      _ = try XCTUnwrap(
        spin { controller.terminalView.terminalFrame?.text.contains("ready") == true })
      toFrame.append(Self.milliseconds(since: start))
      controller.dismiss()
      pause(0.1)
    }
    Self.report("standalone_show_main", Self.median(showCost), "ms")
    Self.report("standalone_show_to_frame", Self.median(toFrame), "ms")
  }
}
