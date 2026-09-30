import AppKit
import XCTest

@testable import flash

/// TERMINAL is entered with `enter_terminal_mode` (or by focusing a popup)
/// and left with `leave_mode`, which closes the popup whatever its kind.
final class TerminalModeEntryTests: XCTestCase {
  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
  }

  private func waitUntil(_ description: String, _ condition: @escaping () -> Bool) {
    let ready = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
    ready.expectationDescription = description
    wait(for: [ready], timeout: 5)
  }

  /// A delegate wired as at launch for popup input: the popup's focus
  /// callbacks drive the mode, and `.hideTerminalPopup` dismisses the popup
  /// as the effect executor does. The other effects need a running app.
  private func delegate(terminals: [String: Config.Terminal] = [:]) -> AppDelegate {
    let delegate = AppDelegate()
    delegate.monitor = AppMonitor(
      registry: SourceRegistry(descriptors: [], runningApplications: []), config: .default)
    delegate.overlay = OverlayPanel()
    delegate.overlay.statusPopupController = StatusPopupController(
      terminals: delegate.overlay.statusTerminals, windowActionsEnabled: false)
    delegate.overlay.statusTerminals.apply(style: .init(), terminals: terminals)
    delegate.configureTerminalPopupInput()
    delegate.modeStore.dispatch(.startup(advancedEnabled: true))
    delegate.modeStore.perform = { [unowned delegate] effects, _, _ in
      if effects.contains(.hideTerminalPopup) {
        delegate.overlay.statusPopupController.dismiss()
      }
    }
    return delegate
  }

  private func cat(persistent: Bool) -> Config.Terminal {
    Config.Terminal(
      command: ["/bin/cat"], size: Config.PopupSize(columns: .cells(40), rows: .cells(10)),
      lifecycle: persistent ? .persistent : .fresh)
  }

  func testLeaveModeClosesAFocusedTextPopupAndRestoresTheBaseMode() throws {
    let delegate = delegate()
    let popup = delegate.overlay.statusPopupController
    let registry = delegate.overlay.statusTerminals
    defer {
      popup.dismiss()
      registry.shutdown()
    }
    let region = StatusBarPopupRegion(
      rect: CGRect(x: 100, y: 500, width: 100, height: 20), name: "details",
      content: "CPU 42 %",
      document: [FlashStatusTextSegment(text: "CPU 42 %", foreground: .defaultForeground)])
    popup.preview(
      region,
      visibleFrame: CGRect(x: 0, y: 0, width: 600, height: 400), style: .init(),
      font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    XCTAssertTrue(registry.isPager("details"))
    popup.focus()
    waitUntil("focused pager enters TERMINAL") { delegate.modeStore.mode.isTerminal }
    XCTAssertEqual(delegate.modeStore.mode, .terminal(restoreTo: .normal))
    XCTAssertEqual(popup.focusedName, "details")

    XCTAssertTrue(delegate.handleURLCommand(.leaveMode))
    XCTAssertEqual(delegate.modeStore.mode, .normal)
    XCTAssertFalse(popup.isVisible)
    XCTAssertEqual(delegate.overlay.statusBarHoverGate, .dismissed("details"))
    waitUntil("pager stopped") { registry.sessions["details"] == nil }
  }

  func testEnterTerminalModeFocusesAPopupIsIdempotentSwitchesAndLeaveModeClosesIt() throws {
    try XCTSkipIf(NSScreen.screens.isEmpty, "a standalone popup centres on a screen")
    let delegate = delegate(terminals: [
      "scratch": cat(persistent: false), "top": cat(persistent: true),
    ])
    let popup = delegate.overlay.statusPopupController
    let registry = delegate.overlay.statusTerminals
    defer {
      popup.dismiss()
      registry.shutdown()
    }

    XCTAssertTrue(delegate.handleURLCommand(.terminalMode(name: "scratch")))
    XCTAssertEqual(delegate.modeStore.mode, .terminal(restoreTo: .normal))
    XCTAssertEqual(popup.presentation, .standalone(name: "scratch"))
    let scratch = try XCTUnwrap(registry.session(named: "scratch"))
    let generation = registry.inputGenerations["scratch"]

    // The popup already in TERMINAL mode stays as it is: a fresh popup
    // would otherwise stop its process and start another.
    delegate.handleURLCommand(.terminalMode(name: "scratch"))
    XCTAssertEqual(delegate.modeStore.mode, .terminal(restoreTo: .normal))
    XCTAssertEqual(popup.presentation, .standalone(name: "scratch"))
    XCTAssertTrue(registry.session(named: "scratch") === scratch)
    XCTAssertEqual(registry.inputGenerations["scratch"], generation)

    // Another popup replaces it and keeps TERMINAL over the same base mode.
    delegate.handleURLCommand(.terminalMode(name: "top"))
    XCTAssertEqual(delegate.modeStore.mode, .terminal(restoreTo: .normal))
    XCTAssertEqual(popup.presentation, .standalone(name: "top"))
    XCTAssertEqual(popup.focusedName, "top")
    waitUntil("replaced fresh popup stopped") { registry.session(named: "scratch") !== scratch }
    let top = try XCTUnwrap(registry.session(named: "top"))

    delegate.handleURLCommand(.leaveMode)
    XCTAssertEqual(delegate.modeStore.mode, .normal)
    XCTAssertFalse(popup.isVisible)
    XCTAssertTrue(registry.session(named: "top") === top, "a persistent popup keeps running")
  }

  func testEnterTerminalModeWithoutANameOpensTheBuiltInTerminalPopup() throws {
    try XCTSkipIf(NSScreen.screens.isEmpty, "a standalone popup centres on a screen")
    XCTAssertEqual(Config.defaultPopupName, "terminal")
    let delegate = delegate(terminals: [Config.defaultPopupName: cat(persistent: false)])
    let popup = delegate.overlay.statusPopupController
    defer {
      popup.dismiss()
      delegate.overlay.statusTerminals.shutdown()
    }
    delegate.handleURLCommand(.terminalMode(name: nil))
    XCTAssertEqual(popup.presentation, .standalone(name: "terminal"))
    XCTAssertEqual(delegate.modeStore.mode, .terminal(restoreTo: .normal))
  }
}
