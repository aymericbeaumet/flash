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
    var tasks: [Task] = []
    var controller: FlashStatusBarController!

    init(
      _ template: String, sources: [String: FlashStatusBarSourceDefinition] = [:],
      interval: TimeInterval = 0
    ) {
      controller = FlashStatusBarController(
        template: .init(template: template, sourceNames: Set(sources.keys)), sources: sources,
        refreshIntervalSeconds: interval, queue: queue, clock: { [unowned self] in now },
        makeJob: { [unowned self] invocation, _, line, completion in
          let task = Task(invocation, line: line, completion: completion)
          tasks.append(task)
          return task
        })
      controller.start()
      drain()
    }

    func drain() { queue.sync {} }
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
