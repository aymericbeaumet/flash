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
