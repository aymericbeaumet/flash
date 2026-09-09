import XCTest

@testable import flash

final class ModeStoreTests: XCTestCase {
  func testNestedEventWaitsUntilCurrentEffectsFinish() {
    let store = ModeStore(initial: .normal)
    var observed: [Mode] = []
    store.perform = { _, _, next in
      observed.append(next)
      if next == .insert {
        store.dispatch(.openTerminal)
        XCTAssertEqual(store.mode, .insert)
        observed.append(store.mode)
      }
    }
    store.dispatch(.enterInsert(targetPID: nil))
    XCTAssertEqual(observed, [.insert, .insert, .terminal(restoreTo: .insert)])
    XCTAssertEqual(store.mode, .terminal(restoreTo: .insert))
  }

  func testConfigReconciliationDoesNotPerformModeEntry() {
    let store = ModeStore(initial: .normal)
    var entries = 0
    var renders = 0
    store.perform = { effects, _, _ in
      entries += effects.filter { $0 == .prepareModeEntry }.count
      renders += effects.filter { $0 == .renderSurface }.count
    }
    store.dispatch(.advancedModeChanged(enabled: true))
    XCTAssertEqual(entries, 0, "Refreshing labels must preserve native input ownership")
    XCTAssertEqual(renders, 1)
    store.dispatch(.enterNormal(targetPID: nil))
    XCTAssertEqual(entries, 1, "An explicit entry resets transient capture context")
  }
}
