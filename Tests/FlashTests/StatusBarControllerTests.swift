import FlashCore
import XCTest

@testable import flash

final class StatusBarControllerTests: XCTestCase {
  private final class Task: StatusCommandTask {
    let invocation: StatusCommandInvocation
    let line: (String) -> Void
    let completion: (Int32, String) -> Void
    var cancelled = false

    init(
      _ invocation: StatusCommandInvocation, line: @escaping (String) -> Void,
      completion: @escaping (Int32, String) -> Void
    ) {
      self.invocation = invocation
      self.line = line
      self.completion = completion
    }

    func cancel() { cancelled = true }
  }

  private final class Harness {
    let queue = DispatchQueue(label: "status.tests")
    var now: TimeInterval = 100
    /// Twenty seconds past a minute: a minute clock is 40 s away.
    var wall = Date(timeIntervalSince1970: 1_800_000_020)
    var tasks: [Task] = []
    var controller: FlashStatusBarController!

    var pluginStatuses: [PluginStatusBarInfo] = []

    init(
      _ template: String, sources: [String: FlashStatusBarSourceDefinition] = [:],
      interval: TimeInterval = 0, environment: FlashProcessEnvironment = .shared
    ) {
      controller = FlashStatusBarController(
        template: .init(template: template, sourceNames: Set(sources.keys)), sources: sources,
        refreshIntervalSeconds: interval,
        pluginStatusesProvider: { [unowned self] in pluginStatuses },
        scheduler: PollScheduler(), queue: queue, clock: { [unowned self] in now },
        wallClock: { [unowned self] in wall },
        makeJob: { [unowned self] invocation, _, line, completion in
          let task = Task(invocation, line: line, completion: completion)
          tasks.append(task)
          return task
        },
        environment: environment)
      controller.start()
      drain()
    }

    func drain() { queue.sync {} }
    func tick() { queue.sync { controller.tick() } }
    func update(
      _ template: String, sources: [String: FlashStatusBarSourceDefinition]? = nil,
      interval: TimeInterval? = nil
    ) {
      controller.updateTemplate(
        .init(template: template, sourceNames: Set(sources?.keys.map { $0 } ?? ["value"])),
        sources: sources, refreshIntervalSeconds: interval)
      drain()
    }
  }

  func testStoppingDropsEveryDeadlineAndARestartPlansAfresh() {
    // `%H:%M` needs the clock, so a running bar always has a next wake-up.
    let harness = Harness("%H:%M", interval: 60)
    XCTAssertEqual(harness.queue.sync { harness.controller.nextWakeup }, 140)

    harness.controller.stop()
    harness.drain()
    XCTAssertNil(harness.queue.sync { harness.controller.nextWakeup })
    // A template change while stopped evaluates, but schedules nothing.
    harness.update("%H:%M:%S", interval: 30)
    XCTAssertNil(harness.queue.sync { harness.controller.nextWakeup })

    harness.queue.sync {
      harness.now = 500
      harness.wall = Date(timeIntervalSince1970: 1_800_000_020.25)
    }
    harness.controller.start()
    harness.drain()
    XCTAssertEqual(harness.queue.sync { harness.controller.nextWakeup }, 500.75)
    harness.controller.stop()
  }

  /// The minute used to be re-read every `[statusbar] interval`, so it turned
  /// up to that many seconds late. It is read on the minute instead, and the
  /// interval (even 0, "run once") no longer decides it.
  func testAMinuteClockWakesOnTheMinuteNotEveryInterval() {
    for interval in [5.0, 0] {
      let harness = Harness("%H:%M", interval: interval)
      defer { harness.controller.stop() }
      XCTAssertEqual(harness.queue.sync { harness.controller.nextWakeup }, 140, "\(interval)")
      harness.queue.sync {
        harness.now = 140
        harness.wall = Date(timeIntervalSince1970: 1_800_000_060)
      }
      harness.tick()
      XCTAssertEqual(harness.queue.sync { harness.controller.nextWakeup }, 200, "\(interval)")
    }
  }

  /// A clock boundary and a rotation are the visible change itself, so they
  /// wake at `.high`; a job re-run or a throttled publish lands whenever its
  /// command finishes, so it keeps `.normal` slack — unless a tighter
  /// deadline would fall inside that slack and be dragged late with it.
  func testEachWakeupCarriesTheSlackItsKindTolerates() {
    typealias Controller = FlashStatusBarController
    let job = Controller.Deadline(at: 10, priority: .normal)
    let clock = Controller.Deadline(at: 10.05, priority: .high)
    XCTAssertNil(Controller.nextWakeup([]))
    XCTAssertNil(Controller.nextWakeup([Controller.Deadline(at: .infinity, priority: .high)]))
    XCTAssertEqual(Controller.nextWakeup([job]), job)
    XCTAssertEqual(
      Controller.nextWakeup([job, clock]), Controller.Deadline(at: 10, priority: .high),
      "a clock tick inside the job's slack tightens the shared wake-up")
    XCTAssertEqual(
      Controller.nextWakeup([job, Controller.Deadline(at: 10.5, priority: .high)]), job,
      "a later clock tick gets its own wake-up")
    XCTAssertEqual(
      Controller.nextWakeup([clock, Controller.Deadline(at: 10.06, priority: .normal)]), clock)
  }

  func testACalendarAloneWakesAtTheNextMinute() {
    let harness = Harness("#{flash.calendar}")
    defer { harness.controller.stop() }
    let wall = harness.queue.sync { harness.wall }
    let boundary = Calendar.current.dateInterval(of: .minute, for: wall)!.end
    XCTAssertEqual(
      harness.queue.sync { harness.controller.nextWakeup }!,
      100 + boundary.timeIntervalSince(wall), accuracy: 0.001)
  }

  func testADayEndsAtADaylightSavingTransitionInsideIt() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
    // 2026-03-08 00:30 local; the clocks spring forward at 02:00 (10:00 UTC).
    let date = Date(timeIntervalSince1970: 1_772_958_600)
    XCTAssertEqual(
      FlashStatusBarController.nextClockBoundary(after: date, resolution: .day, calendar: calendar),
      Date(timeIntervalSince1970: 1_772_964_000))
    XCTAssertEqual(
      FlashStatusBarController.nextClockBoundary(after: date, resolution: .minute),
      Date(timeIntervalSince1970: 1_772_958_660))
  }

  /// A clock set, time-zone change, new day or wake re-plans the next
  /// boundary from the wall clock as it now reads.
  func testAWallClockChangeReplansTheNextBoundary() {
    let harness = Harness("%H:%M")
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.queue.sync { harness.controller.nextWakeup }, 140)
    harness.queue.sync { harness.wall = Date(timeIntervalSince1970: 1_800_000_050) }
    harness.controller.clockDidChange(reason: "test")
    harness.drain()
    XCTAssertEqual(harness.queue.sync { harness.controller.nextWakeup }, 110)
  }

  /// A scroll over the run steps that carousel: the line shows at once and
  /// keeps a full cycle, so the clock does not push the reader off it. An
  /// unknown carousel does nothing.
  func testScrollingACarouselStepsItAndRestartsItsDwell() {
    let harness = Harness("#{flash.plugin.feed.summary}")
    defer { harness.controller.stop() }
    harness.queue.sync {
      harness.pluginStatuses = [
        PluginStatusBarInfo(
          id: "feed", state: "running", hasError: false,
          statusSegments: [
            "summary": .carousel(
              prefix: "NEWS ", lines: ["one", "two", "three"], cycleSeconds: 30)
          ])
      ]
    }
    harness.controller.refreshPluginSections()
    harness.drain()
    func text() -> String {
      harness.queue.sync {
        harness.controller.lastPublishedModel!.document.runs.map(\.text).joined()
      }
    }
    let key = StatusCycleKey.plugin("feed", segment: "summary")
    XCTAssertEqual(text(), "NEWS one")
    XCTAssertEqual(harness.queue.sync { harness.controller.nextWakeup }, 130)

    harness.queue.sync { harness.now = 110 }
    harness.controller.stepCycle(key: key, by: 1)
    harness.drain()
    XCTAssertEqual(text(), "NEWS two")
    XCTAssertEqual(
      harness.queue.sync { harness.controller.nextWakeup }, 140,
      "the hand-picked line keeps a full cycle")

    func backward() -> Bool? {
      harness.queue.sync {
        harness.controller.lastPublishedModel!.document.runs.first(where: \.cycle)?.cycleBackward
      }
    }
    XCTAssertEqual(backward(), false)

    // Backwards, wrapping past the first line: that line arrives from above.
    harness.controller.stepCycle(key: key, by: -2)
    harness.drain()
    XCTAssertEqual(text(), "NEWS three")
    XCTAssertEqual(backward(), true)

    for unknown in ["plugin:feed.missing", "source:none", "other"] {
      harness.controller.stepCycle(key: unknown, by: 1)
    }
    harness.drain()
    XCTAssertEqual(text(), "NEWS three")
    XCTAssertEqual(harness.queue.sync { harness.controller.nextWakeup }, 140)

    // The clock's rotation moves forward again.
    harness.queue.sync { harness.now = 140 }
    harness.tick()
    XCTAssertEqual(text(), "NEWS one")
    XCTAssertEqual(backward(), false)
  }

  /// A cycling source steps by the key its drawn run carries, whatever the
  /// source is called, and the step runs on the controller's queue: the
  /// scroll arrives on the main thread.
  func testScrollingACyclingSourceStepsItByTheKeyItsRunCarries() {
    let source = FlashStatusBarSourceDefinition(
      command: ["/bin/cycle"], intervalSeconds: 60, cycleIntervalSeconds: 30)
    let harness = Harness("#{flash.source.News}", sources: ["News": source])
    defer { harness.controller.stop() }
    harness.queue.sync { harness.tasks[0].completion(0, "one\ntwo\nthree") }
    func runs() -> [FlashStatusTextSegment] {
      harness.queue.sync { harness.controller.lastPublishedModel!.document.runs }
    }
    XCTAssertEqual(runs().map(\.text).joined(), "one")
    let key = runs().first(where: \.cycle)?.cycleKey ?? ""
    XCTAssertEqual(key, StatusCycleKey.source("News"))

    harness.controller.stepCycle(key: key, by: 1)
    harness.drain()
    XCTAssertEqual(runs().map(\.text).joined(), "two")
    harness.controller.stepCycle(key: key, by: -2)
    harness.drain()
    XCTAssertEqual(runs().map(\.text).joined(), "three")
  }

  func testPluginCarouselRotatesOnTheHostClockAndKeepsTheVisibleLineAcrossRefreshes() {
    let harness = Harness("#{flash.plugin.feed.summary}")
    defer { harness.controller.stop() }
    func publish(_ lines: [String]) {
      harness.queue.sync {
        harness.pluginStatuses = [
          PluginStatusBarInfo(
            id: "feed", state: "running", hasError: false,
            statusSegments: [
              "summary": .carousel(prefix: "NEWS ", lines: lines, cycleSeconds: 30)
            ])
        ]
      }
      harness.controller.refreshPluginSections()
      harness.drain()
    }
    func text() -> String {
      harness.queue.sync {
        harness.controller.lastPublishedModel!.document.runs.map(\.text).joined()
      }
    }
    publish(["one", "two"])
    XCTAssertEqual(text(), "NEWS one")
    XCTAssertTrue(
      harness.queue.sync {
        harness.controller.lastPublishedModel!.document.runs.contains {
          $0.cycle && $0.text == "one"
        }
      })
    XCTAssertEqual(harness.queue.sync { harness.controller.nextWakeup }, 130)
    // A republish before the deadline neither rotates nor resets the cadence.
    harness.queue.sync { harness.now = 110 }
    publish(["two", "one", "three"])
    XCTAssertEqual(text(), "NEWS one")
    XCTAssertEqual(harness.queue.sync { harness.controller.nextWakeup }, 130)
    // The scheduled rotation advances through the refreshed playlist.
    harness.queue.sync { harness.now = 131 }
    harness.controller.refreshPluginSections()
    harness.drain()
    XCTAssertEqual(text(), "NEWS one")
    harness.tick()
    XCTAssertEqual(text(), "NEWS three")
    // Dropping the segment forgets its rotation state.
    harness.queue.sync { harness.pluginStatuses = [] }
    harness.controller.refreshPluginSections()
    harness.drain()
    XCTAssertEqual(text(), "")
    XCTAssertNil(harness.queue.sync { harness.controller.nextWakeup })
  }

  /// A carousel no visible surface reads rotates nothing anyone sees, so it
  /// holds no wake-up; referencing it again arms its rotation.
  func testOnlyCarouselsAVisibleSurfaceReadsHoldWakeups() {
    let harness = Harness("#{flash.plugin.feed.label}")
    defer { harness.controller.stop() }
    harness.queue.sync {
      harness.pluginStatuses = [
        PluginStatusBarInfo(
          id: "feed", state: "running", hasError: false,
          statusSegments: [
            "summary": .carousel(prefix: "", lines: ["one", "two"], cycleSeconds: 30),
            "label": .text("NEWS"),
          ])
      ]
    }
    harness.controller.refreshPluginSections()
    harness.drain()
    XCTAssertNil(harness.queue.sync { harness.controller.nextWakeup })
    harness.update("#{flash.plugin.feed.summary}")
    XCTAssertEqual(harness.queue.sync { harness.controller.nextWakeup }, 130)
    harness.update("#{flash.plugin.feed.label}")
    XCTAssertNil(harness.queue.sync { harness.controller.nextWakeup })
  }

  /// A source job inherits the environment in effect when it spawns. While
  /// the login shell is still being read the bar renders without jobs; the
  /// moment it resolves, every due job starts with the resolved `PATH`.
  func testSourceJobsWaitForTheLoginEnvironment() {
    let release = DispatchSemaphore(value: 0)
    let environment = FlashProcessEnvironment(seed: ["PATH": "/usr/bin:/bin"]) { _, _ in
      release.wait()
      return ["PATH": "/flash/resolved:/usr/bin:/bin"]
    }
    environment.refresh()
    let source = FlashStatusBarSourceDefinition(command: ["/bin/value"], intervalSeconds: 60)
    let harness = Harness(
      "#{flash.source.value}", sources: ["value": source], environment: environment)
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.tasks.count, 0, "no job before the environment resolved")
    XCTAssertNotNil(harness.queue.sync { harness.controller.lastPublishedModel })
    release.signal()
    let started = expectation(
      for: NSPredicate { _, _ in harness.tasks.count == 1 }, evaluatedWith: nil)
    wait(for: [started], timeout: 5)
    harness.drain()
    XCTAssertEqual(harness.tasks[0].invocation.environment["PATH"], "/flash/resolved:/usr/bin:/bin")
  }

  func testUnchangedReloadPreservesRunningSourceAndCompletion() {
    let source = FlashStatusBarSourceDefinition(command: ["/bin/value"], intervalSeconds: 60)
    let harness = Harness("#{flash.source.value}", sources: ["value": source])
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.tasks.count, 1)
    harness.update("value: #{flash.source.value}", sources: ["value": source])
    XCTAssertEqual(harness.tasks.count, 1)
    XCTAssertFalse(harness.tasks[0].cancelled)
    harness.queue.sync { harness.tasks[0].completion(0, "retained") }
    XCTAssertTrue(
      harness.queue.sync {
        harness.controller.lastPublishedModel!.document.runs.map(\.text).joined().contains(
          "retained")
      })
  }

  private func pushed(
    _ harness: Harness, _ name: String, _ value: String?, file: StaticString = #filePath,
    line: UInt = #line
  ) -> Bool {
    let done = expectation(description: "push \(name)")
    var accepted = false
    harness.controller.push(source: name, value: value) {
      accepted = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    harness.drain()
    return accepted
  }

  private func barText(_ harness: Harness) -> String {
    harness.queue.sync { harness.controller.lastPublishedModel!.document.runs.map(\.text).joined() }
  }

  /// `status set`: a source without a command runs nothing and shows what is
  /// pushed, feeding its history like a run's output; `status clear` empties it.
  func testAPushedSourceShowsWhatIsPushedAndRunsNothing() {
    let source = FlashStatusBarSourceDefinition(command: [], historyLength: 3)
    let harness = Harness(
      "ws #{flash.source.ws} [#{flash.history.ws}]", sources: ["ws": source])
    defer { harness.controller.stop() }
    XCTAssertTrue(source.isPushed)
    XCTAssertEqual(harness.tasks.count, 0)
    for value in ["1", "2", "3", "4"] { XCTAssertTrue(pushed(harness, "ws", value)) }
    XCTAssertTrue(barText(harness).contains("ws 4 [2 3 4]"), barText(harness))
    XCTAssertEqual(harness.tasks.count, 0, "a pushed source never spawns")
    XCTAssertTrue(pushed(harness, "ws", nil))
    XCTAssertFalse(barText(harness).contains("ws 4"), barText(harness))
    XCTAssertFalse(pushed(harness, "missing", "x"))
  }

  /// A source with a command also takes a push between its runs; the next
  /// run replaces it.
  func testAPushLandsBetweenARunningSourcesRuns() {
    let source = FlashStatusBarSourceDefinition(command: ["/bin/value"], intervalSeconds: 60)
    let harness = Harness("#{flash.source.value}", sources: ["value": source])
    defer { harness.controller.stop() }
    harness.queue.sync { harness.tasks[0].completion(0, "polled") }
    XCTAssertTrue(pushed(harness, "value", "pushed"))
    XCTAssertTrue(barText(harness).contains("pushed"))
    harness.queue.sync { harness.now += 61 }
    harness.controller.refreshPluginSections()
    harness.drain()
    harness.queue.sync { harness.tasks.last!.completion(0, "polled again") }
    XCTAssertTrue(barText(harness).contains("polled again"))
  }

  func testReplacementRejectsOldCompletionAndRetainsLastGoodValueOnFailure() {
    let old = FlashStatusBarSourceDefinition(command: ["/bin/old"], intervalSeconds: 60)
    let new = FlashStatusBarSourceDefinition(command: ["/bin/new"], intervalSeconds: 60)
    let harness = Harness("#{flash.source.value}", sources: ["value": old])
    defer { harness.controller.stop() }
    harness.update("#{flash.source.value}", sources: ["value": new])
    XCTAssertTrue(harness.tasks[0].cancelled)
    XCTAssertEqual(harness.tasks.count, 2)
    harness.queue.sync {
      harness.tasks[0].completion(0, "stale")
      harness.tasks[1].completion(0, "current")
      harness.now += 61
    }
    harness.controller.refreshPluginSections()
    harness.drain()
    XCTAssertEqual(harness.tasks.count, 3)
    harness.queue.sync { harness.tasks[2].completion(1, "failure") }
    let text = harness.queue.sync {
      harness.controller.lastPublishedModel!.document.runs.map(\.text).joined()
    }
    XCTAssertTrue(text.contains("current"))
    XCTAssertFalse(text.contains("stale"))
    XCTAssertFalse(text.contains("failure"))
  }

  func testInactiveCyclesAndShellJobsHaveNoWakeupsAndShellCacheIsPruned() {
    let source = FlashStatusBarSourceDefinition(
      command: ["/bin/cycle"], intervalSeconds: 60,
      cycleIntervalSeconds: 10)
    let harness = Harness("#{flash.source.value} #(echo active)", sources: ["value": source])
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.tasks.count, 2)
    harness.queue.sync {
      harness.tasks[0].completion(0, "one\ntwo")
      harness.tasks[1].line("first")
      harness.tasks[1].line("second")
    }
    XCTAssertNotNil(harness.queue.sync { harness.controller.nextWakeup })
    harness.update("hidden")
    XCTAssertTrue(harness.tasks[1].cancelled)
    XCTAssertNil(harness.queue.sync { harness.controller.nextWakeup })
    harness.queue.sync { harness.tasks[1].line("stale") }
    harness.update("#(echo active)")
    XCTAssertEqual(harness.tasks.count, 3)
    XCTAssertFalse(
      harness.queue.sync {
        harness.controller.lastPublishedModel!.document.runs.map(\.text).joined().contains("stale")
      })
  }

  func testCadenceChangePreservesRunningShellAndEnablesLaterRefresh() {
    let harness = Harness("#(echo active)")
    defer { harness.controller.stop() }
    harness.update("#(echo active)", interval: 5)
    XCTAssertEqual(harness.tasks.count, 1)
    XCTAssertFalse(harness.tasks[0].cancelled)
    harness.queue.sync {
      harness.tasks[0].line("value")
      harness.tasks[0].completion(0, "value")
    }
    XCTAssertEqual(harness.queue.sync { harness.controller.nextWakeup }, 105)
    harness.queue.sync { harness.now = 106 }
    harness.controller.refreshPluginSections()
    harness.drain()
    XCTAssertEqual(harness.tasks.count, 2)
  }

  func testScheduleRejectsStaleAndDuplicateCompletions() {
    var schedule = StatusJobSchedule()
    XCTAssertTrue(schedule.begin(token: 1, now: 10, interval: 5))
    XCTAssertFalse(schedule.begin(token: 2, now: 20, interval: 5))
    XCTAssertFalse(schedule.complete(2))
    XCTAssertTrue(schedule.complete(1))
    XCTAssertTrue(schedule.begin(token: 2, now: 20, interval: 5))
    XCTAssertFalse(schedule.complete(1))
    XCTAssertTrue(schedule.owns(2))
    schedule.reschedule(now: 21, interval: 0)
    XCTAssertTrue(schedule.complete(2))
    XCTAssertEqual(schedule.dueAt, .infinity)
    XCTAssertFalse(schedule.complete(2))
  }
}
