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
      interval: TimeInterval = 0
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
        })
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

  func testACalendarAloneWakesAtTheNextLocalMidnight() {
    let harness = Harness("#{flash.calendar}")
    defer { harness.controller.stop() }
    let wall = harness.queue.sync { harness.wall }
    let midnight = Calendar.current.dateInterval(of: .day, for: wall)!.end
    let boundary = min(
      midnight, TimeZone.current.nextDaylightSavingTimeTransition(after: wall) ?? midnight)
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
