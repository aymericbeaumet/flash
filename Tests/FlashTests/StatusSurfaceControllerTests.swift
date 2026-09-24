import XCTest

@testable import flash

/// The bar and desktop widgets as surfaces of one controller: one source and
/// job registry, one clock deadline, each surface memoized on its own.
final class StatusSurfaceControllerTests: XCTestCase {
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
    let queue = DispatchQueue(label: "status.surface.tests")
    var now: TimeInterval = 100
    var tasks: [Task] = []
    var controller: FlashStatusBarController!

    init(
      bar: String?, widgets: [String: StatusWidgetSpec] = [:],
      sources: [String: FlashStatusBarSourceDefinition] = [:], interval: TimeInterval = 0
    ) {
      controller = FlashStatusBarController(
        template: .init(template: bar ?? ""), sources: sources,
        refreshIntervalSeconds: interval,
        scheduler: PollScheduler(), queue: queue, clock: { [unowned self] in now },
        makeJob: { [unowned self] invocation, _, line, completion in
          let task = Task(invocation, line: line, completion: completion)
          tasks.append(task)
          return task
        })
      if bar == nil { controller.setBar(enabled: false) }
      controller.updateWidgets(widgets)
      controller.start()
      drain()
    }

    func drain() { queue.sync {} }
    func tick() { queue.sync { controller.tick() } }
    func refresh() {
      controller.refreshPluginSections()
      drain()
    }
    var nextWakeup: TimeInterval? { queue.sync { controller.nextWakeup } }
    var barText: String? {
      queue.sync { controller.lastPublishedModel?.document.runs.map(\.text).joined() }
    }
    func widgetText(_ name: String) -> [String]? {
      queue.sync {
        controller.lastPublishedWidgets[name]?.map {
          $0.runs.filter { !$0.isStyleBoundary }.map(\.text).joined()
        }
      }
    }
    func evaluations(_ surface: String) -> Int {
      queue.sync { controller.surfaceEvaluations[surface, default: 0] }
    }
    func running(_ command: String) -> [Task] {
      tasks.filter { !$0.cancelled && $0.invocation.argv.last == command }
    }
  }

  private func widget(_ template: String, interval: TimeInterval = 0, columns: Int = 40)
    -> StatusWidgetSpec
  {
    StatusWidgetSpec(
      template: .init(template: template), intervalSeconds: interval, columns: columns)
  }

  func testASourceSharedByTheBarAndAWidgetRunsOnce() {
    let source = FlashStatusBarSourceDefinition(command: ["/bin/value"], intervalSeconds: 60)
    let harness = Harness(
      bar: "bar #{flash.source.value}", widgets: ["w": widget("widget #{flash.source.value}")],
      sources: ["value": source])
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.tasks.count, 1)
    harness.queue.sync { harness.tasks[0].completion(0, "42") }
    XCTAssertEqual(harness.barText, "bar 42")
    XCTAssertEqual(harness.widgetText("w"), ["widget 42"])
  }

  func testAWidgetOnlyConfigurationRunsItsSourcesWithTheBarDisabled() {
    let source = FlashStatusBarSourceDefinition(command: ["/bin/value"], intervalSeconds: 60)
    let template = "#{flash.widget.name}:#{flash.widget.columns}\n#{flash.source.value}"
    let harness = Harness(bar: nil, widgets: ["w": widget(template)], sources: ["value": source])
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.tasks.count, 1)
    XCTAssertNil(harness.barText, "a disabled bar publishes nothing")
    harness.queue.sync { harness.tasks[0].completion(0, "7") }
    XCTAssertEqual(harness.widgetText("w"), ["w:40", "7"])
    XCTAssertEqual(harness.evaluations("bar"), 0)
    // Removing the last widget releases the source.
    harness.queue.sync { harness.now = 200 }
    harness.controller.updateWidgets([:])
    harness.drain()
    harness.refresh()
    XCTAssertEqual(harness.tasks.count, 1)
    XCTAssertNil(harness.widgetText("w"))
    XCTAssertNil(harness.nextWakeup)
  }

  func testAHiddenWidgetReleasesItsJobsAndDeadlinesUntilShownAgain() {
    let source = FlashStatusBarSourceDefinition(command: ["/bin/value"], intervalSeconds: 60)
    let harness = Harness(
      bar: "static", widgets: ["w": widget("#{flash.source.value} #(echo job) %S", interval: 1)],
      sources: ["value": source])
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.tasks.count, 2)
    XCTAssertEqual(harness.nextWakeup, 101)
    harness.controller.setWidgetVisible(name: "w", false)
    harness.drain()
    XCTAssertTrue(harness.tasks.allSatisfy(\.cancelled), "hiding reaps the widget's commands")
    XCTAssertNil(harness.nextWakeup, "a hidden widget holds no deadline")
    harness.queue.sync { harness.now = 110 }
    harness.refresh()
    XCTAssertEqual(harness.tasks.count, 2, "nothing runs for a hidden widget")
    harness.controller.setWidgetVisible(name: "w", true)
    harness.drain()
    XCTAssertEqual(harness.tasks.count, 4)
    XCTAssertEqual(harness.nextWakeup, 111)
  }

  func testAWidgetIntervalArmsItsOwnClockBesideTheBars() {
    let harness = Harness(bar: "%H:%M", interval: 60)
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.nextWakeup, 160)
    harness.controller.updateWidgets(["seconds": widget("%S", interval: 1)])
    harness.drain()
    XCTAssertEqual(harness.nextWakeup, 101)
    harness.queue.sync { harness.now = 101 }
    harness.tick()
    XCTAssertEqual(harness.nextWakeup, 102)
    // A widget without its own interval follows the bar's cadence.
    harness.controller.updateWidgets(["seconds": widget("%S")])
    harness.drain()
    XCTAssertEqual(harness.nextWakeup, 160)
    harness.controller.setWidgetVisible(name: "seconds", false)
    harness.drain()
    XCTAssertEqual(harness.nextWakeup, 160)
  }

  func testAJobSharedAcrossSurfacesRefreshesAtTheFastestCadence() {
    let harness = Harness(
      bar: "#(echo shared)", widgets: ["w": widget("#(echo shared)", interval: 2)], interval: 30)
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.running("echo shared").count, 1)
    harness.queue.sync {
      harness.tasks[0].line("out")
      harness.tasks[0].completion(0, "out")
    }
    XCTAssertEqual(harness.nextWakeup, 102)
    harness.controller.setWidgetVisible(name: "w", false)
    harness.drain()
    XCTAssertEqual(harness.nextWakeup, 130, "the bar alone refreshes it at its own interval")
  }

  func testSurfacesExpandingOneJobDifferentlyRunAndShowTheirOwnCommands() {
    let template = "#(echo #{flash.widget.name})"
    let harness = Harness(bar: nil, widgets: ["a": widget(template), "b": widget(template)])
    defer { harness.controller.stop() }
    XCTAssertEqual(harness.running("echo a").count, 1)
    XCTAssertEqual(harness.running("echo b").count, 1)
    harness.queue.sync {
      for name in ["a", "b"] {
        let task = harness.running("echo \(name)")[0]
        task.line("out-\(name)")
        task.completion(0, "out-\(name)")
      }
    }
    harness.tick()
    XCTAssertEqual(harness.widgetText("a"), ["out-a"])
    XCTAssertEqual(harness.widgetText("b"), ["out-b"])
  }

  func testSurfacesSkipEvaluationIndependently() {
    let a = FlashStatusBarSourceDefinition(command: ["/bin/a"], intervalSeconds: 60)
    let b = FlashStatusBarSourceDefinition(command: ["/bin/b"], intervalSeconds: 60)
    let harness = Harness(
      bar: "#{flash.source.a}", widgets: ["w": widget("#{flash.source.b}")],
      sources: ["a": a, "b": b])
    defer { harness.controller.stop() }
    let bar = harness.evaluations("bar")
    let widget = harness.evaluations("w")
    XCTAssertGreaterThan(bar, 0)
    XCTAssertGreaterThan(widget, 0)
    let taskB = harness.tasks.first { $0.invocation.argv == ["/bin/b"] }
    harness.queue.sync { taskB?.completion(0, "B") }
    XCTAssertEqual(harness.evaluations("bar"), bar, "the bar read nothing that changed")
    XCTAssertEqual(harness.evaluations("w"), widget + 1)
    XCTAssertEqual(harness.widgetText("w"), ["B"])
    let taskA = harness.tasks.first { $0.invocation.argv == ["/bin/a"] }
    harness.queue.sync { taskA?.completion(0, "A") }
    XCTAssertEqual(harness.evaluations("bar"), bar + 1)
    XCTAssertEqual(harness.evaluations("w"), widget + 1, "the widget read nothing that changed")
    XCTAssertEqual(harness.barText, "A")
  }

  func testSourceHistoryKeepsTheLastNumbersAndSurvivesWhileInactive() {
    let source = FlashStatusBarSourceDefinition(
      command: ["/bin/load"], intervalSeconds: 5, historyLength: 3)
    let harness = Harness(bar: "#{flash.history.load}", sources: ["load": source])
    defer { harness.controller.stop() }
    func run(_ output: String) {
      harness.queue.sync { harness.tasks.last?.completion(0, output) }
      harness.queue.sync { harness.now += 5 }
      harness.refresh()
    }
    XCTAssertEqual(harness.tasks.count, 1, "a history reference runs its source")
    for output in ["1", "2.5", "n/a", "3", "4"] { run(output) }
    XCTAssertEqual(harness.barText, "2.5 3 4", "non-numeric output never enters the history")
    let started = harness.tasks.count
    harness.controller.updateTemplate(
      .init(template: "hidden"), sources: ["load": source], refreshIntervalSeconds: 0)
    harness.drain()
    harness.queue.sync { harness.now += 60 }
    harness.refresh()
    XCTAssertEqual(harness.tasks.count, started, "an inactive source stops running")
    harness.controller.updateTemplate(
      .init(template: "#{flash.history.load}"), sources: ["load": source])
    harness.drain()
    XCTAssertEqual(harness.barText, "2.5 3 4", "the ring is retained while inactive")
  }
}
