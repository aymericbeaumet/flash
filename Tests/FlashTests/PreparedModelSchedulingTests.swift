import XCTest

@testable import flash

final class PreparedModelSchedulingTests: XCTestCase {
  private struct Clock {
    var now: UInt64 = 0
    mutating func advance(_ milliseconds: Int) { now += UInt64(milliseconds) * 1_000_000 }
  }

  private func scheduler() -> PreparedModelScheduler {
    PreparedModelScheduler(
      debounceMs: 80, minimumIntervalMs: 2500, freshnessMs: 1500, maintenanceLeadMs: 250)
  }

  /// A waiter is a promise: the one a newer activation displaces, and the
  /// ones cancelled with their app's refresh work, are handed back to be
  /// completed with nil, never dropped.
  func testDisplacedAndCancelledWaitersCompleteOnceWithNil() {
    var waiters = PreparedModelWaiters()
    var completed: [String] = []
    let waiter = { (name: String) -> PreparedModelWaiters.Waiter in
      { model in completed.append("\(name):\(model == nil ? "nil" : "model")") }
    }
    XCTAssertNil(waiters.park(waiter("a"), pid: 1))
    let displaced = waiters.park(waiter("b"), pid: 1)
    displaced?(nil)
    XCTAssertEqual(completed, ["a:nil"], "the displaced waiter is returned, not dropped")
    waiters.park(waiter("c"), pid: 2)?(nil)
    XCTAssertEqual(completed, ["a:nil"], "an empty slot displaces nothing")
    waiters.take(pid: 1)?(nil)
    XCTAssertEqual(completed, ["a:nil", "b:nil"])
    XCTAssertNil(waiters.take(pid: 1), "taken once")
    for cancelled in waiters.takeAll() { cancelled(nil) }
    XCTAssertEqual(completed, ["a:nil", "b:nil", "c:nil"])
    XCTAssertTrue(waiters.isEmpty)
  }

  func testCancelledWakeCannotConsumeRearmedRefresh() throws {
    var clock = Clock()
    var state = scheduler()
    let old = try XCTUnwrap(state.scheduleRefresh(pid: 42, reason: .focus, now: clock.now))
    state.cancelRefresh(pid: 42)
    clock.advance(10)
    let new = try XCTUnwrap(state.scheduleRefresh(pid: 42, reason: .config, now: clock.now))
    clock.advance(100)
    XCTAssertEqual(state.wake(old.ticket, now: clock.now), .stale)
    XCTAssertTrue(state.hasRefresh(pid: 42))
    XCTAssertEqual(state.wake(new.ticket, now: clock.now), .fire(.refresh(.config)))
    XCTAssertEqual(state.wake(new.ticket, now: clock.now), .stale)
  }

  func testEventBurstKeepsOneTimerAndExtendsItsDeadline() throws {
    var clock = Clock()
    var state = scheduler()
    let first = try XCTUnwrap(
      state.scheduleRefresh(pid: 42, reason: .axEvent("layout"), now: clock.now))
    clock.advance(60)
    XCTAssertNil(state.scheduleRefresh(pid: 42, reason: .axEvent("resize"), now: clock.now))
    clock.advance(20)
    guard case .wait(let extended) = state.wake(first.ticket, now: clock.now) else {
      return XCTFail("The first wake must retain the burst until its last event settles")
    }
    XCTAssertEqual(extended.ticket, first.ticket)
    XCTAssertEqual(extended.deadline, 140_000_000)
    clock.advance(60)
    XCTAssertEqual(state.wake(extended.ticket, now: clock.now), .fire(.refresh(.axEvent("resize"))))
  }

  func testFocusRefreshPreemptsThrottledNoiseAndRetainsPriority() throws {
    var clock = Clock()
    var state = scheduler()
    state.noteRefreshStarted(pid: 42, now: clock.now)
    let noisy = try XCTUnwrap(
      state.scheduleRefresh(pid: 42, reason: .axEvent("layout"), now: clock.now))
    XCTAssertEqual(noisy.deadline, 2_500_000_000)
    clock.advance(10)
    let focus = try XCTUnwrap(state.scheduleRefresh(pid: 42, reason: .focus, now: clock.now))
    clock.advance(10)
    XCTAssertNil(state.scheduleRefresh(pid: 42, reason: .axEvent("layout"), now: clock.now))
    state.suppressSpeculativeRefresh(pid: 42)
    clock.advance(70)
    XCTAssertEqual(state.wake(focus.ticket, now: clock.now), .fire(.refresh(.focus)))
    clock.advance(3000)
    XCTAssertEqual(state.wake(noisy.ticket, now: clock.now), .stale)
  }

  func testMaintenanceStartsBeforeFreshnessDespiteBackgroundThrottle() throws {
    var clock = Clock()
    var state = scheduler()
    state.noteRefreshStarted(pid: 42, now: clock.now)
    clock.advance(40)
    let computedAt = clock.now
    let maintenance = state.scheduleMaintenance(
      pid: 42, computedAt: computedAt, dirtyToken: 7, configRevision: 2)
    clock.advance(1250)
    XCTAssertEqual(
      state.wake(maintenance.ticket, now: clock.now),
      .fire(.maintenance(dirtyToken: 7, configRevision: 2)))
    let refresh = try XCTUnwrap(
      state.scheduleRefresh(pid: 42, reason: .maintenance, now: clock.now))
    XCTAssertLessThan(refresh.deadline + 50_000_000, computedAt + 1_500_000_000)
    clock.advance(80)
    XCTAssertEqual(state.wake(refresh.ticket, now: clock.now), .fire(.refresh(.maintenance)))
  }

  /// The maintenance interval is the one backoff. A slow walk — one that
  /// would cost over a tenth of a core at the current interval — doubles it
  /// toward the 30 s ceiling; a walk cheap enough for a shorter interval
  /// shrinks it back, only as far as its cost allows; a static app's
  /// unchanged reproduction grows it as before; an empty tree, fast because
  /// there was nothing to read, leaves it alone.
  func testTheMaintenanceIntervalDoublesToTheCeilingAndShrinksBackAsWalksGetCheaper() {
    let floor = AppMonitor.modelFreshnessMs
    let ceiling = AppMonitor.modelFreshnessMaxMs
    func next(
      _ current: Int, _ elapsedMs: Double, unchanged: Bool = false, degenerate: Bool = false
    ) -> Int {
      AppMonitor.nextModelIntervalMs(
        current: current, elapsedMs: elapsedMs, unchanged: unchanged, degenerate: degenerate)
    }
    XCTAssertEqual(next(floor, 60), floor)
    XCTAssertEqual(next(floor, 200), 3000, "slow at 1.5 s: doubles")
    XCTAssertEqual(next(3000, 200), 3000, "kept: still slow for the floor")
    XCTAssertEqual(next(3000, 100), floor, "cheap for the floor: shrinks back")
    XCTAssertEqual(next(3000, 500), 6000)
    XCTAssertEqual(next(6000, 500), 6000)
    XCTAssertEqual(next(24_000, 2000), 24_000)
    XCTAssertEqual(next(24_000, 100), floor, "all the way back in one step")
    XCTAssertEqual(next(24_000, 5000), ceiling, "the ceiling")
    XCTAssertEqual(next(ceiling, 5000), ceiling)
    XCTAssertEqual(next(ceiling, 800), 15_000, "halves while the halved interval stays cheap")
    XCTAssertEqual(next(floor, 10, unchanged: true), 3000, "a static app is walked less often")
    XCTAssertEqual(next(ceiling, 10, unchanged: true), ceiling)
    XCTAssertEqual(next(6000, 5, degenerate: true), 6000)
    XCTAssertEqual(next(6000, 900, degenerate: true), 12_000, "a slow empty walk still backs off")

    // The wake follows the interval: 250 ms before it.
    var state = scheduler()
    let backedOff = state.scheduleMaintenance(
      pid: 42, computedAt: 0, dirtyToken: 1, configRevision: 1,
      freshnessNs: UInt64(next(floor, 200)) * 1_000_000)
    XCTAssertEqual(backedOff.deadline, 2_750_000_000)
  }

  /// An app's interval also spaces its event-driven refreshes: the fixed
  /// 2.5 s minimum is the floor, the app's interval the throttle, and only
  /// throttled reasons wait.
  func testAnAppsIntervalThrottlesItsEventRefreshesBeyondTheFixedMinimum() throws {
    var clock = Clock()
    var state = scheduler()
    state.noteRefreshStarted(pid: 42, now: clock.now)
    clock.advance(100)
    let spaced = try XCTUnwrap(
      state.scheduleRefresh(
        pid: 42, reason: .axEvent("layout"), now: clock.now, minimumIntervalNs: 6_000_000_000))
    XCTAssertEqual(spaced.deadline, 6_000_000_000)
    XCTAssertEqual(state.refreshDeadline(pid: 42), 6_000_000_000)
    state.cancelRefresh(pid: 42)
    let short = try XCTUnwrap(
      state.scheduleRefresh(
        pid: 42, reason: .axEvent("layout"), now: clock.now, minimumIntervalNs: 1_500_000_000))
    XCTAssertEqual(short.deadline, 2_500_000_000, "never under the fixed minimum")
    state.cancelRefresh(pid: 42)
    let focus = try XCTUnwrap(
      state.scheduleRefresh(
        pid: 42, reason: .focus, now: clock.now, minimumIntervalNs: 6_000_000_000))
    XCTAssertEqual(focus.deadline, 180_000_000, "only throttled reasons wait")
    XCTAssertNil(state.refreshDeadline(pid: 7))
  }

  func testMaintenanceWakesLeadBeforeTheModelsOwnFreshness() {
    var state = scheduler()
    let extended = state.scheduleMaintenance(
      pid: 42, computedAt: 0, dirtyToken: 7, configRevision: 2, freshnessNs: 6_000_000_000)
    XCTAssertEqual(extended.deadline, 5_750_000_000)
    XCTAssertEqual(state.wake(extended.ticket, now: 5_000_000_000), .wait(extended))
    XCTAssertEqual(
      state.wake(extended.ticket, now: 5_750_000_000),
      .fire(.maintenance(dirtyToken: 7, configRevision: 2)))
  }

  func testReplacingMaintenanceRejectsOlderTimerEvenWithSameModelTokens() {
    var state = scheduler()
    let old = state.scheduleMaintenance(pid: 42, computedAt: 0, dirtyToken: 7, configRevision: 2)
    let current = state.scheduleMaintenance(
      pid: 42, computedAt: 100_000_000, dirtyToken: 7, configRevision: 2)
    XCTAssertEqual(state.wake(old.ticket, now: 2_000_000_000), .stale)
    XCTAssertEqual(
      state.wake(current.ticket, now: 2_000_000_000),
      .fire(.maintenance(dirtyToken: 7, configRevision: 2)))
  }

  func testSpeculativeSuppressionAndResetInvalidateBothTimerKinds() throws {
    var state = scheduler()
    let refresh = try XCTUnwrap(state.scheduleRefresh(pid: 42, reason: .axEvent("layout"), now: 0))
    let maintenance = state.scheduleMaintenance(
      pid: 42, computedAt: 0, dirtyToken: 7, configRevision: 2)
    state.suppressSpeculativeRefresh(pid: 42)
    XCTAssertEqual(state.wake(refresh.ticket, now: 3_000_000_000), .stale)
    XCTAssertEqual(state.wake(maintenance.ticket, now: 3_000_000_000), .stale)
    let focus = try XCTUnwrap(state.scheduleRefresh(pid: 42, reason: .focus, now: 0))
    state.reset()
    let next = try XCTUnwrap(state.scheduleRefresh(pid: 42, reason: .focus, now: 0))
    XCTAssertEqual(state.wake(focus.ticket, now: 3_000_000_000), .stale)
    XCTAssertEqual(state.wake(next.ticket, now: 3_000_000_000), .fire(.refresh(.focus)))
  }
  func testAReadinessStepHasItsOwnTicketBesideRefreshAndMaintenance() throws {
    var clock = Clock()
    var state = scheduler()
    let refresh = try XCTUnwrap(state.scheduleRefresh(pid: 42, reason: .userAction("x"), now: 0))
    let readiness = state.scheduleReadiness(
      pid: 42, step: 1, then: .focus, deadline: clock.now + 100_000_000)
    XCTAssertTrue(state.hasReadiness(pid: 42))
    XCTAssertTrue(state.hasRefresh(pid: 42), "a readiness step never replaces a refresh")
    clock.advance(50)
    XCTAssertEqual(state.wake(readiness.ticket, now: clock.now), .wait(readiness))
    clock.advance(50)
    XCTAssertEqual(
      state.wake(readiness.ticket, now: clock.now), .fire(.readiness(step: 1, then: .focus)))
    XCTAssertFalse(state.hasReadiness(pid: 42))
    XCTAssertEqual(state.wake(refresh.ticket, now: clock.now), .fire(.refresh(.userAction("x"))))
  }

  func testAReadinessProbeAppliesOnlyWhileItsHoldSurvives() {
    var state = scheduler()
    let held = state.holdReadiness(pid: 42, step: 0, then: .readiness)
    XCTAssertTrue(state.hasReadiness(pid: 42), "a probe in flight still defers speculation")
    XCTAssertTrue(state.releaseReadiness(held))
    XCTAssertFalse(state.releaseReadiness(held), "a hold is consumed once")
    XCTAssertFalse(state.hasReadiness(pid: 42))

    // A newer ladder, a cancel or a reset revokes the probe's result.
    let replaced = state.holdReadiness(pid: 42, step: 0, then: .focus)
    let next = state.scheduleReadiness(pid: 42, step: 0, then: .focus, deadline: 1)
    XCTAssertFalse(state.releaseReadiness(replaced))
    XCTAssertEqual(state.wake(next.ticket, now: 1), .fire(.readiness(step: 0, then: .focus)))

    let cancelled = state.holdReadiness(pid: 42, step: 2, then: .focus)
    state.cancelReadiness(pid: 42)
    XCTAssertFalse(state.releaseReadiness(cancelled))

    let reset = state.holdReadiness(pid: 42, step: 2, then: .focus)
    state.reset(pid: 42)
    XCTAssertFalse(state.releaseReadiness(reset))
  }

  func testFocusElsewhereRevokesEveryOtherAppsLadder() {
    var state = scheduler()
    let other = state.scheduleReadiness(pid: 7, step: 0, then: .focus, deadline: 1)
    let otherProbe = state.holdReadiness(pid: 8, step: 1, then: .readiness)
    let focused = state.scheduleReadiness(pid: 9, step: 0, then: .focus, deadline: 1)
    state.cancelReadiness(exceptPID: 9)
    XCTAssertEqual(state.wake(other.ticket, now: 2), .stale)
    XCTAssertFalse(state.releaseReadiness(otherProbe))
    XCTAssertEqual(state.wake(focused.ticket, now: 2), .fire(.readiness(step: 0, then: .focus)))
  }

  func testSpeculativeSuppressionKeepsTheReadinessLadder() {
    var state = scheduler()
    let readiness = state.scheduleReadiness(pid: 42, step: 0, then: .readiness, deadline: 1)
    // Storms and slow walks pause speculation; a tree mid-build is exactly
    // when an app storms, so the ladder must survive them.
    state.suppressSpeculativeRefresh(pid: 42)
    XCTAssertEqual(
      state.wake(readiness.ticket, now: 1), .fire(.readiness(step: 0, then: .readiness)))
  }
}
