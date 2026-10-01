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

  /// Arming reads the registrations as they stand: one already due — a
  /// zero-delay deadline, or anything that fell due while the scheduler was
  /// held — wakes the timer now instead of waiting for the next deadline.
  func testTheTimerIsArmedForTheEarliestDeadlineEvenWhenItIsAlreadyDue() {
    XCTAssertNil(PollScheduler.wakeup(clients: []))
    let wakeup = PollScheduler.wakeup(clients: [
      PollScheduler.ClientState(
        id: "overdue", intervalMs: 1, nextAtMs: 900, busy: false, priority: .low, repeats: false),
      PollScheduler.ClientState(
        id: "probe", intervalMs: 80, nextAtMs: 900, busy: false, priority: .system),
      client("later", every: 1000, at: 2_000),
    ])
    XCTAssertEqual(wakeup?.atMs, 900)
    XCTAssertEqual(wakeup?.leewayMs, PollScheduler.Priority.system.leewayMs)
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
    // Both keep ticking until they are unregistered below.
    ticked.assertForOverFulfill = false
    let queue = DispatchQueue(label: "poll.tests")
    for id in ["core:one", "core:two"] {
      scheduler.register(id, everyMs: 50, priority: .normal, on: queue) { ticked.fulfill() }
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
    scheduler.scheduleOnce("core:once", afterMs: 5_000, priority: .normal, on: queue) {
      again.fulfill()
    }
    scheduler.scheduleOnce("core:once", afterMs: 60, priority: .normal, on: queue) {
      again.fulfill()
    }
    wait(for: [again], timeout: 5)
  }

  // MARK: - Re-armable deadlines

  private func registeredIDs(_ scheduler: PollScheduler) -> [String] {
    let listed = DispatchSemaphore(value: 0)
    var ids: [String] = []
    scheduler.registeredIDs {
      ids = $0
      listed.signal()
    }
    listed.wait()
    return ids
  }

  /// A debounce re-arms one registration per event; only the last arming
  /// runs, and it leaves nothing registered behind it.
  func testAPollDeadlineRunsOnlyItsLatestArming() {
    let scheduler = PollScheduler()
    let queue = DispatchQueue(label: "poll.deadline.tests")
    let deadline = PollDeadline("core:debounce", priority: .normal, on: queue, scheduler: scheduler)
    let fired = expectation(description: "the latest arming runs once")
    fired.assertForOverFulfill = true
    var runs: [Int] = []
    queue.sync {
      for arming in 1...3 {
        deadline.arm(afterMs: 40) {
          runs.append(arming)
          fired.fulfill()
        }
      }
    }
    wait(for: [fired], timeout: 5)
    queue.sync { XCTAssertEqual(runs, [3]) }
    XCTAssertEqual(registeredIDs(scheduler), [])
    queue.sync { XCTAssertFalse(deadline.isArmed) }
  }

  /// Cancelling releases the registration, so a cancelled debounce costs no
  /// wake-up; a fire already on its way to the queue is dropped as stale.
  func testCancellingAPollDeadlineReleasesItsWakeup() {
    let scheduler = PollScheduler()
    let queue = DispatchQueue(label: "poll.deadline.cancel.tests")
    let deadline = PollDeadline("core:grace", priority: .low, on: queue, scheduler: scheduler)
    let dropped = expectation(description: "a cancelled deadline never runs")
    dropped.isInverted = true
    queue.sync { deadline.arm(afterMs: 5_000) { dropped.fulfill() } }
    XCTAssertEqual(registeredIDs(scheduler), ["core:grace"])
    queue.sync { deadline.cancel() }
    XCTAssertEqual(registeredIDs(scheduler), [])

    queue.sync { deadline.arm(afterMs: 0) { dropped.fulfill() } }
    // Cancel from the handler queue while the zero-delay fire is in flight.
    queue.async { deadline.cancel() }
    wait(for: [dropped], timeout: 0.3)
  }

  // MARK: - Suspension

  func testTheGateHoldsWhileAnyReasonRemainsAndResumesOnTheLast() {
    var gate = PollScheduler.Gate()
    XCTAssertFalse(gate.isSuspended)
    XCTAssertEqual(gate.set(.screens, active: true), .suspended)
    // A second reason neither re-suspends nor lets a lone release resume.
    XCTAssertEqual(gate.set(.session, active: true), .unchanged)
    XCTAssertEqual(gate.set(.screens, active: true), .unchanged)
    XCTAssertEqual(gate.set(.screens, active: false), .unchanged)
    XCTAssertTrue(gate.isSuspended)
    // Releasing a reason that never held is not a transition.
    XCTAssertEqual(gate.set(.systemSleep, active: false), .unchanged)
    XCTAssertEqual(gate.set(.session, active: false), .resumed)
    XCTAssertFalse(gate.isSuspended)
    XCTAssertEqual(gate.set(.session, active: false), .unchanged)
  }

  func testResumeRunsEveryOverdueClientOnceAndReturnsItToTheGrid() {
    // A registration that missed forty ticks while the displays slept is
    // owed one catch-up tick, not forty.
    let plan = PollScheduler.plan(
      nowMs: 45_300,
      clients: [
        client("sampler", every: 1000, at: 5_000),
        PollScheduler.ClientState(
          id: "deadline", intervalMs: 20_000, nextAtMs: 20_000, busy: false, repeats: false),
        client("later", every: 60_000, at: 60_000),
      ])
    XCTAssertEqual(plan.fire, ["deadline", "sampler"])
    XCTAssertEqual(plan.rescheduled, ["sampler": 46_000])
    XCTAssertEqual(plan.expired, ["deadline"])
    XCTAssertEqual(plan.nextWakeupMs, 46_000)
  }

  func testASuspendedSchedulerFiresNothingUntilItResumes() {
    let scheduler = PollScheduler()
    let queue = DispatchQueue(label: "poll.suspend.tests")
    scheduler.setSuspended(true, reason: .screens)
    let held = expectation(description: "nothing fires while suspended")
    held.isInverted = true
    let resumed = expectation(description: "the catch-up tick fires after resuming")
    resumed.assertForOverFulfill = false
    let caughtUp = expectation(description: "the overdue deadline fires once after resuming")
    caughtUp.assertForOverFulfill = true
    var suspended = true
    scheduler.register("core:held", everyMs: 50, priority: .low, on: queue) {
      if suspended { held.fulfill() } else { resumed.fulfill() }
    }
    scheduler.scheduleOnce("core:held.once", afterMs: 60, priority: .low, on: queue) {
      if suspended { held.fulfill() } else { caughtUp.fulfill() }
    }
    wait(for: [held], timeout: 0.4)
    queue.sync { suspended = false }
    scheduler.setSuspended(false, reason: .screens)
    // Both overdue registrations run in the catch-up tick.
    wait(for: [resumed, caughtUp], timeout: 5)
    scheduler.unregister("core:held")
  }

  /// A deadline that is already due when it is registered — a zero delay, or
  /// an uptime deadline that passed while its arm was computed — fires at
  /// once rather than never.
  func testADeadlineAlreadyDueAtRegistrationFiresAtOnce() {
    let scheduler = PollScheduler()
    let queue = DispatchQueue(label: "poll.due.tests")
    let fired = expectation(description: "a zero-delay deadline fires")
    scheduler.scheduleOnce("core:due", afterMs: 0, priority: .normal, on: queue) {
      fired.fulfill()
    }
    wait(for: [fired], timeout: 2)
  }

  func testTheSharedClockCountsTimeSpentAsleep() {
    // Deadlines ride a clock that keeps running through system sleep, so a
    // wake finds every deadline that passed meanwhile overdue.
    let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let continuous = clock_gettime_nsec_np(CLOCK_MONOTONIC)
    let now = PollScheduler.continuousNowMs()
    XCTAssertGreaterThanOrEqual(now, Int(continuous / 1_000_000))
    XCTAssertGreaterThanOrEqual(continuous, uptime)
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
