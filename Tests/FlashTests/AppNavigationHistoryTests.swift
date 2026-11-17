import XCTest

@testable import flash

/// `app next` / `app previous` and the refocus after a quit, over the app
/// MRU as one value.
final class AppNavigationHistoryTests: XCTestCase {
  private typealias History = AppNavigationHistory

  func testAVisitMovesTheAppToTheFrontAndDropsWhatWasAhead() {
    var history = History(current: 10)
    history.record(20)
    history.record(30)
    XCTAssertEqual(history, History(current: 30, back: [10, 20]))
    history.record(10)
    XCTAssertEqual(history, History(current: 10, back: [20, 30]))
    history.record(10)
    XCTAssertEqual(history, History(current: 10, back: [20, 30]), "the same app again is no visit")
  }

  func testANavigationsActivationLandsItWithoutReorderingTheRing() throws {
    var history = History(current: 30, back: [10, 20])
    let navigated = try XCTUnwrap(history.navigating(.back, isAvailable: { _ in true }))
    XCTAssertEqual(navigated, History(current: 20, back: [10], forward: [30], target: 20))
    history = navigated
    history.record(20)
    XCTAssertEqual(history, History(current: 20, back: [10], forward: [30]))
  }

  func testNavigationSwitchesInEitherDirectionWithBackHistoryOnly() throws {
    let available: Set<pid_t> = [10, 20]
    let history = History(current: 20, back: [10])
    XCTAssertEqual(history.navigating(.back, isAvailable: available.contains)?.target, 10)
    XCTAssertEqual(history.navigating(.forward, isAvailable: available.contains)?.target, 10)
    XCTAssertNil(History(current: 20).navigating(.back, isAvailable: available.contains))
    XCTAssertNil(History().navigating(.back, isAvailable: available.contains))
  }

  func testNavigationCyclesAndSkipsUnavailableApps() throws {
    let available: Set<pid_t> = [10, 30]
    let previous = try XCTUnwrap(
      History(current: 30, back: [10, 20]).navigating(.back, isAvailable: available.contains))
    XCTAssertEqual(previous, History(current: 10, forward: [30], target: 10))
    let wrapped = try XCTUnwrap(previous.navigating(.back, isAvailable: available.contains))
    XCTAssertEqual(wrapped.target, 30)
  }

  func testSeedingKeepsTheFocusedAppAndTheTarget() {
    XCTAssertEqual(
      History(current: 30, forward: [40], target: 30).seeded(back: [10, 20]),
      History(current: 30, back: [10, 20], target: 30))
  }

  func testQuittingTheFocusedAppFocusesThePreviousOne() {
    let available: Set<pid_t> = [10, 20, 30]
    XCTAssertEqual(
      History(current: 30, back: [10, 20]).refocusing(
        afterQuitOf: 30, isAvailable: available.contains),
      History(current: 20, back: [10], target: 20))
  }

  func testQuittingReturnsToTheAppJustLeftAheadOfOlderHistory() {
    let available: Set<pid_t> = [10, 30, 40]
    // back once from 40 landed on 30, leaving 40 as the nearest forward entry.
    XCTAssertEqual(
      History(current: 30, back: [10], forward: [40])
        .refocusing(afterQuitOf: 30, isAvailable: available.contains),
      History(current: 40, back: [10], target: 40))
  }

  func testQuittingSkipsADeadAppAndKeepsAnUnrelatedCurrentApp() {
    let alive: Set<pid_t> = [10]
    XCTAssertEqual(
      History(current: 30, back: [10, 20]).refocusing(afterQuitOf: 30, isAvailable: alive.contains),
      History(current: 10, target: 10))
    XCTAssertNil(History(current: 30).refocusing(afterQuitOf: 30, isAvailable: alive.contains))
    XCTAssertEqual(
      History(current: 10, back: [20])
        .refocusing(afterQuitOf: 30, isAvailable: { $0 == 10 || $0 == 20 }),
      History(current: 10, back: [20], target: 10))
  }

  /// A quit app leaves the ring and stops being a navigation's target: a pid
  /// macOS later reuses must not land as that navigation.
  func testForgettingAnAppDropsItEverywhereIncludingAPendingTarget() {
    var history = History(current: 30, back: [10, 20], forward: [40], target: 20)
    history.forget(20, clearingCurrent: false)
    XCTAssertEqual(history, History(current: 30, back: [10], forward: [40]))
    history.forget(30, clearingCurrent: false)
    XCTAssertEqual(history.current, 30, "only a focused quit clears current")
    history.forget(30, clearingCurrent: true)
    XCTAssertEqual(history, History(back: [10], forward: [40]))
  }
}
