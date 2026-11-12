import Carbon.HIToolbox
import FlashCore
import XCTest

@testable import flash

/// The process model, its status values and the sampler that keeps them only
/// while a surface shows them.
final class ProcessStatusTests: XCTestCase {
  private func process(_ pid: pid_t, _ name: String, cpu: Double = 0, bytes: UInt64 = 0)
    -> ProcessTable.Process
  {
    ProcessTable.Process(pid: pid, name: name, cpuPercent: cpu, residentBytes: bytes)
  }

  // MARK: - Top tables

  func testTheCPUTableAlignsValuesAndTruncatesLongNames() {
    let processes = [
      process(10, "WindowServer", cpu: 12.34),
      process(11, "a-very-long-process-name", cpu: 3),
      process(12, "kernel_task", cpu: 142),
      process(13, "idle"),
    ]
    XCTAssertEqual(
      ProcessStatusFormat.topTable(.topCPU, processes: processes, count: 3),
      """
      kernel_task      142.0%
      WindowServer      12.3%
      a-very-long-pr…    3.0%
      """)
  }

  func testTheMemoryTableRanksResidentBytesAndBreaksTiesByName() {
    let processes = [
      process(1, "beta", bytes: 921_600),
      process(2, "Xcode", bytes: 432_013_312),
      process(3, "firefox", bytes: 1_610_612_736),
      process(4, "alpha", bytes: 921_600),
    ]
    XCTAssertEqual(
      ProcessStatusFormat.topTable(.topMemory, processes: processes, count: 5),
      """
      firefox           1.5 GiB
      Xcode             412 MiB
      alpha             900 KiB
      beta              900 KiB
      """)
  }

  func testAnOutlierValueWidensTheValueColumnForEveryRow() {
    let processes = [process(1, "wide", cpu: 2345.6), process(2, "idle")]
    XCTAssertEqual(
      ProcessStatusFormat.topTable(.topCPU, processes: processes, count: 5),
      "wide             2345.6%\nidle                0.0%")
  }

  func testTheRowCountIsClampedToOneThroughTwenty() {
    let processes = (1...25).map { process(pid_t($0), "p\($0)", cpu: Double($0)) }
    func rows(_ count: Int, _ list: [ProcessTable.Process] = processes) -> Int {
      ProcessStatusFormat.topTable(.topCPU, processes: list, count: count)
        .split(separator: "\n").count
    }
    XCTAssertEqual(rows(5), 5)
    XCTAssertEqual(rows(20), 20)
    XCTAssertEqual(rows(50), 20)
    XCTAssertEqual(rows(0), 1)
    XCTAssertEqual(rows(5, Array(processes.prefix(2))), 2)
    XCTAssertEqual(ProcessStatusFormat.topTable(.topCPU, processes: [], count: 5), "")
    XCTAssertEqual(ProcessStatusFormat.topTable(.topMemory, processes: [], count: 5), "")
  }

  func testExternalNamesCannotOpenMarkupOrBreakRows() {
    XCTAssertEqual(
      ProcessStatusFormat.topTable(.topCPU, processes: [process(1, "a#b")], count: 5),
      "a##b                0.0%")
    XCTAssertEqual(
      ProcessStatusFormat.topTable(.topCPU, processes: [process(1, "bad\nname")], count: 5),
      "bad?name           0.0%")
    XCTAssertEqual(
      ProcessStatusFormat.topTable(.topCPU, processes: [process(77, "  ")], count: 5),
      "[77]               0.0%")
  }

  // MARK: - Focused app details

  func testFocusedAppDetailsFormatLiveAndLifetimeFigures() {
    let app = FocusedProcess(pid: 4242, bundleID: "org.mozilla.firefox")
    let tree = ProcessTable.Tree(
      pid: 4242, name: "firefox", cpuPercent: 12.5,
      residentBytes: ProcessTable.physicalMemory / 16, processCount: 9, threadCount: 42,
      socketCount: 7, uptimeSeconds: 7_384, diskReadBytes: 536_870_912,
      diskWriteBytes: 67_108_864)
    let memory = ProcessStatusFormat.bytesIEC(ProcessTable.physicalMemory / 16)
    XCTAssertEqual(
      ProcessStatusFormat.focusedDetails(app, tree),
      """
      #[bold]firefox#[nobold]
      Bundle        org.mozilla.firefox
      PID           4242

      #[bold]Resources · app + descendants#[nobold]
      CPU           12.5% · 100% = 1 core
      Memory        \(memory) (6.2% of RAM)
      Processes     9 · 42 threads
      Sockets       7
      Running       2h 3m · main process
      Disk read     512 MiB cumulative
      Disk written  64 MiB cumulative
      """)
  }

  func testFocusedIdentityCannotInjectExtraRowsOrTerminalControls() {
    let text = ProcessStatusFormat.focusedPlaceholder(
      FocusedProcess(pid: 7, bundleID: "com.example.#[bold]\n\u{1b}[31m"),
      ProcessStatusFormat.unavailable)
    XCTAssertEqual(
      text, "Bundle        com.example.##[bold]??[31m\nPID           7\nMetrics unavailable")
  }

  func testFocusedDetailsKeepApplicationMetadataLiteralAndRankOnlyFiveHelpers() {
    let app = FocusedProcess(pid: 42, bundleID: "com.example.Editor")
    let tree = ProcessTable.Tree(
      pid: 42, name: "editor", cpuPercent: 215, residentBytes: 1024, processCount: 7,
      threadCount: 12, socketCount: 3, uptimeSeconds: 60, diskReadBytes: 4, diskWriteBytes: 5,
      descendants: [
        process(9, "slow", cpu: 1),
        process(8, "busy", cpu: 30),
        process(7, "tie-less-memory", cpu: 20, bytes: 1),
        process(6, "tie-low-pid", cpu: 20, bytes: 3),
        process(5, "zero", cpu: 0),
        process(10, "tie-high-pid", cpu: 20, bytes: 3),
      ])
    let text = ProcessStatusFormat.focusedDetails(
      app, tree,
      metadata: .init(
        name: "Editor #[bold]\nTitle", version: "2.1 (42)",
        bundlePath: "/Applications/Editor.app",
        executablePath: "/Applications/Editor.app/Contents/MacOS/editor"))
    XCTAssertTrue(text.hasPrefix("#[bold]Editor ##[bold]?Title#[nobold]\nVersion       2.1 (42)"))
    XCTAssertTrue(text.contains("CPU           215.0% · 100% = 1 core"))
    XCTAssertTrue(text.contains("#[bold]Busiest helpers · 5 of 6#[nobold]"))
    let rows = text.components(separatedBy: "\n").filter {
      ["busy", "tie-low-pid", "tie-high-pid", "tie-less-memory", "slow", "zero"].contains(
        $0.components(separatedBy: " ")[0])
    }
    XCTAssertEqual(
      rows.map { $0.split(separator: " ").first.map(String.init) },
      ["busy", "tie-low-pid", "tie-high-pid", "tie-less-memory", "slow"])
    XCTAssertEqual(rows.first?.contains("8    30.0%"), true)
    XCTAssertTrue(text.contains("Bundle path   /Applications/Editor.app"))
    XCTAssertTrue(text.contains("Executable    /Applications/Editor.app/Contents/MacOS/editor"))
    let rendered = FlashStatusBarTemplateEngine.render(
      template: .init(template: "#{flash.focused_app_details}"), context: .init(),
      dynamicValues: [ProcessStatusValue.focusedAppDetails.rawValue: text]
    ).document.runs
    XCTAssertTrue(rendered.map(\.text).joined().contains("Editor #[bold]?Title"))
    XCTAssertEqual(rendered.first { $0.text.contains("Editor #[bold]?Title") }?.bold, true)
    XCTAssertEqual(rendered.first { $0.text.contains("Version") }?.bold, false)
  }

  func testFocusedMetadataCacheDoesNotReuseARecycledPID() {
    var cache = FocusedProcessMetadataCache()
    let app = FocusedProcess(pid: 42, bundleID: "com.example.Editor")
    var reads = 0
    func read(_ app: FocusedProcess) -> FocusedProcessMetadata {
      reads += 1
      return .init(name: "App \(reads)")
    }
    XCTAssertEqual(cache.read(app, startAbstime: 100, using: read).name, "App 1")
    XCTAssertEqual(cache.read(app, startAbstime: 100, using: read).name, "App 1")
    XCTAssertEqual(reads, 1, "ordinary metric refreshes reuse application metadata")
    XCTAssertEqual(cache.read(app, startAbstime: 200, using: read).name, "App 2")
    XCTAssertEqual(
      cache.read(
        FocusedProcess(pid: 42, bundleID: "com.example.Other"), startAbstime: 200, using: read
      ).name,
      "App 3")
    cache = .init()
    XCTAssertEqual(cache.read(app, startAbstime: 200, using: read).name, "App 4")
  }

  func testTheFocusedPlaceholderNeverShowsAnotherAppsFiguresOrOpensMarkup() {
    XCTAssertEqual(
      ProcessStatusFormat.focusedPlaceholder(
        FocusedProcess(pid: 99, bundleID: "com.example.Editor"), ProcessStatusFormat.collecting),
      "Bundle        com.example.Editor\nPID           99\nCollecting metrics…")
    XCTAssertEqual(
      ProcessStatusFormat.focusedPlaceholder(
        FocusedProcess(pid: 7, bundleID: "com.example.#[dev]"), ProcessStatusFormat.unavailable),
      "Bundle        com.example.##[dev]\nPID           7\nMetrics unavailable")
    XCTAssertEqual(
      ProcessStatusFormat.focusedPlaceholder(
        FocusedProcess(pid: 7, bundleID: " "), ProcessStatusFormat.unavailable),
      "Bundle        Unavailable\nPID           7\nMetrics unavailable")
  }

  func testUnitsMatchTheStatusLanguageHelpers() {
    XCTAssertEqual(ProcessStatusFormat.bytesIEC(0), "0 B")
    XCTAssertEqual(ProcessStatusFormat.bytesIEC(1023), "1023 B")
    XCTAssertEqual(ProcessStatusFormat.bytesIEC(921_600), "900 KiB")
    XCTAssertEqual(ProcessStatusFormat.bytesIEC(1_610_612_736), "1.5 GiB")
    XCTAssertEqual(ProcessStatusFormat.uptime(42), "42s")
    XCTAssertEqual(ProcessStatusFormat.uptime(300), "5m")
    XCTAssertEqual(ProcessStatusFormat.uptime(7_384), "2h 3m")
    XCTAssertEqual(ProcessStatusFormat.uptime(93_600), "1d 2h")
  }

  func testTopCountIsAStatusBarSettingFromOneToTwenty() {
    XCTAssertEqual(Config().statusBar.topCount, 5)
    XCTAssertEqual(ConfigLoader.parse("[statusbar]\ntop_count = 12").statusBar.topCount, 12)
    for invalid in ["0", "21", "2.5", "\"5\"", "true"] {
      let config = ConfigLoader.parse("[statusbar]\ntop_count = \(invalid)")
      XCTAssertEqual(config.statusBar.topCount, 5, invalid)
      XCTAssertTrue(
        config.loadingDiagnostics.contains { $0.logMessage.contains("statusbar.top_count") },
        invalid)
    }
  }

  // MARK: - Observation

  func testCadencesArmOnlyWhileTheirValuesAreObserved() {
    var observation = ProcessStatusObservation()
    typealias Change = ProcessStatusObservation.Change

    XCTAssertEqual(
      observation.update([.focusedAppDetails]),
      Change(focused: .arm, sampleFocusedNow: true))
    XCTAssertEqual(
      observation.update([.focusedAppDetails, .topCPU]), Change(top: .arm, sampleTopNow: true))
    XCTAssertEqual(observation.update([.topCPU, .focusedAppDetails]), Change())
    // A second table keeps the cadence and is sampled at once.
    XCTAssertEqual(
      observation.update([.topCPU, .topMemory]),
      Change(focused: .disarm, sampleTopNow: true, cleared: [.focusedAppDetails]))
    XCTAssertEqual(observation.update([.topMemory]), Change(cleared: [.topCPU]))
    XCTAssertEqual(observation.update([]), Change(top: .disarm, cleared: [.topMemory]))
    XCTAssertEqual(observation.update([]), Change())
    XCTAssertEqual(observation.update([.topMemory]).top, .arm)
  }

  // MARK: - Sampler

  private final class Published {
    private let lock = NSLock()
    private var values: [[ProcessStatusValue: String?]] = []
    func append(_ value: [ProcessStatusValue: String?]) {
      lock.lock()
      values.append(value)
      lock.unlock()
    }
    var all: [[ProcessStatusValue: String?]] {
      lock.lock()
      defer { lock.unlock() }
      return values
    }
  }

  private func registeredIDs(_ scheduler: PollScheduler) -> [String] {
    let done = expectation(description: "registered ids")
    var ids: [String] = []
    scheduler.registeredIDs {
      ids = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
    return ids
  }

  /// A frozen clock: registrations are kept, none ever comes due.
  private func frozenScheduler() -> PollScheduler { PollScheduler(clock: { 0 }) }

  func testTheSamplerReadsAndRegistersOnlyWhileAValueIsObserved() {
    let scheduler = frozenScheduler()
    let published = Published()
    var reads = 0
    let sampler = ProcessStatusSampler(
      scheduler: scheduler,
      readProcesses: {
        reads += 1
        return [ProcessTable.Process(pid: 2, name: "firefox", cpuPercent: 40, residentBytes: 9)]
      },
      readTree: { _ in nil }, publish: published.append)
    sampler.setTopCount(2)
    sampler.drain()
    XCTAssertEqual(reads, 0, "nothing is read before a surface shows a value")
    XCTAssertEqual(registeredIDs(scheduler), [])

    sampler.observe([.topCPU])
    sampler.drain()
    XCTAssertEqual(reads, 1, "a newly observed table is sampled at once")
    XCTAssertEqual(registeredIDs(scheduler), [ProcessStatusSampler.topPollID])
    XCTAssertEqual(published.all, [[.topCPU: "firefox           40.0%"]])

    sampler.observe([])
    sampler.drain()
    XCTAssertEqual(registeredIDs(scheduler), [])
    XCTAssertEqual(published.all.last, [.topCPU: String?.none], "an unobserved table clears")
  }

  func testTheFocusedAppShowsItsPlaceholderThenItsOwnFigures() {
    let scheduler = frozenScheduler()
    let published = Published()
    let tree = ProcessTable.Tree(
      pid: 42, name: "editor", cpuPercent: 2.5, residentBytes: 1024, processCount: 1,
      threadCount: 4, socketCount: 0, uptimeSeconds: 60, diskReadBytes: 0, diskWriteBytes: 0)
    var treeReads: [pid_t] = []
    var metadataReads = 0
    let sampler = ProcessStatusSampler(
      scheduler: scheduler, readProcesses: { [] },
      readTree: { pid in
        treeReads.append(pid)
        return pid == 42 ? tree : nil
      },
      readMetadata: { _ in
        XCTAssertFalse(Thread.isMainThread)
        metadataReads += 1
        return .init()
      }, publish: published.append)
    let app = FocusedProcess(pid: 42, bundleID: "com.example.Editor")
    sampler.focusChanged(app)
    sampler.drain()
    XCTAssertEqual(treeReads, [], "focus alone reads nothing")
    XCTAssertEqual(metadataReads, 0, "focus alone reads no application metadata")

    sampler.observe([.focusedAppDetails])
    sampler.drain()
    XCTAssertEqual(treeReads, [42])
    XCTAssertEqual(metadataReads, 1)
    XCTAssertEqual(registeredIDs(scheduler), [ProcessStatusSampler.focusedPollID])
    XCTAssertEqual(
      published.all,
      [
        [.focusedAppDetails: ProcessStatusFormat.focusedPlaceholder(app, "Collecting metrics…")],
        [.focusedAppDetails: ProcessStatusFormat.focusedDetails(app, tree)],
      ])

    // Another app: its placeholder at once, its figures once focus settles.
    let other = FocusedProcess(pid: 7, bundleID: "com.example.Other")
    sampler.focusChanged(other)
    sampler.drain()
    XCTAssertEqual(
      published.all.last,
      [.focusedAppDetails: ProcessStatusFormat.focusedPlaceholder(other, "Collecting metrics…")])
    XCTAssertEqual(
      Set(registeredIDs(scheduler)),
      [ProcessStatusSampler.focusedPollID, ProcessStatusSampler.focusSettleID])

    sampler.observe([])
    sampler.drain()
    XCTAssertEqual(registeredIDs(scheduler), [], "unobserved: no cadence and no settle")
    XCTAssertEqual(published.all.last, [.focusedAppDetails: String?.none])
  }

  // MARK: - The status controller's report

  func testTheControllerReportsValuesItsBarPopupsAndWidgetsRead() {
    let queue = DispatchQueue(label: "process.status.tests")
    var reports: [Set<ProcessStatusValue>] = []
    let controller = FlashStatusBarController(
      template: .init(template: "bar"),
      popupTemplates: ["app": .init(template: "#{flash.focused_app_details}")],
      scheduler: PollScheduler(), queue: queue,
      processValuesObserver: { reports.append($0) })
    controller.updateWidgets([
      "top": StatusWidgetSpec(
        template: .init(template: "#{flash.top_cpu}"), intervalSeconds: 0, columns: 40)
    ])
    controller.start()
    queue.sync {}
    XCTAssertEqual(reports.last, [.focusedAppDetails, .topCPU])

    controller.updateProcessValues([.topCPU: "firefox  40.0%"])
    queue.sync {}
    XCTAssertEqual(
      queue.sync {
        controller.lastPublishedWidgets["top"]?.map {
          $0.runs.filter { !$0.isStyleBoundary }.map(\.text).joined()
        }
      }, ["firefox  40.0%"])

    controller.setWidgetVisible(name: "top", false)
    queue.sync {}
    XCTAssertEqual(reports.last, [.focusedAppDetails], "a covered widget stops observing")
    controller.setBar(enabled: false)
    queue.sync {}
    XCTAssertEqual(reports.last, [], "the bar's popups go with the bar")
    controller.stopAndWait()
  }

  // MARK: - Process table

  func testTheProcessTableListsThisProcessAndSumsATree() throws {
    let rows = ProcessTable.shared.processes(windowMs: 10)
    let mine = try XCTUnwrap(rows.first { $0.pid == getpid() })
    XCTAssertFalse(mine.name.isEmpty)
    XCTAssertEqual(ProcessTable.name(of: getpid()), mine.name)

    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["2"]
    try child.run()
    defer {
      if child.isRunning { child.terminate() }
      child.waitUntilExit()
    }
    let tree = try XCTUnwrap(ProcessTable.shared.tree(root: getpid(), windowMs: 10))
    XCTAssertEqual(tree.pid, getpid())
    XCTAssertGreaterThanOrEqual(tree.processCount, 2)
    XCTAssertGreaterThan(tree.threadCount, 0)
    XCTAssertGreaterThan(tree.residentBytes, 0)
    XCTAssertGreaterThan(tree.startAbstime, 0)
    XCTAssertTrue(
      tree.descendants.contains { $0.pid == child.processIdentifier && $0.name == "sleep" })
    XCTAssertFalse(tree.descendants.contains { $0.pid == getpid() })
  }

  func testTerminateRefusesLowPidsAndReportsTheOSReason() {
    let original = ProcessTable.signalSender
    defer { ProcessTable.signalSender = original }
    var signaled: [pid_t] = []
    ProcessTable.signalSender = { pid in
      signaled.append(pid)
      return 0
    }
    XCTAssertNil(ProcessTable.terminate(4321))
    XCTAssertEqual(ProcessTable.terminate(1), "refusing pid 1")
    XCTAssertEqual(ProcessTable.terminate(0), "refusing pid 0")
    XCTAssertEqual(signaled, [4321])
  }

  func testAKillAsksWithTheProcessNameAndRunsOnlyOnceConfirmed() {
    XCTAssertEqual(
      ProcessKill.step(pid: 42, name: "Safari", confirmed: false), .ask("Kill Safari (pid 42)?"))
    XCTAssertEqual(ProcessKill.step(pid: 42, name: "Safari", confirmed: true), .run)
    XCTAssertEqual(
      ProcessKill.step(pid: 42, name: nil, confirmed: true), .refuse("no process with pid 42"))
    XCTAssertEqual(
      ProcessKill.step(pid: 1, name: "launchd", confirmed: true), .refuse("refusing pid 1"))
  }

  // MARK: - Sources

  func testProcessRowsCarryThePidAsPayloadAndAlias() {
    let row = ProcessListSource.candidate(
      for: process(4242, "Safari", cpu: 12.5, bytes: ProcessTable.physicalMemory / 4))
    XCTAssertEqual(row.title, "Safari")
    XCTAssertEqual(row.source, "processes.processes")
    XCTAssertEqual(row.sourceID, "core.processes")
    XCTAssertEqual(row.kind, .plugin("process"))
    XCTAssertEqual(row.sourcePayload, "4242")
    XCTAssertEqual(row.searchAliases, "4242")
    XCTAssertEqual(row.subtitle, "pid 4242 · 12.5% CPU · 25.0% MEM")
  }

  func testPickingAProcessRowAsksToKillIt() {
    var performed: [URLCommand] = []
    let source = ProcessListSource(
      read: { [ProcessTable.Process(pid: 77, name: "zsh", cpuPercent: 1, residentBytes: 1)] },
      perform: { performed.append($0) })
    let listed = expectation(description: "rows")
    var rows: [Candidate] = []
    source.liveCandidates(
      matching: "", in: FlashSourceEnvironment(runningApplications: []), scope: .all
    ) {
      rows = $0
      listed.fulfill()
    }
    wait(for: [listed], timeout: 2)
    XCTAssertEqual(rows.map(\.title), ["zsh"])

    let resolved = expectation(description: "resolved")
    source.resolveCandidate(rows[0], in: FlashSourceEnvironment(runningApplications: [])) {
      XCTAssertTrue($0.didResolve)
      resolved.fulfill()
    }
    wait(for: [resolved], timeout: 2)
    XCTAssertEqual(performed, [.processKill(pid: 77)])
  }

  func testSystemRowsRunTheirCommands() throws {
    let rows = SystemActionSource.rows
    XCTAssertEqual(rows.count, SystemAction.allCases.count)
    XCTAssertTrue(rows.allSatisfy { $0.source == "system.actions" && $0.finishesCommand })
    let restart = try XCTUnwrap(rows.first { $0.sourcePayload == "system restart" })
    XCTAssertEqual(restart.title, "Restart Mac")
    XCTAssertEqual(restart.kind, .plugin("system_action"))
    XCTAssertTrue(restart.searchAliases.contains("reboot"))

    var performed: [URLCommand] = []
    let source = SystemActionSource(perform: { performed.append($0) })
    let resolved = expectation(description: "resolved")
    source.resolveCandidate(restart, in: FlashSourceEnvironment(runningApplications: [])) { _ in
      resolved.fulfill()
    }
    wait(for: [resolved], timeout: 2)
    XCTAssertEqual(performed, [.systemAction(.systemRestart)])
  }

  // MARK: - Commands

  func testSystemCommandsParseRoundTripAndAskOnlyForWhatNothingUndoes() {
    for action in SystemAction.allCases {
      let name = action.name
      let command = URLEventHandler.parse(topic: name.topic, action: name.action, args: [:])
      XCTAssertEqual(command, .systemAction(action), action.rawValue)
      XCTAssertEqual(command?.argv, ["flash", name.topic, name.action])
      XCTAssertNil(
        URLEventHandler.parse(topic: name.topic, action: name.action, args: ["now": "1"]))
    }
    let asking = SystemAction.allCases.filter { $0.step(confirmed: false) != .run }
    XCTAssertEqual(asking, [.systemRestart, .systemShutdown, .systemLogout, .trashEmpty])
    XCTAssertEqual(SystemAction.systemRestart.step(confirmed: false), .ask("Restart this Mac?"))
    XCTAssertTrue(SystemAction.allCases.allSatisfy { $0.step(confirmed: true) == .run })
  }

  func testProcessKillParsesAPidAboveOne() {
    XCTAssertEqual(
      URLEventHandler.parse(topic: "process", action: "kill", args: ["pid": "4242"]),
      .processKill(pid: 4242))
    XCTAssertEqual(
      URLCommand.processKill(pid: 4242).argv, ["flash", "process", "kill", "--pid=4242"])
    for pid in ["1", "0", "-3", "x", "99999999999"] {
      XCTAssertNil(URLEventHandler.parse(topic: "process", action: "kill", args: ["pid": pid]), pid)
    }
    XCTAssertNil(URLEventHandler.parse(topic: "process", action: "kill", args: [:]))
  }

  func testSystemActionsUseInProcessAPIsAndTheLockShortcut() throws {
    XCTAssertEqual(SystemAction.screenLock.execution, .lockScreenChord)
    let chord = try XCTUnwrap(HotkeySyntax.parse(hotkey: SystemActionExecution.lockScreenShortcut))
    XCTAssertEqual(chord.virtualKey, UInt32(kVK_ANSI_Q))
    XCTAssertEqual(chord.eventFlags, [.maskControl, .maskCommand])
    XCTAssertEqual(SystemAction.systemSleep.execution, .sleepSystem)
    XCTAssertEqual(SystemAction.displaySleep.execution, .sleepDisplays)
    XCTAssertEqual(SystemAction.screensaverStart.execution, .startScreensaver)
    XCTAssertEqual(
      SystemAction.trashEmpty.execution,
      .appleScript("tell application \"Finder\" to empty trash", timeout: 30))
    for action in [SystemAction.systemRestart, .systemShutdown, .systemLogout, .darkModeToggle] {
      guard case .appleScript(let source, _) = action.execution else {
        return XCTFail("\(action) is not an Apple Event")
      }
      XCTAssertTrue(source.hasPrefix("tell application \"System Events\""), source)
    }
  }
}
