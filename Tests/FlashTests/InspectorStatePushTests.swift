import AppKit
import FlashCore
import XCTest

@testable import flash

/// Every change the inspector's state reflects pushes it, and each one is a
/// single coalesced snapshot — the inspector has no clock of its own.
final class InspectorStatePushTests: XCTestCase {
  private var snapshots = 0
  private var delegate: AppDelegate!
  private var server: DebugServer!

  override func setUp() {
    super.setUp()
    _ = NSApplication.shared
    snapshots = 0
    let delegate = AppDelegate()
    delegate.config = ConfigLoader.parse(
      """
      [debug]
      http_inspector_enabled = true
      """)
    delegate.registry = SourceRegistry(descriptors: [], runningApplications: [])
    delegate.monitor = AppMonitor(registry: delegate.registry, config: delegate.config)
    delegate.overlay = OverlayPanel()
    delegate.overlay.statusPopupController = StatusPopupController(
      terminals: delegate.overlay.statusTerminals, windowActionsEnabled: false)
    delegate.widgetController = WidgetController(
      setVisible: { _, _ in }, screenLayouts: { _, _ in [] })
    delegate.wireInspectorChangeSources()
    // Not listening: the pushes are counted where the snapshot is taken.
    let server = DebugServer(
      host: delegate.config.debug.httpInspectorHost,
      port: delegate.config.debug.httpInspectorPort, accessToken: HelpAccess.newToken(),
      coalescingWindowMs: 20
    ) { [unowned self] in
      self.snapshots += 1
      return [:]
    }
    delegate.attachDebugServer(server)
    // A browser holds the event stream.
    server.streamsDidChange(by: 1)
    self.delegate = delegate
    self.server = server
  }

  override func tearDown() {
    delegate.stopDebugServer()
    delegate.overlay.statusTerminals.shutdown()
    delegate = nil
    server = nil
    super.tearDown()
  }

  private func hint(_ label: String) -> AssignedHint {
    AssignedHint(
      target: JumpTarget(
        id: label, frame: CGRect(x: 10, y: 10, width: 40, height: 20), role: "AXButton",
        pid: 42, providerID: "test"),
      label: label)
  }

  private func spin(for seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      spin(for: 0.02)
    }
    return condition()
  }

  private func waitForSnapshot(after count: Int, timeout: TimeInterval = 2) -> Bool {
    waitUntil(timeout: timeout) { snapshots > count }
  }

  /// `change` pushes exactly one snapshot once its window has passed.
  private func assertOnePush(
    _ source: String, file: StaticString = #filePath, line: UInt = #line,
    _ change: () -> Void
  ) {
    spin(for: 0.1)
    let before = snapshots
    change()
    XCTAssertTrue(
      waitForSnapshot(after: before), "\(source) did not publish", file: file, line: line)
    spin(for: 0.05)
    XCTAssertEqual(snapshots - before, 1, source, file: file, line: line)
  }

  func testModeOverlayAndRoutingChangesPushOnce() {
    assertOnePush("mode") { delegate.applyModeOverlay() }
    assertOnePush("overlay routing") {
      delegate.modeStore.dispatch(.startup(advancedEnabled: true))
      delegate.refreshOverlayInputRouting()
    }
  }

  func testFocusAndMappingChangesPushOnce() {
    assertOnePush("focus and the mappings it applies") {
      delegate.applyFocusedApplicationChange(.current, emitFocusEvent: false)
    }
    delegate.invalidateEffectiveMappings()
    assertOnePush("mappings") { delegate.refreshEffectiveMappings(for: nil) }
  }

  func testHintAndActivationChangesPushOnceAndTypingDoesNot() {
    assertOnePush("hints") { delegate.hintSession.hints = [hint("a"), hint("b")] }
    spin(for: 0.1)
    let before = snapshots
    delegate.hintSession.prefix = "a"
    spin(for: 0.15)
    XCTAssertEqual(snapshots, before, "a typed prefix changes nothing the inspector shows")
    assertOnePush("hint command") { delegate.hintSession.command = .move }
    assertOnePush("activation and the routing it takes") {
      _ = delegate.activationLifecycle.begin()
    }
  }

  func testInputCapturePermissionAndClipboardChangesPushOnce() {
    assertOnePush("secure input") { delegate.noteSecureInput(true) }
    assertOnePush("keyboard capture") {
      delegate.keyboardCaptureTap = KeyboardCaptureTap(
        shouldSwallow: { _ in .pass }, handle: { _ in })
    }
    assertOnePush("clipboard") {
      delegate.clipboardEntries = [
        ClipboardModalEntry(
          id: "0123456789abcdef0123456789abcdef", kind: "text", preview: "hello", value: "hello")
      ]
    }
    // The trust list is re-read once more a second later: the notification
    // can precede the database it announces.
    assertOnePush("accessibility trust") {
      delegate.inspectorChangeObservers?.accessibilityTrustListDidChange(
        Notification(name: AppDelegate.accessibilityTrustListDidChangeNotification))
    }
    spin(for: 1.1)
  }

  func testPluginAndConfigChangesPushOnce() {
    assertOnePush("plugins") { delegate.pluginStateDidChange() }
    assertOnePush("monitors") {
      delegate.monitorsDidChange([
        MonitorSnapshot(
          id: "disk", spec: StatusMonitorSpec(value: .init(template: "93"), warning: 90),
          tracker: MonitorTracker(sinceMs: 0))
      ])
    }
    let monitors = delegate.debugStateJSON()["monitors"] as? [[String: Any]]
    XCTAssertEqual(monitors?.map { $0["id"] as? String }, ["disk"])
    assertOnePush("config reload") { delegate.configureDebugServer(for: delegate.config) }
    XCTAssertTrue(delegate.debugServer === server, "the same listener keeps serving")
  }

  func testSurfaceAndWindowChangesPushOnce() {
    assertOnePush("status bar") {
      delegate.overlay.setStatusBarModel(
        FlashStatusBarModel(appText: "", modeText: "", rightText: "12:00"))
    }
    assertOnePush("menu-bar yielding") { delegate.overlay.setStatusBarYieldsToNativeMenuBar(true) }
    assertOnePush("terminal popups") {
      delegate.overlay.statusTerminals.apply(
        style: .init(), terminals: ["scratch": Config.Terminal(command: ["/bin/cat"])])
    }
    assertOnePush("widgets") {
      delegate.widgetController?.apply(
        widgets: [:], statusBarReservesSpace: false, statusBarMonitor: .all,
        hideFromCapture: false)
    }
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless,
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    assertOnePush("window geometry") {
      window.setFrame(CGRect(x: 20, y: 20, width: 120, height: 90), display: false)
    }
  }

  /// The status bar republishes as its values change, several times a
  /// second: its snapshot rebuilds the bar and the popup anchors it places
  /// on main, never the mappings, commands and plugins; any other change
  /// still rebuilds everything.
  func testAStatusBarChangeRebuildsOnlyTheBarsSections() {
    var scoped: [Set<String>] = []
    var full = 0
    let delegate: AppDelegate = self.delegate
    let server = DebugServer(
      host: delegate.config.debug.httpInspectorHost,
      port: delegate.config.debug.httpInspectorPort, accessToken: HelpAccess.newToken(),
      coalescingWindowMs: 200,
      sectionsProvider: { [unowned delegate] sections in
        scoped.append(sections)
        return delegate.debugStateJSON(sections: sections)
      },
      stateProvider: { [unowned delegate] in
        full += 1
        return delegate.debugStateJSON()
      })
    delegate.stopDebugServer()
    delegate.attachDebugServer(server)
    server.streamsDidChange(by: 1)
    self.server = server
    // The first snapshot is whole: there is nothing to rebuild over.
    delegate.applyModeOverlay()
    XCTAssertTrue(waitUntil { full > 0 }, "the initial snapshot did not publish")
    XCTAssertEqual(full, 1)

    // Wait for each burst to publish before starting the next. The shared
    // scheduler may deliver later than its coalescing window under load.
    delegate.overlay.statusBarDidChange?()
    delegate.overlay.statusPopupController.didChange?()
    XCTAssertTrue(waitUntil { !scoped.isEmpty }, "the status bar snapshot did not publish")
    XCTAssertEqual(full, 1, "a status bar change takes no whole snapshot")
    XCTAssertEqual(scoped, [AppDelegate.statusBarSections], "one rebuild of the burst's sections")
    delegate.widgetController?.didChange?()
    XCTAssertTrue(waitUntil { scoped.count > 1 }, "the widget snapshot did not publish")
    XCTAssertEqual(scoped, [AppDelegate.statusBarSections, ["widgets"]])
    XCTAssertEqual(full, 1)

    XCTAssertEqual(
      Set(delegate.debugStateJSON(sections: AppDelegate.statusBarSections).keys),
      AppDelegate.statusBarSections.union(["snapshot_at_unix_ms"]))
    XCTAssertEqual(
      Set(delegate.debugStateJSON(sections: ["statusbar", "mappings"]).keys),
      Set(delegate.debugStateJSON().keys), "a section the scoped build lacks rebuilds everything")

    delegate.applyModeOverlay()
    XCTAssertTrue(waitUntil { full > 1 }, "the mode snapshot did not publish")
    XCTAssertEqual(full, 2, "a mode change rebuilds everything")
  }

  /// Without a reader nothing is taken; the inspector's observers go with
  /// its server.
  func testNothingIsSnapshottedWithoutAReaderAndObserversEndWithTheServer() {
    server.streamsDidChange(by: -1)
    spin(for: 0.1)
    let before = snapshots
    delegate.noteSecureInput(true)
    delegate.hintSession.hints = [hint("a")]
    delegate.pluginStateDidChange()
    spin(for: 0.15)
    XCTAssertEqual(snapshots, before)
    XCTAssertTrue(server.publication.stale)

    delegate.stopDebugServer()
    XCTAssertNil(delegate.inspectorChangeObservers)
    XCTAssertNil(delegate.debugServer)
  }
}
