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
    let old = try XCTUnwrap(state.scheduleRefresh(pid: 42, reason: "focus", now: clock.now))
    state.cancelRefresh(pid: 42)
    clock.advance(10)
    let new = try XCTUnwrap(state.scheduleRefresh(pid: 42, reason: "config", now: clock.now))
    clock.advance(100)
    XCTAssertEqual(state.wake(old.ticket, now: clock.now), .stale)
    XCTAssertTrue(state.hasRefresh(pid: 42))
    XCTAssertEqual(state.wake(new.ticket, now: clock.now), .fire(.refresh("config")))
    XCTAssertEqual(state.wake(new.ticket, now: clock.now), .stale)
  }

  func testEventBurstKeepsOneTimerAndExtendsItsDeadline() throws {
    var clock = Clock()
    var state = scheduler()
    let first = try XCTUnwrap(state.scheduleRefresh(pid: 42, reason: "ax:layout", now: clock.now))
    clock.advance(60)
    XCTAssertNil(state.scheduleRefresh(pid: 42, reason: "ax:resize", now: clock.now))
    clock.advance(20)
    guard case .wait(let extended) = state.wake(first.ticket, now: clock.now) else {
      return XCTFail("The first wake must retain the burst until its last event settles")
    }
    XCTAssertEqual(extended.ticket, first.ticket)
    XCTAssertEqual(extended.deadline, 140_000_000)
    clock.advance(60)
    XCTAssertEqual(state.wake(extended.ticket, now: clock.now), .fire(.refresh("ax:resize")))
  }

  func testFocusRefreshPreemptsThrottledNoiseAndRetainsPriority() throws {
    var clock = Clock()
    var state = scheduler()
    state.noteRefreshStarted(pid: 42, now: clock.now)
    let noisy = try XCTUnwrap(state.scheduleRefresh(pid: 42, reason: "ax:layout", now: clock.now))
    XCTAssertEqual(noisy.deadline, 2_500_000_000)
    clock.advance(10)
    let focus = try XCTUnwrap(state.scheduleRefresh(pid: 42, reason: "focus", now: clock.now))
    clock.advance(10)
    XCTAssertNil(state.scheduleRefresh(pid: 42, reason: "ax:layout", now: clock.now))
    state.suppressSpeculativeRefresh(pid: 42)
    clock.advance(70)
    XCTAssertEqual(state.wake(focus.ticket, now: clock.now), .fire(.refresh("focus")))
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
      state.scheduleRefresh(pid: 42, reason: "maintenance", now: clock.now))
    XCTAssertLessThan(refresh.deadline + 50_000_000, computedAt + 1_500_000_000)
    clock.advance(80)
    XCTAssertEqual(state.wake(refresh.ticket, now: clock.now), .fire(.refresh("maintenance")))
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
    let refresh = try XCTUnwrap(state.scheduleRefresh(pid: 42, reason: "ax:layout", now: 0))
    let maintenance = state.scheduleMaintenance(
      pid: 42, computedAt: 0, dirtyToken: 7, configRevision: 2)
    state.suppressSpeculativeRefresh(pid: 42)
    XCTAssertEqual(state.wake(refresh.ticket, now: 3_000_000_000), .stale)
    XCTAssertEqual(state.wake(maintenance.ticket, now: 3_000_000_000), .stale)
    let focus = try XCTUnwrap(state.scheduleRefresh(pid: 42, reason: "focus", now: 0))
    state.reset()
    let next = try XCTUnwrap(state.scheduleRefresh(pid: 42, reason: "focus", now: 0))
    XCTAssertEqual(state.wake(focus.ticket, now: 3_000_000_000), .stale)
    XCTAssertEqual(state.wake(next.ticket, now: 3_000_000_000), .fire(.refresh("focus")))
  }
}
