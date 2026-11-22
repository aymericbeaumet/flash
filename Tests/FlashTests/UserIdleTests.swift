import XCTest

@testable import flash

/// `core:user.idle` and `core:user.active`: what an away episode announces,
/// when the watch samples next, and which event monitors fire.
final class UserIdleTests: XCTestCase {
  func testAnEpisodeAnnouncesEachThresholdOnceThenTheReturn() {
    var watch = IdleWatch()
    var step = watch.sample(idleSeconds: 10, thresholds: [600, 60])
    XCTAssertEqual(step.announcements, [])
    XCTAssertEqual(step.nextSampleIn, 50, "nothing announced: wait for the first threshold")

    step = watch.sample(idleSeconds: 61, thresholds: [60, 600])
    XCTAssertEqual(step.announcements, [.idle(seconds: 60)])
    XCTAssertEqual(
      step.nextSampleIn, IdleWatch.returnProbeSeconds, "announced: probe for the return")

    step = watch.sample(idleSeconds: 63, thresholds: [60, 600])
    XCTAssertEqual(step.announcements, [], "each threshold once per episode")

    step = watch.sample(idleSeconds: 700, thresholds: [60, 600])
    XCTAssertEqual(step.announcements, [.idle(seconds: 600)])

    step = watch.sample(idleSeconds: 1, thresholds: [60, 600])
    XCTAssertEqual(step.announcements, [.active(idleSeconds: 700)])
    XCTAssertEqual(step.nextSampleIn, 59, "a new episode waits for the first threshold again")
  }

  func testInputBeforeAnyThresholdAnnouncesNothing() {
    var watch = IdleWatch()
    _ = watch.sample(idleSeconds: 50, thresholds: [60])
    XCTAssertEqual(watch.sample(idleSeconds: 2, thresholds: [60]).announcements, [])
  }

  func testASampleAlreadyPastSeveralThresholdsAnnouncesThemAll() {
    var watch = IdleWatch()
    XCTAssertEqual(
      watch.sample(idleSeconds: 1000, thresholds: [300, 60]).announcements,
      [.idle(seconds: 60), .idle(seconds: 300)])
  }

  func testNoThresholdMeansNoSampling() {
    var watch = IdleWatch()
    XCTAssertNil(watch.sample(idleSeconds: 1000, thresholds: []).nextSampleIn)
  }

  func testAMonitorFiresAtItsOwnIdleTimeAndOnAReturnFromAtLeastIt() throws {
    let config = ConfigLoader.parse(
      """
      [monitors.away]
      event = ["core:user.idle", "core:user.active"]
      idle = 600
      run = ["/bin/echo", "away"]
      """)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    let spec = try XCTUnwrap(config.eventMonitorSpecs["away"])
    XCTAssertEqual(spec.idleSeconds, 600)
    XCTAssertTrue(spec.listensToIdle)
    XCTAssertTrue(spec.matches(PluginEvent(.userIdle, payload: ["seconds": 600])))
    XCTAssertFalse(spec.matches(PluginEvent(.userIdle, payload: ["seconds": 300])))
    XCTAssertTrue(spec.matches(PluginEvent(.userActive, payload: ["idle_seconds": 900])))
    XCTAssertFalse(
      spec.matches(PluginEvent(.userActive, payload: ["idle_seconds": 400])),
      "back before this monitor's idle time")
  }

  func testAnIdleTimeNeedsAnIdleEventAndARange() {
    func messages(_ toml: String) -> [String] {
      ConfigLoader.parse(toml).loadingDiagnostics.map(\.message)
    }
    XCTAssertTrue(
      messages(
        """
        [monitors.x]
        event = "core:screen.locked"
        idle = 60
        run = ["true"]
        """
      ).contains { $0.contains("monitors.x.idle times core:user.idle and core:user.active") })
    XCTAssertTrue(
      messages(
        """
        [monitors.x]
        event = "core:user.idle"
        idle = 0
        run = ["true"]
        """
      ).contains { $0.contains("monitors.x.idle must be an integer between 1 and 86400") })
  }

  func testTheMonitorAnnouncesWhatItsFirstSampleFinds() {
    var announced: [IdleWatch.Announcement] = []
    let monitor = UserIdleMonitor(
      thresholds: { [60] }, readIdleSeconds: { 90 },
      deadline: PollDeadline("test:user-idle", priority: .low, on: .main),
      announce: { announced.append($0) })
    monitor.start()
    XCTAssertEqual(announced, [.idle(seconds: 60)])
    monitor.stop()
  }
}
