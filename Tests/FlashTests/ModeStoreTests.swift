import XCTest

@testable import flash

final class ModeStoreTests: XCTestCase {
  func testNestedEventWaitsUntilCurrentEffectsFinish() {
    let store = ModeStore(initial: .normal(persistent: true))
    var observed: [Mode] = []
    store.perform = { _, _, next in
      observed.append(next)
      if next == .passthrough {
        store.dispatch(.openTerminal)
        XCTAssertEqual(store.mode, .passthrough)
        observed.append(store.mode)
      }
    }
    store.dispatch(.enterPassthrough(targetPID: nil))
    XCTAssertEqual(observed, [.passthrough, .passthrough, .terminal(restoreTo: .passthrough)])
    XCTAssertEqual(store.mode, .terminal(restoreTo: .passthrough))
  }

  func testConfigReconciliationDoesNotPerformModeEntry() {
    let store = ModeStore(initial: .normal(persistent: true))
    var entries = 0
    var renders = 0
    store.perform = { effects, _, _ in
      entries += effects.filter { $0 == .prepareModeEntry }.count
      renders += effects.filter { $0 == .renderSurface }.count
    }
    store.dispatch(.advancedModeChanged(enabled: true))
    XCTAssertEqual(entries, 0, "Refreshing labels must preserve native input ownership")
    XCTAssertEqual(renders, 1)
    store.dispatch(.enterNormal(persistent: true, targetPID: nil))
    XCTAssertEqual(entries, 1, "An explicit entry resets transient capture context")
  }
}
