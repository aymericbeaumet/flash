import XCTest

@testable import flash

/// `[monitors.<name>]`: a value judged against thresholds, evaluated beside
/// the bar and widgets, alerting through the centred alert on a rise only.
final class MonitorTests: XCTestCase {
  // MARK: - The state machine

  func testAnAlertFiresOnARiseIntoWarningOrErrorAndNeverWhileTheStatePersists() {
    var tracker = MonitorTracker(sinceMs: 0)
    XCTAssertNil(tracker.observe(.ok, now: 0, wallMs: 1))
    XCTAssertEqual(tracker.observe(.warning, now: 10, wallMs: 2), .warning)
    XCTAssertNil(tracker.observe(.warning, now: 20, wallMs: 3), "a persisting state is quiet")
    XCTAssertEqual(tracker.observe(.error, now: 30, wallMs: 4), .error, "warning to error alerts")
    XCTAssertNil(tracker.observe(.warning, now: 40, wallMs: 5), "easing off is not news")
    XCTAssertNil(tracker.observe(.ok, now: 50, wallMs: 6), "a recovery clears silently")
    XCTAssertEqual(tracker.level, .ok)
    XCTAssertEqual(tracker.sinceMs, 6)
    XCTAssertEqual(tracker.lastAlertMs, 4)
  }

  func testTheFirstKnownValueAlertsWhenItIsAlreadyBad() {
    var tracker = MonitorTracker(sinceMs: 0)
    XCTAssertEqual(tracker.observe(.error, now: 0, wallMs: 1), .error)
  }

  func testAValueThatBlinksOutAndBackDoesNotAlertTwice() {
    var tracker = MonitorTracker(sinceMs: 0)
    XCTAssertEqual(tracker.observe(.warning, now: 0, wallMs: 1), .warning)
    XCTAssertNil(tracker.observe(.unknown, now: 1_000, wallMs: 2))
    XCTAssertEqual(tracker.level, .unknown)
    XCTAssertEqual(tracker.sinceMs, 2)
    XCTAssertNil(
      tracker.observe(.warning, now: 2_000, wallMs: 3),
      "a plugin restart blanking the value is not a new warning")
    XCTAssertEqual(tracker.observe(.error, now: 2_001, wallMs: 4), .error)
  }

  func testAFlappingMonitorAlertsAtMostOncePerLevelPerCooldown() {
    let cooldown = MonitorTracker.alertCooldownSeconds
    XCTAssertEqual(cooldown, 300)
    var tracker = MonitorTracker(sinceMs: 0)
    XCTAssertEqual(tracker.observe(.warning, now: 0, wallMs: 1), .warning)
    XCTAssertNil(tracker.observe(.ok, now: 10, wallMs: 2))
    XCTAssertNil(tracker.observe(.warning, now: 20, wallMs: 3), "within the cooldown")
    XCTAssertEqual(tracker.lastAlertMs, 1)
    XCTAssertEqual(
      tracker.observe(.error, now: 30, wallMs: 4), .error,
      "a warning's cooldown never swallows an error")
    XCTAssertNil(tracker.observe(.ok, now: 40, wallMs: 5))
    XCTAssertEqual(tracker.observe(.warning, now: cooldown, wallMs: 6), .warning)
    XCTAssertNil(tracker.observe(.error, now: cooldown + 1, wallMs: 7), "error still cooling")
    XCTAssertNil(tracker.observe(.ok, now: cooldown + 2, wallMs: 8))
    XCTAssertEqual(tracker.observe(.error, now: cooldown + 30, wallMs: 9), .error)
  }

  func testThresholdsCountOnceReachedInTheirDirection() {
    let above = StatusMonitorSpec(value: .init(template: ""), warning: 90, error: 97)
    XCTAssertEqual(above.level(of: nil), .unknown)
    XCTAssertEqual(above.level(of: 89.9), .ok)
    XCTAssertEqual(above.level(of: 90), .warning)
    XCTAssertEqual(above.level(of: 97), .error)
    let below = StatusMonitorSpec(
      value: .init(template: ""), warning: 20, error: 10, direction: .below)
    XCTAssertEqual(below.level(of: 21), .ok)
    XCTAssertEqual(below.level(of: 20), .warning)
    XCTAssertEqual(below.level(of: 3), .error)
    let errorOnly = StatusMonitorSpec(value: .init(template: ""), error: 5)
    XCTAssertEqual(errorOnly.level(of: 4), .ok)
    XCTAssertEqual(errorOnly.level(of: 5), .error)
  }

  func testTheDerivedMessageNamesTheThresholdCrossed() {
    let spec = StatusMonitorSpec(
      value: .init(template: ""), warning: 20, error: 10, direction: .below)
    XCTAssertEqual(spec.derivedMessage(name: "battery", level: .warning), "Battery below 20")
    XCTAssertEqual(spec.derivedMessage(name: "battery", level: .error), "Battery below 10")
    XCTAssertEqual(spec.derivedMessage(name: "low_power", level: .ok), "Low power below 20")
    XCTAssertEqual(MonitorText.number(0.5), "0.5")
  }

  func testAValueMustStartWithANumber() {
    XCTAssertEqual(MonitorText.leadingNumber("87%"), 87)
    XCTAssertEqual(MonitorText.leadingNumber("1532 ms"), 1532)
    XCTAssertEqual(MonitorText.leadingNumber("-3 C"), -3)
    XCTAssertEqual(MonitorText.leadingNumber("0.75"), 0.75)
    XCTAssertEqual(MonitorText.leadingNumber(".5"), 0.5)
    XCTAssertNil(MonitorText.leadingNumber(""))
    XCTAssertNil(MonitorText.leadingNumber("%"))
    XCTAssertNil(MonitorText.leadingNumber("load 3"))
    XCTAssertNil(MonitorText.leadingNumber("-"))
  }

  // MARK: - Configuration

  private func messages(_ config: Config) -> [String] {
    config.loadingDiagnostics.map(\.message)
  }

  func testEveryMonitorKeyParses() throws {
    let config = ConfigLoader.parse(
      """
      [statusbar.sources.load]
      command = ["/usr/bin/true"]

      [monitors.load]
      enabled = false
      value = "#{flash.source.load}"
      message = "Load #{flash.source.load}"
      detail = "#{flash.source.load} runnable"
      warning = 4
      error = 8.5
      direction = "above"
      interval = 30
      """)
    XCTAssertEqual(messages(config), [])
    let monitor = try XCTUnwrap(config.monitors["load"])
    XCTAssertEqual(
      monitor,
      Config.Monitor(
        enabled: false, value: "#{flash.source.load}", message: "Load #{flash.source.load}",
        detail: "#{flash.source.load} runnable", warning: 4, error: 8.5, direction: .above,
        intervalSeconds: 30))
    XCTAssertNil(config.enabledMonitors["load"])
    let spec = try XCTUnwrap(config.monitorSpecs["load"])
    XCTAssertFalse(spec.enabled)
    XCTAssertEqual(spec.origin, .config)
    XCTAssertEqual(config.monitorSpecs["battery"]?.origin, .default)
  }

  func testAUserLayerRetunesABuiltInMonitorKeyByKey() throws {
    let config = ConfigLoader.parse(
      """
      [monitors.disk]
      warning = 80
      error = false

      [monitors.battery]
      enabled = false
      """)
    XCTAssertEqual(messages(config), [])
    let disk = try XCTUnwrap(config.monitors["disk"])
    XCTAssertEqual(disk.warning, 80)
    XCTAssertNil(disk.error, "false removes the bundled threshold")
    XCTAssertEqual(disk.value, Config.defaultMonitors["disk"]?.value)
    XCTAssertNil(config.enabledMonitors["battery"])
    XCTAssertEqual(config.monitorSpecs["disk"]?.origin, .default)
  }

  func testMalformedMonitorsAreReportedAndDoNotRun() {
    let config = ConfigLoader.parse(
      """
      [monitors."bad name"]
      value = "1"
      warning = 1

      [monitors.flat]
      value = "1"

      [monitors.backwards]
      value = "1"
      warning = 50
      error = 10

      [monitors.typo]
      value = "1"
      warning = "high"
      direction = "sideways"
      interval = 0
      treshold = 4

      [monitors.unknown]
      value = "#{flash.nope}"
      warning = 1
      """)
    let found = messages(config)
    for expected in [
      "monitor name 'bad name' must use only letters, digits, '_' and '-'",
      "monitors.flat needs a warning or an error threshold",
      "monitors.backwards.warning must be below .error when direction is \"above\"",
      "monitors.typo.warning must be a number, or false to remove it",
      "monitors.typo.direction must be \"above\" or \"below\"",
      "monitors.typo.interval must be an integer between 1 and 86400 (seconds)",
      "unknown config key 'monitors.typo.treshold'",
      "monitors.typo needs a warning or an error threshold",
      "monitors.unknown.value has unknown Flash value flash.nope",
    ] {
      XCTAssertTrue(found.contains { $0.hasPrefix(expected) }, "\(expected) in \(found)")
    }
    for name in ["flat", "backwards", "typo"] {
      XCTAssertNil(config.enabledMonitors[name], name)
      XCTAssertEqual(config.monitorSpecs[name]?.enabled, false, name)
    }
  }

  func testTheCoreMonitorValuesAreKnownToTheLanguage() {
    let config = ConfigLoader.parse(
      """
      [monitors.mine]
      value = "#{flash.memory_pressure} #{flash.plugin.spawn_ms}"
      detail = "#{flash.plugin.errors} #{flash.plugin.spawn_id}"
      warning = 1
      """)
    XCTAssertEqual(messages(config), [])
  }

  func testTheBuiltInPluginMonitorsNameThePluginsTheyCount() {
    XCTAssertEqual(Config.defaultMonitors["plugin_errors"]?.detail, "#{flash.plugin.errors}")
    XCTAssertEqual(
      Config.defaultMonitors["plugin_spawn"]?.detail,
      "#{flash.plugin.spawn_id} #{flash.plugin.spawn_ms} ms")
    for name in ["battery", "disk", "memory"] {
      XCTAssertEqual(Config.defaultMonitors[name]?.detail, "", "\(name) alerts with its value")
    }
  }

  func testAnEnabledMonitorKeepsThePluginSegmentsItReadsObserved() {
    var config = ConfigLoader.parse(
      """
      [monitors.battery]
      enabled = false

      [monitors.mine]
      value = "#{flash.plugin.sysinfo.cpu_percent}"
      message = "#{flash.plugin.sysinfo.cpu_label}"
      detail = "#{flash.plugin.sysinfo.cpu_top}"
      warning = 90
      """)
    XCTAssertFalse(config.statusBar.enabled)
    let observed = config.observedStatusSegments()
    XCTAssertEqual(Set(observed.keys), ["sysinfo"])
    XCTAssertEqual(
      observed["sysinfo"], ["cpu_percent", "cpu_label", "cpu_top", "disks_percent"],
      "the custom monitor's cpu segments beside the built-in disk monitor's")
    XCTAssertFalse(
      observed["sysinfo"]?.contains("power_percent") ?? false,
      "a disabled monitor observes nothing")
    config.monitors["mine"]?.enabled = false
    XCTAssertEqual(config.observedStatusSegments()["sysinfo"], ["disks_percent"])
  }

  // MARK: - Evaluation beside the bar

  private final class Task: StatusCommandTask {
    let invocation: StatusCommandInvocation
    let completion: (Int32, String) -> Void
    var cancelled = false

    init(_ invocation: StatusCommandInvocation, completion: @escaping (Int32, String) -> Void) {
      self.invocation = invocation
      self.completion = completion
    }

    func cancel() { cancelled = true }
  }

  private final class Harness {
    let queue = DispatchQueue(label: "monitor.tests")
    var now: TimeInterval = 100
    var wall = Date(timeIntervalSince1970: 1_800_000_020)
    var plugins: [PluginStatusBarInfo] = []
    var memoryPressure: String? = "40"
    var hostReads = 0
    var tasks: [Task] = []
    var controller: FlashStatusBarController!
    /// What the sinks handed to main, in order.
    var fires: [MonitorFire] = []
    var notified: [(name: String, alert: StatusAlert)] = []
    var alerts: [StatusAlert] = []

    init(
      monitors: [String: StatusMonitorSpec], bar: String? = nil,
      sources: [String: FlashStatusBarSourceDefinition] = [:]
    ) {
      controller = FlashStatusBarController(
        template: .init(template: bar ?? ""), sources: sources, refreshIntervalSeconds: 5,
        pluginStatusesProvider: { [unowned self] in plugins },
        scheduler: PollScheduler(), queue: queue, clock: { [unowned self] in now },
        wallClock: { [unowned self] in wall },
        makeJob: { [unowned self] invocation, _, _, completion in
          let task = Task(invocation, completion: completion)
          tasks.append(task)
          return task
        },
        // A hop can land after the test that queued it ended.
        monitorAlertSink: { [weak self] in self?.alerts.append($0) },
        monitorFireSink: { [weak self] in self?.fires.append($0) },
        monitorNotifySink: { [weak self] name, alert in self?.notified.append((name, alert)) },
        readHostValue: { [unowned self] value in
          XCTAssertEqual(value, .memoryPressure)
          hostReads += 1
          return memoryPressure
        })
      if bar == nil { controller.setBar(enabled: false) }
      controller.updateMonitors(monitors)
      controller.start()
      drain()
    }

    func drain() { queue.sync {} }
    func tick() { queue.sync { controller.tick() } }
    /// Let the sinks' main-queue hops land.
    func settle() {
      drain()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    func publish(_ segments: [String: String], plugin: String = "sysinfo", hasError: Bool = false) {
      queue.sync {
        plugins = [
          PluginStatusBarInfo(
            id: plugin, state: "running", hasError: hasError,
            statusSegments: segments.mapValues { .text($0) })
        ]
      }
      controller.refreshPluginSections()
      drain()
    }

    var snapshots: [MonitorSnapshot] { queue.sync { controller.lastPublishedMonitors } }
    func snapshot(_ name: String) -> MonitorSnapshot? { snapshots.first { $0.id == name } }
    var nextWakeup: TimeInterval? { queue.sync { controller.nextWakeup } }
    func evaluations(_ name: String) -> Int {
      queue.sync {
        controller.surfaceEvaluations[FlashStatusBarController.monitorSurfaceName(name), default: 0]
      }
    }
  }

  private static let battery = StatusMonitorSpec(
    value: .init(template: "#{flash.plugin.sysinfo.power_percent}%%"),
    message: .init(template: "Battery low"), warning: 20, error: 10, direction: .below)

  func testAMonitorFollowsItsPluginValueWithTheBarOffAndAlertsOnARise() {
    let harness = Harness(monitors: ["battery": Self.battery])
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.snapshot("battery")?.level, .unknown, "nothing published yet")
    harness.publish(["power_percent": "55"])
    var battery = harness.snapshot("battery")
    XCTAssertEqual(battery?.level, .ok)
    XCTAssertEqual(battery?.value, 55)
    XCTAssertEqual(battery?.display, "55%")
    XCTAssertEqual(battery?.message, "Battery low")
    XCTAssertNil(battery?.lastAlertMs)

    harness.queue.sync { harness.wall = Date(timeIntervalSince1970: 1_800_000_100) }
    harness.publish(["power_percent": "18"])
    battery = harness.snapshot("battery")
    XCTAssertEqual(battery?.level, .warning)
    XCTAssertEqual(battery?.sinceMs, 1_800_000_100_000)
    XCTAssertEqual(battery?.lastAlertMs, 1_800_000_100_000)
    XCTAssertEqual(
      battery?.alert(at: .warning),
      StatusAlert(title: "Battery low", value: "18%", style: .warning))

    harness.queue.sync { harness.wall = Date(timeIntervalSince1970: 1_800_000_200) }
    harness.publish(["power_percent": "17"])
    XCTAssertEqual(
      harness.snapshot("battery")?.lastAlertMs, 1_800_000_100_000, "no repeat while it persists")
    harness.publish(["power_percent": "9"])
    XCTAssertEqual(harness.snapshot("battery")?.level, .error)
    XCTAssertEqual(harness.snapshot("battery")?.lastAlertMs, 1_800_000_200_000)
    harness.publish(["power_percent": "80"])
    XCTAssertEqual(harness.snapshot("battery")?.level, .ok)
    XCTAssertEqual(harness.snapshot("battery")?.lastAlertMs, 1_800_000_200_000)
  }

  // MARK: - Runs and events

  /// A monitor without thresholds is a hook on its value: its `run` fires on
  /// every change from its first known value on.
  func testAChangeMonitorRunsOnEveryChangeButNotItsFirstValue() {
    let spec = StatusMonitorSpec(
      value: .init(template: "#{flash.plugin.sysinfo.wifi}"), fires: .onChange)
    let harness = Harness(monitors: ["wifi": spec])
    defer { harness.controller.stop() }
    harness.publish(["wifi": "home"])
    harness.settle()
    XCTAssertEqual(harness.fires, [], "the first value is where it starts")
    harness.publish(["wifi": "office"])
    harness.settle()
    harness.publish(["wifi": "office"])
    harness.settle()
    harness.publish(["wifi": "cafe"])
    harness.settle()
    XCTAssertEqual(harness.fires.map(\.display), ["office", "cafe"])
    XCTAssertEqual(harness.alerts, [], "a change monitor never alerts")
  }

  /// With thresholds, `run` rides the rise the alert would; `alert = false`
  /// keeps only the run.
  func testARiseRunsAndAlertsUnlessTheAlertIsOff() {
    var spec = Self.battery
    spec.fires = .onRise
    spec.alerts = false
    let harness = Harness(monitors: ["battery": spec])
    defer { harness.controller.stop() }
    harness.publish(["power_percent": "55"])
    harness.publish(["power_percent": "18"])
    harness.publish(["power_percent": "17"])
    harness.publish(["power_percent": "9"])
    harness.settle()
    XCTAssertEqual(harness.fires.map(\.level), [.warning, .error])
    XCTAssertEqual(harness.fires.map(\.display), ["18%", "9%"])
    XCTAssertEqual(harness.alerts, [])
    XCTAssertEqual(
      MonitorEnvironment.value(harness.fires[0]),
      ["FLASH_MONITOR": "battery", "FLASH_VALUE": "18%", "FLASH_STATE": "warning"])
  }

  /// `notify = true` posts the rise as a macOS notification, with or
  /// without the centred alert.
  func testANotifyingMonitorPostsItsRiseAsANotification() {
    var spec = Self.battery
    spec.alerts = false
    spec.notifies = true
    let harness = Harness(monitors: ["battery": spec])
    defer { harness.controller.stop() }
    harness.publish(["power_percent": "55"])
    harness.publish(["power_percent": "18"])
    harness.publish(["power_percent": "17"])
    harness.settle()
    XCTAssertEqual(harness.alerts, [], "alert = false shows no centred alert")
    XCTAssertEqual(harness.notified.map(\.name), ["battery"], "one notification per rise")
    XCTAssertEqual(harness.notified.first?.alert.value, "18%")
    XCTAssertEqual(harness.notified.first?.alert.style, .warning)
  }

  func testNotifyNeedsSomethingToSay() {
    let config = ConfigLoader.parse(
      """
      [monitors.loud]
      value = "1"
      warning = 1
      notify = true

      [monitors.silent]
      value = "1"
      run = ["/usr/bin/true"]
      notify = true

      [monitors.wake]
      event = "core:system.woke"
      run = ["/usr/bin/true"]
      notify = true

      [monitors.typo]
      value = "1"
      warning = 1
      notify = "yes"
      """)
    let messages = config.diagnostics.map(\.message)
    XCTAssertEqual(config.monitorSpecs["loud"]?.notifies, true)
    XCTAssertTrue(
      messages.contains {
        $0.contains(
          "monitors.silent notifies on a rise, which needs a warning or an error threshold")
      }, "\(messages)")
    XCTAssertTrue(
      messages.contains { $0.contains("monitors.wake notifies with its message, which is empty") },
      "\(messages)")
    XCTAssertTrue(messages.contains { $0.contains("monitors.typo.notify must be true or false") })
    let event = ConfigLoader.parse(
      """
      [monitors.wake]
      event = "core:system.woke"
      message = "Awake"
      alert = false
      notify = true
      """)
    XCTAssertEqual(event.eventMonitorSpecs["wake"]?.alerts, false)
    XCTAssertEqual(event.eventMonitorSpecs["wake"]?.notifies, true)
  }

  func testEventMonitorsParseAndRejectWhatOnlyAValueHas() throws {
    let config = ConfigLoader.parse(
      """
      [monitors.wake]
      event = "core:system.woke"
      run = ["flash", "caffeinate", "off"]

      [monitors.apps]
      event = ["core:apps.launched", "core:apps.terminated"]
      app = "com.apple.Safari"
      run = ["/usr/bin/true", "--flag"]
      message = "Safari came or went"

      [monitors.both]
      event = "core:system.woke"
      value = "1"
      run = ["/usr/bin/true"]

      [monitors.limited]
      event = "core:system.woke"
      warning = 3
      run = ["/usr/bin/true"]

      [monitors.nowhere]
      event = "core:nothing.*"
      run = ["/usr/bin/true"]

      [monitors.idle]
      event = "core:screen.locked"

      [monitors.stray]
      value = "1"
      warning = 1
      app = "com.apple.Safari"

      [monitors.changes]
      value = "#{flash.focused_app_name}"
      run = ["/usr/bin/true"]
      """)
    let found = messages(config)
    for expected in [
      "monitors.both watches either a value or an event, not both",
      "monitors.limited has thresholds, which only a value has",
      "monitors.nowhere.event \"core:nothing.*\" matches no host event",
      "monitors.idle needs a run or a message for its events",
      "monitors.stray.app narrows events; it needs an event",
    ] {
      XCTAssertTrue(found.contains { $0.hasPrefix(expected) }, "\(expected) in \(found)")
    }
    XCTAssertEqual(Set(config.eventMonitorSpecs.keys), ["wake", "apps"])
    let apps = try XCTUnwrap(config.eventMonitorSpecs["apps"])
    XCTAssertEqual(apps.app, "com.apple.Safari")
    XCTAssertEqual(apps.message, "Safari came or went")
    XCTAssertEqual(
      config.monitors["wake"]?.run,
      [parseMappingCommand(argv: ["flash", "caffeinate", "off"])].compactMap { $0 })
    XCTAssertEqual(config.monitors["apps"]?.run, [.shellCommand(["/usr/bin/true", "--flag"])])
    XCTAssertNil(config.monitorSpecs["wake"], "the status controller evaluates values only")
    XCTAssertEqual(config.monitorSpecs["changes"]?.fires, .onChange)
    XCTAssertEqual(config.monitorSpecs["changes"]?.enabled, true)
  }

  func testAnEventMonitorMatchesItsGlobsAndApp() {
    let spec = EventMonitorSpec(
      patterns: [PluginPattern("core:apps.*")], app: "com.apple.Safari", message: nil)
    func event(_ name: String, _ bundle: String?) -> PluginEvent {
      PluginEvent(name: name, payload: bundle.map { ["bundle_id": $0] } ?? [:], bundleID: nil)
    }
    XCTAssertTrue(spec.matches(event("core:apps.launched", "com.apple.Safari")))
    XCTAssertFalse(spec.matches(event("core:apps.launched", "com.apple.Notes")))
    XCTAssertFalse(spec.matches(event("core:focus.changed", "com.apple.Safari")))
    let any = EventMonitorSpec(patterns: [PluginPattern("core:screen.*")], app: nil, message: nil)
    XCTAssertTrue(any.matches(event("core:screen.unlocked", nil)))
    XCTAssertTrue(any.listens(to: "core:screen.locked"))
  }

  func testARunExecutableReadsTheEventFromItsEnvironment() {
    let event = PluginEvent(
      name: "core:displays.changed",
      payload: [
        "added": ["Studio Display"], "removed": [String](), "count": 2, "pid": 7,
        "nested": ["a": 1],
      ],
      bundleID: nil)
    XCTAssertEqual(
      MonitorEnvironment.event(event, monitor: "docked"),
      [
        "FLASH_MONITOR": "docked", "FLASH_EVENT": "core:displays.changed",
        "FLASH_EVENT_ADDED": "Studio Display", "FLASH_EVENT_REMOVED": "",
        "FLASH_EVENT_COUNT": "2", "FLASH_EVENT_PID": "7",
      ])
  }

  func testADisplayChangeNamesWhatWasConnectedAndRemoved() throws {
    let before: [CGDirectDisplayID: String] = [1: "Built-in Retina Display"]
    let after: [CGDirectDisplayID: String] = [1: "Built-in Retina Display", 2: "Studio Display"]
    let added = try XCTUnwrap(SystemEventObservers.displayChange(from: before, to: after))
    XCTAssertEqual(added["added"] as? [String], ["Studio Display"])
    XCTAssertEqual(added["removed"] as? [String], [])
    let removed = try XCTUnwrap(SystemEventObservers.displayChange(from: after, to: before))
    XCTAssertEqual(removed["removed"] as? [String], ["Studio Display"])
    XCTAssertNil(SystemEventObservers.displayChange(from: after, to: after), "same displays")
  }

  func testTheAlertSinkReceivesTheMessageOverTheValue() {
    let alerted = expectation(description: "alert")
    var shown: [StatusAlert] = []
    let queue = DispatchQueue(label: "monitor.tests.sink")
    var plugins: [PluginStatusBarInfo] = []
    let controller = FlashStatusBarController(
      template: .init(template: ""), pluginStatusesProvider: { plugins },
      scheduler: PollScheduler(), queue: queue,
      monitorAlertSink: { alert in
        shown.append(alert)
        alerted.fulfill()
      })
    defer { controller.stop() }
    controller.setBar(enabled: false)
    controller.updateMonitors(["battery": Self.battery])
    controller.start()
    queue.sync {
      plugins = [
        PluginStatusBarInfo(
          id: "sysinfo", state: "running", hasError: false,
          statusSegments: ["power_percent": .text("7")])
      ]
    }
    controller.refreshPluginSections()
    wait(for: [alerted], timeout: 5)
    XCTAssertEqual(shown, [StatusAlert(title: "Battery low", value: "7%", style: .error)])
  }

  func testAMonitorIsReEvaluatedOnlyWhenAValueItReadChanged() {
    let harness = Harness(monitors: ["battery": Self.battery])
    defer { harness.controller.stop() }
    harness.publish(["power_percent": "55"])
    let evaluations = harness.evaluations("battery")
    harness.publish(["power_percent": "55", "power_state": "charging"])
    XCTAssertEqual(harness.evaluations("battery"), evaluations)
    harness.publish(["power_percent": "54", "power_state": "charging"])
    XCTAssertEqual(harness.evaluations("battery"), evaluations + 1)
  }

  func testADisabledMonitorIsListedButNeverEvaluated() {
    var spec = Self.battery
    spec.enabled = false
    let harness = Harness(monitors: ["battery": spec])
    defer { harness.controller.stop() }
    harness.publish(["power_percent": "5"])
    let battery = harness.snapshot("battery")
    XCTAssertEqual(battery?.enabled, false)
    XCTAssertEqual(battery?.level, .unknown)
    XCTAssertNil(battery?.value)
    XCTAssertEqual(battery?.sinceMs, 1_800_000_020_000)
    XCTAssertEqual(harness.evaluations("battery"), 0)
    XCTAssertNil(harness.nextWakeup)
  }

  func testAKernelValueIsReadAtTheMonitorIntervalAndNeverTicksTheClock() {
    let spec = StatusMonitorSpec(
      value: .init(template: "#{flash.memory_pressure}%%"),
      message: .init(template: "Memory %H:%M"), warning: 85, error: 95, intervalSeconds: 60)
    let harness = Harness(monitors: ["memory": spec])
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.hostReads, 1, "read as soon as a monitor reads it")
    XCTAssertEqual(harness.snapshot("memory")?.value, 40)
    XCTAssertEqual(harness.nextWakeup, 160, "the interval, not the message's minute")
    harness.queue.sync {
      harness.now = 130
      harness.memoryPressure = "90"
    }
    harness.publish([:])
    XCTAssertEqual(harness.hostReads, 1, "a publish before the interval reads nothing")
    harness.queue.sync { harness.now = 160 }
    harness.tick()
    XCTAssertEqual(harness.hostReads, 2)
    XCTAssertEqual(harness.snapshot("memory")?.level, .warning)
    XCTAssertEqual(harness.nextWakeup, 220)
    // Removing the monitor stops the reads.
    harness.controller.updateMonitors([:])
    harness.drain()
    XCTAssertNil(harness.nextWakeup)
    XCTAssertEqual(harness.snapshots, [])
  }

  func testAMonitorRunsTheSourcesAndJobsItReads() {
    let source = FlashStatusBarSourceDefinition(command: ["/bin/load"], intervalSeconds: 30)
    let spec = StatusMonitorSpec(
      value: .init(template: "#{flash.source.load} #(echo job)"), warning: 4,
      intervalSeconds: 120)
    let harness = Harness(monitors: ["load": spec], sources: ["load": source])
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.tasks.count, 2)
    harness.queue.sync {
      harness.tasks[0].completion(0, "5.5")
      harness.tasks[1].completion(0, "")
    }
    harness.drain()
    XCTAssertEqual(harness.snapshot("load")?.level, .warning)
    XCTAssertEqual(harness.snapshot("load")?.display, "5.5")
    XCTAssertEqual(harness.nextWakeup, 130, "the source's own interval comes first")
    harness.queue.sync { harness.now = 130 }
    harness.tick()
    XCTAssertEqual(harness.tasks.count, 3, "the source re-runs; the job waits for 120 s")
    harness.controller.updateMonitors([:])
    harness.drain()
    XCTAssertTrue(harness.tasks[2].cancelled, "removing the monitor reaps its running source")
    XCTAssertNil(harness.nextWakeup)
  }

  func testTheLatestPluginSpawnIsACoreValue() {
    let spawn = StatusMonitorSpec(
      value: .init(template: "#{flash.plugin.spawn_ms} ms"),
      detail: .init(template: "#{flash.plugin.spawn_id} #{flash.plugin.spawn_ms} ms"),
      warning: 1000, error: 5000)
    let harness = Harness(monitors: ["plugin_spawn": spawn])
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.snapshot("plugin_spawn")?.level, .unknown, "no spawn yet")
    harness.queue.sync {
      harness.plugins = [
        PluginStatusBarInfo(
          id: "late", state: "running", hasError: false, statusSegments: [:],
          lastSpawn: PluginSpawnTiming(milliseconds: 12.4, at: 2_000)),
        PluginStatusBarInfo(
          id: "early", state: "running", hasError: false, statusSegments: [:],
          lastSpawn: PluginSpawnTiming(milliseconds: 6_210.6, at: 1_000)),
      ]
    }
    harness.controller.refreshPluginSections()
    harness.drain()
    let snapshot = harness.snapshot("plugin_spawn")
    XCTAssertEqual(snapshot?.display, "12 ms", "the latest spawn, not the slowest")
    XCTAssertEqual(snapshot?.level, .ok)
    XCTAssertEqual(snapshot?.detail, "late 12 ms", "the spawn names its plugin")
  }

  func testAFailingCountNamesWhatFailsInItsAlert() {
    let errors = StatusMonitorSpec(
      value: .init(template: "#{flash.plugin.error_count}"),
      message: .init(template: "Failing plugins"),
      detail: .init(template: "#{flash.plugin.errors}"),
      warning: 1)
    let harness = Harness(monitors: ["plugin_errors": errors])
    defer { harness.controller.stop() }
    func plugin(_ id: String, failing: Bool) -> PluginStatusBarInfo {
      PluginStatusBarInfo(id: id, state: "running", hasError: failing, statusSegments: [:])
    }
    harness.queue.sync { harness.plugins = [plugin("cpu", failing: false)] }
    harness.controller.refreshPluginSections()
    harness.drain()
    XCTAssertEqual(harness.snapshot("plugin_errors")?.level, .ok)
    XCTAssertEqual(harness.snapshot("plugin_errors")?.detail, "")
    harness.queue.sync {
      harness.plugins = [
        plugin("tmux", failing: true), plugin("cpu", failing: false),
        plugin("media", failing: true),
      ]
    }
    harness.controller.refreshPluginSections()
    harness.drain()
    let snapshot = harness.snapshot("plugin_errors")
    XCTAssertEqual(snapshot?.level, .warning)
    XCTAssertEqual(snapshot?.display, "2")
    XCTAssertEqual(snapshot?.detail, "media, tmux")
    XCTAssertEqual(
      snapshot?.alert(at: .warning),
      StatusAlert(title: "Failing plugins", value: "media, tmux", style: .warning),
      "the alert names the failing plugins, not their count")
  }

  func testAnEmptyDetailAlertsWithTheValue() {
    var spec = Self.battery
    spec.detail = .init(template: "#{flash.plugin.sysinfo.power_source}")
    let harness = Harness(monitors: ["battery": spec])
    defer { harness.controller.stop() }
    harness.publish(["power_percent": "8"])
    XCTAssertEqual(
      harness.snapshot("battery")?.alert(at: .error),
      StatusAlert(title: "Battery low", value: "8%", style: .error))
    harness.publish(["power_percent": "8", "power_source": "Battery Power"])
    XCTAssertEqual(
      harness.snapshot("battery")?.alert(at: .error),
      StatusAlert(title: "Battery low", value: "Battery Power", style: .error))
  }

  func testAChangedThresholdKeepsTheStateAndANewValueStartsAfresh() {
    let harness = Harness(monitors: ["battery": Self.battery])
    defer { harness.controller.stop() }
    harness.publish(["power_percent": "15"])
    XCTAssertEqual(harness.snapshot("battery")?.level, .warning)
    let alerted = harness.snapshot("battery")?.lastAlertMs
    var retuned = Self.battery
    retuned.warning = 30
    harness.controller.updateMonitors(["battery": retuned])
    harness.drain()
    XCTAssertEqual(harness.snapshot("battery")?.warning, 30)
    XCTAssertEqual(harness.snapshot("battery")?.level, .warning)
    XCTAssertEqual(harness.snapshot("battery")?.lastAlertMs, alerted, "no second alert")
    var rewritten = Self.battery
    rewritten.value = .init(template: "#{flash.plugin.sysinfo.power_percent}")
    harness.controller.updateMonitors(["battery": rewritten])
    harness.drain()
    XCTAssertEqual(harness.snapshot("battery")?.expression, "#{flash.plugin.sysinfo.power_percent}")
    XCTAssertEqual(harness.snapshot("battery")?.display, "15")
  }

  // MARK: - The help page

  func testTheSnapshotCarriesTheHelpPageContract() throws {
    let harness = Harness(monitors: ["battery": Self.battery])
    defer { harness.controller.stop() }
    harness.publish(["power_percent": "18"])
    let object = try XCTUnwrap(harness.snapshot("battery")).jsonObject
    XCTAssertEqual(
      Set(object.keys),
      [
        "id", "name", "origin", "enabled", "value", "display", "state", "direction", "warning",
        "error", "interval_s", "message", "detail", "since_ms", "last_alert_ms", "expression",
      ])
    XCTAssertEqual(object["id"] as? String, "battery")
    XCTAssertEqual(object["name"] as? String, "Battery")
    XCTAssertEqual(object["origin"] as? String, "config")
    XCTAssertEqual(object["state"] as? String, "warning")
    XCTAssertEqual(object["value"] as? Double, 18)
    XCTAssertEqual(object["direction"] as? String, "below")
    XCTAssertEqual(object["interval_s"] as? Double, 60)
    XCTAssertEqual(object["expression"] as? String, "#{flash.plugin.sysinfo.power_percent}%%")
    XCTAssertNotNil(object["last_alert_ms"] as? Int64)
    let data = try JSONSerialization.data(withJSONObject: ["monitors": [object]])
    XCTAssertFalse(data.isEmpty)
    let unknown = MonitorSnapshot(
      id: "disk", spec: StatusMonitorSpec(value: .init(template: "x"), warning: 1),
      tracker: MonitorTracker(sinceMs: 5)
    ).jsonObject
    XCTAssertTrue(unknown["value"] is NSNull)
    XCTAssertTrue(unknown["error"] is NSNull)
    XCTAssertTrue(unknown["last_alert_ms"] is NSNull)
    XCTAssertEqual(unknown["since_ms"] as? Int64, 5)
  }

  func testTheMonitorsPageAndItsCommand() {
    XCTAssertEqual(DebugServer.Page(path: "/monitors"), .monitors)
    XCTAssertEqual(DebugServer.Page.monitors.path, "/monitors")
    XCTAssertNil(DebugServer.Page(path: "/monitors/battery"))
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "monitors", "show"])?.command, .showMonitors)
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "monitors", "show"])?.command?.diagnosticDescription,
      "flash monitors show")
    XCTAssertNil(parseMappingCommand(argv: ["flash", "monitors", "show", "--name=x"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "monitors_show"]))
    XCTAssertEqual(DebugServer.Page(path: "/docs/monitors"), .docs(page: "monitors"))
  }

  func testAMonitorAlertIsTheOneAlertAndOutlivesTeardown() throws {
    _ = NSApplication.shared
    let panel = OverlayPanel()
    defer {
      panel.dismissAlert()
      panel.orderOut(nil)
    }
    panel.displayAlert(
      StatusAlert(title: "Startup disk almost full", value: "93%", style: .warning))
    let toast = try XCTUnwrap(panel.toast)
    XCTAssertTrue(toast.outlivesTeardown, "a mode change or app switch leaves it up")
    XCTAssertEqual(toast.layer.sublayers?.count, 2, "the message over the value")
    panel.hide()
    XCTAssertNotNil(panel.toast)
  }

  func testAConfirmationKeepsItsQuestionAndTheMonitorAlertFollowsIt() throws {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.overlay = OverlayPanel()
    defer {
      delegate.overlay.dismissAlert()
      delegate.overlay.orderOut(nil)
    }
    delegate.hintSession.phase = .confirming(.init(prompt: "Close?", command: .tabClose))
    delegate.overlay.displayAlert(.confirmation("Close?"))
    let alert = StatusAlert(title: "Battery low", value: "9%", style: .error)
    delegate.presentMonitorAlert(alert)
    XCTAssertEqual(delegate.pendingMonitorAlert, alert)
    XCTAssertFalse(try XCTUnwrap(delegate.overlay.toast).outlivesTeardown, "the question stays")
    delegate.clearHintSessionState()
    XCTAssertNil(delegate.pendingMonitorAlert)
    XCTAssertTrue(try XCTUnwrap(delegate.overlay.toast).outlivesTeardown, "then the alert shows")
  }

  func testWarningsAndErrorsStayUpLongEnoughToRead() {
    XCTAssertEqual(
      OverlayPanel.alertDurationMs(.standard, style: .warning),
      OverlayPanel.alertDurationMs(.standard, style: .error))
    XCTAssertTrue(OverlayPanel.AlertStyle.warning.outlivesTeardown)
  }
}
