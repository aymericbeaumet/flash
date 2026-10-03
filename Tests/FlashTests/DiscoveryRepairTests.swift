import FlashCore
import FlashProviders
import XCTest

@testable import flash

final class DiscoveryRepairTests: XCTestCase {
  // MARK: Outcome threading

  func testTheDiscoveryPathDecidesWhetherThePreparedModelServed() {
    XCTAssertTrue(DiscoveryOutcome(path: "prepared_model").preparedHit)
    XCTAssertTrue(DiscoveryOutcome(path: "prepared_model_filter").preparedHit)
    for path in [
      "prepared_model_refresh", "prepared_model_refresh_filter", "activation_refresh_miss",
      "activation_uncached", "activation_no_fallback", "activation_self",
    ] {
      XCTAssertFalse(DiscoveryOutcome(path: path).preparedHit, path)
      XCTAssertEqual(DiscoveryOutcome(path: path).prepared, .miss, path)
    }
    XCTAssertEqual(DiscoveryOutcome(path: "prepared_model").prepared, .hit)
  }

  func testTheLoggedOutcomeNamesHowTheHintsWereObtained() {
    typealias Probe = HintLatencyProbe
    XCTAssertEqual(Probe.outcome(DiscoveryOutcome(path: "prepared_model"), appHints: 9), .hit)
    XCTAssertEqual(
      Probe.outcome(DiscoveryOutcome(path: "prepared_model_refresh"), appHints: 9), .miss)
    XCTAssertEqual(
      Probe.outcome(DiscoveryOutcome(path: "prepared_model_refresh", retried: true), appHints: 9),
      .retried)
    XCTAssertEqual(
      Probe.outcome(DiscoveryOutcome(path: "activation_refresh_miss", retried: true), appHints: 9),
      .retried)
    // The app yielded nothing, whatever else (status-bar segments) was shown.
    XCTAssertEqual(
      Probe.outcome(DiscoveryOutcome(path: "prepared_model_refresh", retried: true), appHints: 0),
      .empty)
    XCTAssertEqual(Probe.outcome(DiscoveryOutcome(path: "prepared_model"), appHints: 0), .empty)
  }

  // MARK: Degenerate repair

  func testRuntimesThatBuildTheirTreeLateClimbTheReadinessLadder() {
    for engine: AppTraits.Engine in [.chromium, .gecko, .flutter] {
      XCTAssertTrue(AppTraits(engine: engine).buildsAccessibilityTreeAsynchronously)
      XCTAssertEqual(
        AppMonitor.degenerateRepair(
          engine: engine, afterVolatileDecline: false, lastHealthy: 90, knownEmpty: false),
        .readinessLadder(ReadinessLadder.delaysMs), "\(engine)")
      XCTAssertEqual(
        AppMonitor.degenerateRepair(
          engine: engine, afterVolatileDecline: false, lastHealthy: nil, knownEmpty: false),
        .readinessLadder(ReadinessLadder.delaysMs), "a freshly launched app has no history yet")
    }
    XCTAssertFalse(AppTraits().buildsAccessibilityTreeAsynchronously)
    XCTAssertEqual(
      AppMonitor.degenerateRepair(
        engine: nil, afterVolatileDecline: false, lastHealthy: 90, knownEmpty: false),
      .retry(afterMs: AppMonitor.activationRetryDelayMs))
    XCTAssertEqual(
      AppMonitor.degenerateRepair(
        engine: nil, afterVolatileDecline: false, lastHealthy: nil, knownEmpty: false),
      .retry(afterMs: AppMonitor.activationRetryDelayMs))
  }

  func testATerminalKnownToWalkEmptyIsWalkedOnce() {
    // tmux declined and the app's own tree has only ever walked empty: the
    // empty walk is the answer, so no retry and no ladder.
    XCTAssertEqual(
      AppMonitor.degenerateRepair(
        engine: nil, afterVolatileDecline: true, lastHealthy: nil, knownEmpty: true),
      .none)
    XCTAssertEqual(
      AppMonitor.degenerateRepair(
        engine: .chromium, afterVolatileDecline: true, lastHealthy: nil, knownEmpty: true),
      .none)
    // A terminal whose AX tree has yielded targets before (iTerm2) is repaired.
    XCTAssertEqual(
      AppMonitor.degenerateRepair(
        engine: nil, afterVolatileDecline: true, lastHealthy: 30, knownEmpty: true),
      .retry(afterMs: AppMonitor.activationRetryDelayMs))
  }

  func testAFirstEmptyWalkAfterAVolatileDeclineIsStillRepaired() {
    // No history either way: the tree may still be building, so the first
    // activation gets the usual repair instead of ending on a transient empty.
    XCTAssertEqual(
      AppMonitor.degenerateRepair(
        engine: nil, afterVolatileDecline: true, lastHealthy: nil, knownEmpty: false),
      .retry(afterMs: AppMonitor.activationRetryDelayMs))
    XCTAssertEqual(
      AppMonitor.degenerateRepair(
        engine: .chromium, afterVolatileDecline: true, lastHealthy: nil, knownEmpty: false),
      .readinessLadder(ReadinessLadder.delaysMs))
  }

  func testTheGateRecordsEvidenceOfEmptyWalks() {
    var gate = EmptyBackgroundWalkGate()
    XCTAssertFalse(gate.hasEmptyEvidence(7))
    _ = gate.noteBackgroundWalk(pid: 7, targets: 0, hasVolatileProvider: true)
    XCTAssertTrue(gate.hasEmptyEvidence(7))
    _ = gate.noteBackgroundWalk(pid: 7, targets: 3, hasVolatileProvider: true)
    XCTAssertFalse(gate.hasEmptyEvidence(7), "a walk with targets clears the evidence")
  }

  func testTheLadderIsBoundedAndWalksAtItsLastStep() {
    let delays = ReadinessLadder.delaysMs
    XCTAssertEqual(delays, [50, 100, 200, 400, 750])
    XCTAssertLessThanOrEqual(delays.reduce(0, +), 1_500)
    XCTAssertEqual(delays, delays.sorted(), "each wait at least as long as the last")
    for step in delays.indices.dropLast() {
      XCTAssertTrue(ReadinessLadder.probesBeforeWalking(step: step), "step \(step)")
    }
    XCTAssertFalse(ReadinessLadder.probesBeforeWalking(step: delays.count - 1))
    XCTAssertEqual(ReadinessLadder.delayMs(step: 0), 50)
    XCTAssertEqual(ReadinessLadder.delayMs(step: delays.count - 1), 750)
    XCTAssertNil(ReadinessLadder.delayMs(step: delays.count))
    XCTAssertNil(ReadinessLadder.delayMs(step: -1))
  }

  func testOnlyAsynchronousTreesDeferTheirFocusWalk() {
    typealias M = AppMonitor
    XCTAssertTrue(
      M.focusRefreshAwaitsReadiness(traits: AppTraits(engine: .chromium), onDemand: false))
    XCTAssertTrue(M.focusRefreshAwaitsReadiness(traits: AppTraits(engine: .gecko), onDemand: false))
    XCTAssertFalse(M.focusRefreshAwaitsReadiness(traits: AppTraits(), onDemand: false))
    XCTAssertFalse(M.focusRefreshAwaitsReadiness(traits: nil, onDemand: false), "traits unread")
    XCTAssertFalse(
      M.focusRefreshAwaitsReadiness(traits: AppTraits(engine: .chromium), onDemand: true),
      "an on-demand app is never warmed, so there is nothing to wait for")
  }

  // MARK: Readiness probe

  func testReadinessIsAWebAreaWithContentOrASubstantialWindow() {
    typealias R = AccessibilityReadiness
    XCTAssertFalse(R.isReady(nil), "no window yet")
    // Chromium before its tree is built: the traffic lights and an empty group.
    XCTAssertFalse(R.isReady(.init(windowChildren: 4, webAreaChildren: nil, visited: 5)))
    // The page's web area exists but holds nothing yet.
    XCTAssertFalse(R.isReady(.init(windowChildren: 5, webAreaChildren: 0, visited: 9)))
    XCTAssertTrue(R.isReady(.init(windowChildren: 5, webAreaChildren: 3, visited: 9)))
    // No web area in reach, but more than decorations at the top level…
    XCTAssertTrue(
      R.isReady(.init(windowChildren: R.windowChildThreshold + 1, webAreaChildren: nil, visited: 8))
    )
    XCTAssertFalse(
      R.isReady(.init(windowChildren: R.windowChildThreshold, webAreaChildren: nil, visited: 8)))
    // …or a tree larger than the probe is willing to look at (Flutter).
    XCTAssertTrue(R.isReady(.init(windowChildren: 2, webAreaChildren: nil, visited: R.visitBudget)))
  }

  // MARK: Empty background walk gate

  func testConsecutiveEmptyWalksBehindAVolatileProviderCloseTheGateOnce() {
    var gate = EmptyBackgroundWalkGate()
    let pid = pid_t(7)
    for walk in 1..<EmptyBackgroundWalkGate.threshold {
      XCTAssertFalse(gate.noteBackgroundWalk(pid: pid, targets: 0, hasVolatileProvider: true))
      XCTAssertFalse(gate.isGated(pid), "walk \(walk)")
    }
    XCTAssertTrue(gate.noteBackgroundWalk(pid: pid, targets: 0, hasVolatileProvider: true))
    XCTAssertTrue(gate.isGated(pid))
    // Logged once: a further empty walk does not close it again.
    XCTAssertFalse(gate.noteBackgroundWalk(pid: pid, targets: 0, hasVolatileProvider: true))
    XCTAssertTrue(gate.isGated(pid))
  }

  func testTargetsOrNoVolatileProviderResetTheStreak() {
    var gate = EmptyBackgroundWalkGate()
    let pid = pid_t(8)
    for _ in 1..<EmptyBackgroundWalkGate.threshold {
      _ = gate.noteBackgroundWalk(pid: pid, targets: 0, hasVolatileProvider: true)
    }
    XCTAssertFalse(gate.noteBackgroundWalk(pid: pid, targets: 3, hasVolatileProvider: true))
    for _ in 1..<EmptyBackgroundWalkGate.threshold {
      _ = gate.noteBackgroundWalk(pid: pid, targets: 0, hasVolatileProvider: true)
    }
    XCTAssertFalse(gate.isGated(pid))

    // An app with no volatile provider (iTerm2 without the tmux plugin, any
    // ordinary app) is never gated however empty it walks.
    var plain = EmptyBackgroundWalkGate()
    for _ in 0..<(EmptyBackgroundWalkGate.threshold * 2) {
      XCTAssertFalse(plain.noteBackgroundWalk(pid: pid, targets: 0, hasVolatileProvider: false))
    }
    XCTAssertFalse(plain.isGated(pid))
  }

  func testActivationTargetsConfigChangesAndTerminationReopenTheGate() {
    func closed(_ pid: pid_t) -> EmptyBackgroundWalkGate {
      var gate = EmptyBackgroundWalkGate()
      for _ in 0..<EmptyBackgroundWalkGate.threshold {
        _ = gate.noteBackgroundWalk(pid: pid, targets: 0, hasVolatileProvider: true)
      }
      XCTAssertTrue(gate.isGated(pid))
      return gate
    }
    var byActivation = closed(9)
    XCTAssertTrue(byActivation.noteActivationTargets(pid: 9))
    XCTAssertFalse(byActivation.isGated(9))
    XCTAssertFalse(byActivation.noteActivationTargets(pid: 9), "already open")
    // The streak starts over: one empty walk does not close it again.
    XCTAssertFalse(byActivation.noteBackgroundWalk(pid: 9, targets: 0, hasVolatileProvider: true))
    XCTAssertFalse(byActivation.isGated(9))

    var byConfig = closed(10)
    byConfig.reset()
    XCTAssertFalse(byConfig.isGated(10))

    var byTermination = closed(11)
    byTermination.forget(pid: 11)
    XCTAssertFalse(byTermination.isGated(11))
  }
}
