import XCTest

@testable import flash

final class ScriptExecutionGateTests: XCTestCase {
  func testExpiredRequestNeverEntersTheRuntime() {
    let gate = ScriptExecutionGate()
    let result = gate.perform(control: ScriptControl(timeout: 0)) { true }
    XCTAssertNil(result)
  }

  func testAbandonedOwnerKeepsItsLifetimeUntilTeardownFinishes() {
    let gate = ScriptExecutionGate()
    let owner = ScriptControl(timeout: 30)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let done = expectation(description: "owner closed its component")
    DispatchQueue.global().async {
      let result = gate.perform(control: owner) {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
        return "closed"
      }
      XCTAssertEqual(result, "closed")
      done.fulfill()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
    owner.abandon()
    let started = Date()
    let queued = gate.perform(control: ScriptControl(timeout: 0.05)) { "overlapped" }
    XCTAssertNil(queued, "A caller timeout must not release a component that is still alive")
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    release.signal()
    wait(for: [done], timeout: 5)
    XCTAssertEqual(gate.perform(control: ScriptControl(timeout: 5)) { "next" }, "next")
  }

  func testNextLifetimeCannotStartWhilePreviousAutoreleasePoolIsDraining() {
    let gate = ScriptExecutionGate()
    let closing = DispatchSemaphore(value: 0)
    let allowClose = DispatchSemaphore(value: 0)
    let secondEntered = DispatchSemaphore(value: 0)
    let done = expectation(description: "both lifetimes closed")
    done.expectedFulfillmentCount = 2
    DispatchQueue.global().async {
      _ = gate.perform(control: ScriptControl(timeout: 5)) {
        _ = Unmanaged.passRetained(
          AutoreleaseProbe {
            closing.signal()
            _ = allowClose.wait(timeout: .now() + 5)
          }
        ).autorelease()
      }
      done.fulfill()
    }
    XCTAssertEqual(closing.wait(timeout: .now() + 5), .success)
    DispatchQueue.global().async {
      _ = gate.perform(control: ScriptControl(timeout: 5)) { secondEntered.signal() }
      done.fulfill()
    }
    XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.05), .timedOut)
    allowClose.signal()
    wait(for: [done], timeout: 5)
  }
}

private final class AutoreleaseProbe: NSObject {
  private let onRelease: () -> Void

  init(onRelease: @escaping () -> Void) {
    self.onRelease = onRelease
  }

  deinit { onRelease() }
}
