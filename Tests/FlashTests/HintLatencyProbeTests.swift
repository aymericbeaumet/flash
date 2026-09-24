import FlashCore
import XCTest

@testable import flash

final class HintLatencyProbeTests: XCTestCase {
  func testAnInteractionDatesFromItsInputsOwnTimestamp() {
    Trace.begin(.key, triggeredAt: 12.5) {
      XCTAssertEqual(Trace.currentTrigger?.origin, .key)
      XCTAssertEqual(Trace.currentTrigger?.uptime, 12.5)
      XCTAssertEqual(Trace.currentTrigger?.id, Trace.current)
    }
    XCTAssertNil(Trace.currentTrigger)

    // A Carbon hotkey or AppleEvent reads its time before the interaction
    // begins.
    Trace.triggered(at: 3) {
      Trace.ensure(.hotkey) { XCTAssertEqual(Trace.currentTrigger?.uptime, 3) }
    }
    let before = ProcessInfo.processInfo.systemUptime
    Trace.begin(.cli) {
      XCTAssertGreaterThanOrEqual(Trace.currentTrigger?.uptime ?? 0, before)
    }
  }

  func testWorkReenteredOnALaterTurnHasNoTrigger() {
    var captured: Trace.ID?
    Trace.begin(.key, triggeredAt: 1) { captured = Trace.current }
    Trace.run(in: captured) {
      XCTAssertEqual(Trace.current, captured)
      XCTAssertNil(Trace.currentTrigger, "a later turn is not the trigger's")
    }
  }

  func testOnlyKeysHotkeysAndCLIVerbsArmTheProbe() {
    for origin: Trace.Origin in [.key, .hotkey, .cli] {
      Trace.begin(origin, triggeredAt: 2) {
        let probe = HintLatencyProbe.arm(Trace.currentTrigger)
        XCTAssertEqual(probe?.origin, origin)
        XCTAssertEqual(probe?.triggeredAt, 2)
      }
    }
    for origin: Trace.Origin in [.pointer, .commandLine] {
      Trace.begin(origin) { XCTAssertNil(HintLatencyProbe.arm(Trace.currentTrigger)) }
    }
    XCTAssertNil(HintLatencyProbe.arm(nil))
  }

  func testAppClassComesFromTheRuntime() {
    XCTAssertEqual(HintLatencyProbe.appClass(nil), .other)
    XCTAssertEqual(HintLatencyProbe.appClass(AppTraits()), .native)
    XCTAssertEqual(
      HintLatencyProbe.appClass(AppTraits(isWebBrowser: true, engine: .chromium)), .browser)
    XCTAssertEqual(
      HintLatencyProbe.appClass(AppTraits(isWebBrowser: true, engine: .gecko)), .browser)
    XCTAssertEqual(HintLatencyProbe.appClass(AppTraits(engine: .chromium)), .electron)
    XCTAssertEqual(HintLatencyProbe.appClass(AppTraits(engine: .flutter)), .other)
  }

  /// `Scripts/hints-latency-summary.py` parses exactly this line.
  func testTheLogLineFormat() throws {
    var probe: HintLatencyProbe?
    Trace.begin(.key, triggeredAt: 10) { probe = HintLatencyProbe.arm(Trace.currentTrigger) }
    let line = try XCTUnwrap(probe).line(
      visibleAt: 10.01234, prepared: .hit, targets: 42, appClass: .native, surface: "targets")
    XCTAssertEqual(
      line,
      "[latency] hints_visible ms=12.3 origin=key prepared=hit targets=42 class=native "
        + "surface=targets")
  }
}
