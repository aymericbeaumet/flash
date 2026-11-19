import AppKit
import FlashCore
import XCTest

@testable import flash

extension PluginManager {
  /// What the status controller reports once every surface `config` declares
  /// is on screen: each plugin segment they read, a text popup's included.
  /// Suites that drive a manager without a controller say what is shown
  /// with this, or with `setShownStatusSegments` for part of it.
  func showEverySegment(readBy config: Config) {
    setShownStatusSegments(
      Set(config.statusSegmentsRead().flatMap { id, names in names.map { "\(id).\($0)" } }))
  }
}

/// Which plugin status segments are observed (`core:status.observed`): the
/// ones a status surface shows now. The status controller's required set
/// decides it, so a closed text popup and a covered widget observe nothing,
/// while the configuration alone still decides whether a status-bound
/// plugin runs.
final class StatusPluginObservationTests: XCTestCase {
  // MARK: - The controller's report

  private static let battery = StatusMonitorSpec(
    value: .init(template: "#{flash.plugin.sysinfo.power_percent}"), warning: 20, error: 10,
    direction: .below)

  func testTheControllerReportsThePluginSegmentsItsSurfacesShowNow() {
    let queue = DispatchQueue(label: "status.plugin.observation.tests")
    var reports: [Set<String>] = []
    let controller = FlashStatusBarController(
      template: .init(template: "#{flash.plugin.sysinfo.cpu_label} #{flash.plugin.loaded_count}"),
      popupTemplates: [
        "app": .init(template: "#{flash.plugin.processes.focused_app_details}"),
        "next": .init(template: "#{flash.plugin.calendar.next}"),
      ],
      scheduler: PollScheduler(), queue: queue,
      pluginSegmentsSink: { reports.append($0) })
    controller.updateWidgets([
      "top": StatusWidgetSpec(
        template: .init(template: "#{flash.plugin.processes.top_cpu}"), intervalSeconds: 0,
        columns: 40)
    ])
    controller.updateMonitors(["battery": Self.battery])
    queue.sync {}
    XCTAssertEqual(reports.last ?? [], [], "a stopped controller shows nothing")
    controller.start()
    queue.sync {}
    let always: Set<String> = [
      "sysinfo.cpu_label", "loaded_count", "processes.top_cpu", "sysinfo.power_percent",
    ]
    XCTAssertEqual(reports.last, always, "the bar, a visible widget and a monitor")

    // A text popup counts only while it is on screen, hovered or pinned.
    controller.setPopups(shown: ["app"], live: ["app"])
    queue.sync {}
    XCTAssertEqual(reports.last, always.union(["processes.focused_app_details"]))
    let opened = reports.count
    controller.setPopups(shown: ["app"], live: [])
    queue.sync {}
    XCTAssertEqual(reports.count, opened, "pinned: still shown, nothing to report")
    controller.setPopups(shown: [], live: [])
    queue.sync {}
    XCTAssertEqual(reports.last, always, "closed: released")
    controller.setPopups(shown: ["app", "next"], live: ["next"])
    queue.sync {}
    XCTAssertEqual(
      reports.last, always.union(["processes.focused_app_details", "calendar.next"]))

    controller.setWidgetVisible(name: "top", false)
    queue.sync {}
    XCTAssertFalse(reports.last?.contains("processes.top_cpu") ?? true, "a covered widget")
    controller.setWidgetVisible(name: "top", true)
    queue.sync {}
    XCTAssertTrue(reports.last?.contains("processes.top_cpu") ?? false)

    controller.setBar(enabled: false)
    queue.sync {}
    XCTAssertEqual(
      reports.last, ["processes.top_cpu", "sysinfo.power_percent"],
      "the bar's popups go with the bar")
    controller.stopAndWait()
    XCTAssertEqual(reports.last, [])
  }

  /// A popup that opens on plugin values nobody was showing, and that have
  /// no value yet, is reported, so it can follow its document until they
  /// land; one whose values the bar already shows, whose plugin kept them
  /// published, or that reads none, is not.
  func testOnlyAPopupOpeningOnValuesNobodyShowedAwaitsThem() {
    let queue = DispatchQueue(label: "status.plugin.observation.tests")
    var awaited: [Set<String>] = []
    let controller = FlashStatusBarController(
      template: .init(template: "#{flash.plugin.sysinfo.cpu_label}"),
      popupTemplates: [
        "app": .init(template: "#{flash.plugin.processes.focused_app_details}"),
        "cpu": .init(template: "#{flash.plugin.sysinfo.cpu_label}"),
        "details": .init(template: "#{flash.plugin.sysinfo.cpu_details}"),
        "date": .init(template: "#{flash.date}"),
      ],
      // `sysinfo` samples for the bar's label and publishes its details
      // with it; `processes` cleared the value nobody showed.
      pluginStatusesProvider: {
        [
          PluginStatusBarInfo(
            id: "sysinfo", state: "running", hasError: false,
            statusSegments: ["cpu_label": .text("12%"), "cpu_details": .text("Load 1.2")])
        ]
      },
      scheduler: PollScheduler(), queue: queue,
      popupAwaitsValuesSink: { awaited.append($0) })
    defer { controller.stopAndWait() }
    func settle() {
      queue.sync {}
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    // A stopped controller shows nothing, so nothing is awaited.
    controller.setPopups(shown: ["app"], live: ["app"])
    settle()
    controller.setPopups(shown: [], live: [])
    controller.start()
    settle()
    XCTAssertEqual(awaited, [])

    controller.setPopups(shown: ["cpu"], live: ["cpu"])
    controller.setPopups(shown: ["details"], live: ["details"])
    controller.setPopups(shown: ["date"], live: [])
    settle()
    XCTAssertEqual(
      awaited, [], "a value the bar shows, one already published, and no plugin value")
    controller.setPopups(shown: ["date", "app"], live: ["app"])
    settle()
    XCTAssertEqual(awaited, [["app"]])
    controller.setPopups(shown: ["app"], live: [])
    settle()
    XCTAssertEqual(awaited, [["app"]], "pinned: the same showing")
    controller.setPopups(shown: [], live: [])
    controller.setPopups(shown: ["app"], live: [])
    settle()
    XCTAssertEqual(awaited, [["app"], ["app"]], "each opening awaits afresh")
  }

  /// The resident's wiring: a text popup on screen in any presentation, a
  /// hover preview, a pinned popup or a standalone one, shows its values,
  /// and leaving the screen releases them.
  func testAPopupOnScreenInAnyPresentationShowsItsValues() {
    _ = NSApplication.shared
    let queue = DispatchQueue(label: "status.plugin.observation.tests")
    var reports: [Set<String>] = []
    let controller = FlashStatusBarController(
      template: .init(template: "#[popup=app]app#[nopopup]"),
      popupTemplates: ["app": .init(template: "#{flash.plugin.processes.focused_app_details}")],
      scheduler: PollScheduler(), queue: queue,
      pluginSegmentsSink: { reports.append($0) })
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    delegate.statusBarController = controller
    let registry = delegate.overlay.statusTerminals
    let popup = StatusPopupController(terminals: registry, windowActionsEnabled: false)
    delegate.overlay.statusPopupController = popup
    delegate.wireInspectorChangeSources()
    defer {
      popup.dismiss()
      registry.shutdown()
      controller.stopAndWait()
    }
    controller.start()
    queue.sync {}
    XCTAssertEqual(reports, [], "closed: nothing was ever shown")

    let screen = CGRect(x: 0, y: 0, width: 900, height: 800)
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let details: Set<String> = ["processes.focused_app_details"]
    let label = StatusBarPopupRegion(
      rect: CGRect(x: 100, y: 800, width: 100, height: 20), name: "app", content: "")
    popup.preview(label, visibleFrame: screen, style: .init(), font: font)
    queue.sync {}
    XCTAssertEqual(reports, [details], "hovered")
    popup.focus()
    queue.sync {}
    XCTAssertEqual(popup.focusedName, "app")
    XCTAssertEqual(reports, [details], "pinned: still on screen")
    popup.dismiss()
    queue.sync {}
    XCTAssertEqual(reports, [details, []], "closed")

    popup.show(name: "app", document: [], visibleFrame: screen, style: .init(), font: font)
    queue.sync {}
    XCTAssertEqual(popup.presentation, .standalone(name: "app"))
    XCTAssertEqual(reports, [details, [], details], "standalone")
    popup.dismiss()
    queue.sync {}
    XCTAssertEqual(reports, [details, [], details, []])
  }

  // MARK: - The manager

  /// A status-bound plugin that records every `core:status.observed` it
  /// hears.
  private func fixture(id: String) throws -> PluginFixtureKit.Fixture {
    let script = """
      #!/bin/sh
      D="$FLASH_PLUGIN_DATA_DIR"
      printf 'spawn\\n' >> "$D/spawns"
      while IFS= read -r line; do
        id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        case "$line" in
        *'"method":"initialize"'*)
          \(PluginFixtureKit.initializeOK)
          ;;
        *'"method":"ping"'*)
          \(PluginFixtureKit.pingOK)
          ;;
        *'core:status.observed'*)
          printf '%s\\n' "$line" >> "$D/observed"
          ;;
        esac
      done
      exit 0
      """
    return try PluginFixtureKit.make(
      id: id,
      manifest: PluginFixtureKit.manifest(
        id: id, extra: #""listen": ["core:status.observed"], "status": ["details", "label"]"#),
      script: script)
  }

  private func received(_ fixture: PluginFixtureKit.Fixture) -> [[String]] {
    guard
      let text = try? String(
        contentsOf: fixture.dataDir.appendingPathComponent("observed"), encoding: .utf8)
    else { return [] }
    return text.split(separator: "\n").compactMap { line in
      let frame = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      let params = frame?["params"] as? [String: Any]
      return (params?["payload"] as? [String: Any])?["segments"] as? [String]
    }
  }

  private func config(_ fixture: PluginFixtureKit.Fixture, _ toml: String) -> Config {
    var config = ConfigLoader.parse(toml)
    config.plugins.disabled = Set(
      PluginRepository.officialPluginRoots().compactMap { (try? PluginManifest.load(from: $0))?.id }
    )
    config.plugins.thirdParty = [PluginReference.parse("file:\(fixture.root.path)")]
      .compactMap { $0 }
    config.plugins.watchingEnabled = false
    return config
  }

  /// A value read only by a text popup keeps its plugin running, since the
  /// configuration refers to it, and observes nothing until the popup
  /// opens: opening tells the child at once, closing releases it, and
  /// neither spawns anything.
  func testAPopupsPluginValueIsObservedOnlyWhileThePopupIsOpen() throws {
    let fixture = try fixture(id: "popupbound")
    defer { fixture.cleanup() }
    let manager = PluginManager(baseDataDir: fixture.baseDataDir)
    defer { manager.stop() }
    let config = config(
      fixture,
      """
      [statusbar]
      enabled = true
      template = "#[popup=app]app#[nopopup]"

      [popup.app]
      text = "#{flash.plugin.popupbound.details}"
      """)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    // The status controller as the resident wires it: its required set is
    // what the manager tells the plugins.
    let queue = DispatchQueue(label: "status.plugin.observation.controller")
    let controller = FlashStatusBarController(
      template: config.statusBar.template, popupTemplates: config.textPopups,
      pluginStatusesProvider: { [weak manager] in manager?.statusBarInfos() ?? [] },
      scheduler: PollScheduler(), queue: queue,
      pluginSegmentsSink: { [weak manager] in manager?.setShownStatusSegments($0) })
    defer { controller.stopAndWait() }
    manager.start(config: config)
    controller.start()

    waitUntilTrue("the plugin runs: the configuration refers to its value") {
      manager.pluginStatuses().first { $0.id == "popupbound" }?.state == "running"
    }
    XCTAssertEqual(manager.pluginStatuses().first?.activation, "resident")
    waitUntilTrue("the child heard its first set") { !self.received(fixture).isEmpty }
    settleRunLoop(0.3)
    XCTAssertEqual(received(fixture), [[]], "nobody looks at a closed popup")

    controller.setPopups(shown: ["app"], live: ["app"])
    waitUntilTrue("opening the popup observes its value") {
      self.received(fixture).last == ["details"]
    }
    controller.setPopups(shown: [], live: [])
    waitUntilTrue("closing it releases the value") { self.received(fixture).count == 3 }
    XCTAssertEqual(received(fixture), [[], ["details"], []])
    XCTAssertEqual(fixture.spawnCount(), 1, "the child stayed up throughout")
  }
}
