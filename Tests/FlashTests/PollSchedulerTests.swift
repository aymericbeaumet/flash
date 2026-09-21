import XCTest

@testable import flash

final class PollSchedulerTests: XCTestCase {
  private func client(
    _ id: String, every: Int, at: Int, busy: Bool = false
  ) -> PollScheduler.ClientState {
    PollScheduler.ClientState(id: id, intervalMs: every, nextAtMs: at, busy: busy)
  }

  func testClientsSharingAnIntervalShareAWakeup() {
    // The point of one clock is that twenty one-second pollers cost one
    // wake-up, so deadlines snap to a multiple of the interval instead of
    // landing wherever each client happened to register.
    let first = PollScheduler.nextDeadlineMs(afterNowMs: 10_123, intervalMs: 1000)
    let later = PollScheduler.nextDeadlineMs(afterNowMs: 10_876, intervalMs: 1000)
    XCTAssertEqual(first, 11_000)
    XCTAssertEqual(later, 11_000)
    // A deadline is always in the future, never the instant we asked.
    XCTAssertEqual(PollScheduler.nextDeadlineMs(afterNowMs: 11_000, intervalMs: 1000), 12_000)
    // Sub-floor registrations are clamped: below this a poll is a busy loop.
    XCTAssertEqual(
      PollScheduler.nextDeadlineMs(afterNowMs: 0, intervalMs: 1),
      PollScheduler.minimumIntervalMs)
  }

  func testPlanFiresDueClientsAndReschedulesThemOntoTheGrid() {
    let plan = PollScheduler.plan(
      nowMs: 5_000,
      clients: [
        client("a", every: 1000, at: 5_000),
        client("b", every: 1000, at: 4_900),
        client("c", every: 250, at: 6_000),
      ])
    XCTAssertEqual(plan.fire, ["a", "b"])
    XCTAssertTrue(plan.skipped.isEmpty)
    XCTAssertEqual(plan.rescheduled, ["a": 6_000, "b": 6_000])
    // The untouched client still owns the earliest deadline.
    XCTAssertEqual(plan.nextWakeupMs, 6_000)
  }

  func testAnOverrunningClientIsSkippedRatherThanQueued() {
    // A collector that has not returned must not have a second tick stacked
    // behind it; it loses this round and rejoins on the next deadline.
    let plan = PollScheduler.plan(
      nowMs: 3_000,
      clients: [
        client("slow", every: 1000, at: 3_000, busy: true),
        client("quick", every: 1000, at: 3_000),
      ])
    XCTAssertEqual(plan.fire, ["quick"])
    XCTAssertEqual(plan.skipped, ["slow"])
    XCTAssertEqual(plan.rescheduled, ["slow": 4_000, "quick": 4_000])
    XCTAssertEqual(plan.nextWakeupMs, 4_000)
  }

  func testNothingRegisteredMeansNoTimerAtAll() {
    let plan = PollScheduler.plan(nowMs: 1_000, clients: [])
    XCTAssertTrue(plan.fire.isEmpty)
    XCTAssertNil(plan.nextWakeupMs)
  }

  func testRegisteredClientsRunOnTheSharedClock() {
    let scheduler = PollScheduler()
    let ticked = expectation(description: "both clients tick")
    ticked.expectedFulfillmentCount = 2
    let queue = DispatchQueue(label: "poll.tests")
    for id in ["core:one", "core:two"] {
      scheduler.register(id, everyMs: 50, on: queue) { ticked.fulfill() }
    }
    wait(for: [ticked], timeout: 5)

    let listed = expectation(description: "registrations listed")
    scheduler.registeredIDs {
      XCTAssertEqual($0, ["core:one", "core:two"])
      listed.fulfill()
    }
    wait(for: [listed], timeout: 5)

    scheduler.unregister("core:one")
    scheduler.unregister("core:two")
    let empty = expectation(description: "registrations cleared")
    scheduler.registeredIDs {
      XCTAssertTrue($0.isEmpty)
      empty.fulfill()
    }
    wait(for: [empty], timeout: 5)
  }

  func testADeadlineRegistrationRunsOnceAndIsDropped() {
    // A client whose wake-ups are irregular — the status bar's next deadline
    // is the earliest of its job intervals, cycle rotations and pending
    // output — re-registers each time instead of owning a timer.
    let plan = PollScheduler.plan(
      nowMs: 2_000,
      clients: [
        PollScheduler.ClientState(
          id: "once", intervalMs: 500, nextAtMs: 2_000, busy: false, priority: .high,
          repeats: false),
        client("steady", every: 1000, at: 2_500),
      ])
    XCTAssertEqual(plan.fire, ["once"])
    XCTAssertEqual(plan.expired, ["once"])
    // A one-shot never re-arms itself.
    XCTAssertTrue(plan.rescheduled.isEmpty)
    XCTAssertEqual(plan.nextWakeupMs, 2_500)
  }

  func testTheTightestPriorityOnAWakeupSetsItsSlack() {
    // Slack is what lets unrelated wake-ups collapse into one, but a lax
    // client must never loosen a demanding one riding the same tick.
    let plan = PollScheduler.plan(
      nowMs: 0,
      clients: [
        PollScheduler.ClientState(
          id: "background", intervalMs: 1000, nextAtMs: 1_000, busy: false, priority: .low),
        PollScheduler.ClientState(
          id: "probe", intervalMs: 1000, nextAtMs: 1_000, busy: false, priority: .system),
      ])
    XCTAssertEqual(plan.nextWakeupMs, 1_000)
    XCTAssertEqual(plan.leewayMs, PollScheduler.Priority.system.leewayMs)

    // A later, laxer deadline keeps its own generous slack.
    let lax = PollScheduler.plan(
      nowMs: 0,
      clients: [
        PollScheduler.ClientState(
          id: "background", intervalMs: 1000, nextAtMs: 1_000, busy: false, priority: .low)
      ])
    XCTAssertEqual(lax.leewayMs, PollScheduler.Priority.low.leewayMs)
    XCTAssertLessThan(
      PollScheduler.Priority.system.leewayMs, PollScheduler.Priority.low.leewayMs)
    XCTAssertEqual(
      PollScheduler.Priority.allCases.sorted(),
      [.system, .high, .normal, .low])
  }

  func testDeadlineRegistrationsFireAndReplaceTheirPendingWakeup() {
    let scheduler = PollScheduler()
    let queue = DispatchQueue(label: "poll.once.tests")
    let fired = expectation(description: "deadline fires once")
    scheduler.scheduleOnce("core:once", afterMs: 60, priority: .high, on: queue) {
      fired.fulfill()
    }
    wait(for: [fired], timeout: 5)

    // Firing drops it, so nothing is left registered.
    let empty = expectation(description: "registration dropped")
    scheduler.registeredIDs {
      XCTAssertTrue($0.isEmpty)
      empty.fulfill()
    }
    wait(for: [empty], timeout: 5)

    // Re-arming the same id replaces the pending deadline rather than
    // stacking a second one.
    let again = expectation(description: "re-armed deadline fires once")
    again.expectedFulfillmentCount = 1
    again.assertForOverFulfill = true
    scheduler.scheduleOnce("core:once", afterMs: 5_000, on: queue) { again.fulfill() }
    scheduler.scheduleOnce("core:once", afterMs: 60, on: queue) { again.fulfill() }
    wait(for: [again], timeout: 5)
  }

  // MARK: - The plugin-facing registration

  func testPluginPollRegistrationsDecodeSecondsAndRejectMalformedFrames() {
    typealias Process = PluginProcess
    XCTAssertEqual(
      Process.decodePollIntervals(["intervals": ["sample": 1, "discover": 30.5]]),
      ["sample": 1000, "discover": 30_500])
    // An empty set is how a plugin stops polling entirely.
    XCTAssertEqual(Process.decodePollIntervals(["intervals": [String: Any]()]), [:])

    // Rejected whole, so a typo cannot leave a collector running at a rate
    // nobody asked for.
    XCTAssertNil(Process.decodePollIntervals([:]))
    XCTAssertNil(Process.decodePollIntervals(["intervals": "nope"]))
    XCTAssertNil(Process.decodePollIntervals(["intervals": ["sample": "1"]]))
    XCTAssertNil(Process.decodePollIntervals(["intervals": ["": 1]]))
    // Below the floor a "poll" is a busy loop.
    XCTAssertNil(Process.decodePollIntervals(["intervals": ["sample": 0.001]]))
    XCTAssertNil(Process.decodePollIntervals(["intervals": ["sample": 0]]))
    // The name rides inside the event name, so it stays unambiguous.
    XCTAssertNil(Process.decodePollIntervals(["intervals": ["core:poll": 1]]))
    XCTAssertNil(Process.decodePollIntervals(["intervals": ["Sample": 1]]))
  }

  func testPollClientIDsAreNamespacedPerPluginAndTimer() {
    XCTAssertEqual(
      PluginProcess.pollClientID(pluginID: "cpu", name: "i0"), "plugin:cpu:i0")
    XCTAssertNotEqual(
      PluginProcess.pollClientID(pluginID: "cpu", name: "i0"),
      PluginProcess.pollClientID(pluginID: "memory", name: "i0"))
  }
}
