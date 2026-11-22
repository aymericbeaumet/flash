import ApplicationServices
import XCTest

@testable import flash

/// What `[latency] hints_visible` says Flash was doing about a model an
/// activation missed (`PreparedModelMissContext`).
final class PreparedModelMissContextTests: XCTestCase {
  private let bundle = "com.example.app"

  private func monitor() -> AppMonitor {
    AppMonitor(
      registry: SourceRegistry(descriptors: [], runningApplications: []), config: .default,
      pollScheduler: PollScheduler())
  }

  private func model(pid: pid_t, computedAt: DispatchTime) -> PreparedModel {
    PreparedModel(
      pid: pid, targets: [], hints: [], computedAt: computedAt, dirtyToken: 0, configRevision: 0,
      fingerprint: 0, freshnessMs: AppMonitor.modelFreshnessMs, occluded: false, occlusion: nil)
  }

  private func after(_ start: DispatchTime, ms: UInt64) -> DispatchTime {
    DispatchTime(uptimeNanoseconds: start.uptimeNanoseconds + ms * 1_000_000)
  }

  func testAnAppNeverWalkedHasNothingToReport() {
    let monitor = monitor()
    defer { monitor.cancelAllRefreshWork() }
    XCTAssertEqual(
      monitor.preparedModelMissContext(for: 4250, bundleIdentifier: bundle),
      PreparedModelMissContext(
        modelAgeMs: nil, noModelMs: nil, intervalMs: AppMonitor.modelFreshnessMs, pending: .none,
        refreshInMs: nil, cause: nil))
  }

  /// A value change discards the model and arms the walk for when the app
  /// goes quiet: the miss says which notification, how long ago, and how far
  /// away that walk was.
  func testAValueChangeLeavesNoModelAndAQuietWalkPending() {
    let monitor = monitor()
    defer { monitor.cancelAllRefreshWork() }
    let pid: pid_t = 4251
    monitor.preparedModels.store(model(pid: pid, computedAt: .now()))
    let invalidatedAt = DispatchTime.now()
    monitor.onAXEvent(
      pid: pid, notification: kAXValueChangedNotification as String,
      observedElementIsFocusedWindow: false, observedWindow: nil)

    let context = monitor.preparedModelMissContext(
      for: pid, bundleIdentifier: bundle, now: after(invalidatedAt, ms: 100))
    XCTAssertNil(context.modelAgeMs)
    XCTAssertEqual(context.cause, kAXValueChangedNotification as String)
    XCTAssertEqual(context.pending, .debounce)
    XCTAssertEqual(context.refreshInMs ?? 0, AppMonitor.modelChurnQuietMs - 100, accuracy: 50)
    XCTAssertEqual(context.noModelMs ?? 0, 100, accuracy: 50)
  }

  /// A layout change schedules a walk; one held back by what the app's walks
  /// cost reports how far away the walk was. The maintenance interval a
  /// static app grew holds nothing back.
  func testALayoutChangeBehindACostlyWalkIsThrottled() {
    let monitor = monitor()
    defer { monitor.cancelAllRefreshWork() }
    let pid: pid_t = 4252
    let startedAt = DispatchTime.now()
    monitor.modelIntervalsMs[pid] = 24_000
    monitor.modelWalkCostsMs[pid] = 800
    monitor.modelScheduler.noteRefreshStarted(pid: pid, now: startedAt.uptimeNanoseconds)
    monitor.onAXEvent(
      pid: pid, notification: kAXLayoutChangedNotification as String,
      observedElementIsFocusedWindow: false, observedWindow: nil)

    let context = monitor.preparedModelMissContext(
      for: pid, bundleIdentifier: bundle, now: after(startedAt, ms: 1_000))
    XCTAssertEqual(context.pending, .throttled)
    XCTAssertEqual(context.intervalMs, 24_000)
    XCTAssertEqual(context.refreshInMs, 7_000)
    XCTAssertEqual(context.cause, kAXLayoutChangedNotification as String)

    monitor.cancelRefreshWork(for: pid)
    monitor.modelIntervalsMs[pid] = 24_000
    monitor.modelWalkCostsMs[pid] = 60
    monitor.modelScheduler.noteRefreshStarted(pid: pid, now: startedAt.uptimeNanoseconds)
    monitor.onAXEvent(
      pid: pid, notification: kAXLayoutChangedNotification as String,
      observedElementIsFocusedWindow: false, observedWindow: nil)
    let cheap = monitor.preparedModelMissContext(
      for: pid, bundleIdentifier: bundle, now: after(startedAt, ms: 1_000))
    XCTAssertEqual(cheap.refreshInMs, 1_500, "the fixed minimum, not the 24 s interval")
  }

  /// A model the lookup rejected for its age reports that age, and the
  /// maintenance that was armed to renew it.
  func testAnExpiredModelReportsItsAgeAndItsMaintenance() {
    let monitor = monitor()
    defer { monitor.cancelAllRefreshWork() }
    let pid: pid_t = 4253
    let computedAt = DispatchTime.now()
    let stored = model(pid: pid, computedAt: computedAt)
    monitor.preparedModels.store(stored)
    monitor.scheduleMaintenanceRefresh(for: stored)

    let context = monitor.preparedModelMissContext(
      for: pid, bundleIdentifier: bundle, now: after(computedAt, ms: 1_000))
    XCTAssertEqual(context.modelAgeMs, 1_000)
    XCTAssertNil(context.noModelMs)
    XCTAssertEqual(context.pending, .maintenance)
    XCTAssertEqual(context.refreshInMs, 250)
    XCTAssertNil(context.cause)
  }

  /// A walk in flight wins over whatever is armed; an app Flash is not
  /// warming says so when nothing is.
  func testAWalkInFlightAndASuppressedAppAreNamed() throws {
    let monitor = monitor()
    defer { monitor.cancelAllRefreshWork() }
    let pid: pid_t = 4254
    monitor.axEventStormingPIDs.insert(pid)
    XCTAssertEqual(
      monitor.preparedModelMissContext(for: pid, bundleIdentifier: bundle).pending, .suppressed)
    let ticket = try XCTUnwrap(monitor.preparedModels.beginRebuild(pid: pid))
    XCTAssertEqual(
      monitor.preparedModelMissContext(for: pid, bundleIdentifier: bundle).pending, .walking)
    _ = monitor.preparedModels.finishRebuild(ticket)
  }
}
