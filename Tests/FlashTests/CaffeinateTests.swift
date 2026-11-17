import IOKit.pwr_mgt
import XCTest

@testable import flash

/// The core keep-awake: the pure transitions, the verbs, and the controller
/// against stubbed power assertions and a hand-fired expiry, so no test holds
/// the machine awake or waits out a bound.
final class CaffeinateTests: XCTestCase {
  private final class StubPower: PowerAssertionProviding {
    var acquired: [Int?] = []
    var released: [[IOPMAssertionID]] = []
    var nextID: IOPMAssertionID = 1
    var failure: CaffeinateError?

    func acquire(seconds: Int?) throws -> [IOPMAssertionID] {
      if let failure { throw failure }
      acquired.append(seconds)
      defer { nextID += 1 }
      return [nextID]
    }
    func release(_ assertions: [IOPMAssertionID]) { released.append(assertions) }
  }

  private final class StubExpiry {
    var armed: [(afterMs: Int, body: () -> Void)] = []
    var cancels = 0

    var expiry: CaffeinateController.Expiry {
      CaffeinateController.Expiry(
        arm: { [unowned self] afterMs, body in self.armed.append((afterMs, body)) },
        cancel: { [unowned self] in self.cancels += 1 })
    }
  }

  // MARK: - Transitions

  func testToggleStartsAnUnboundedHoldAndReleasesIt() {
    var state = CaffeinateState()
    XCTAssertEqual(state.apply(.status), [])
    XCTAssertEqual(state.apply(.off), [], "off with nothing held does nothing")
    let on = state.apply(.toggle(minutes: nil))
    guard case .acquire(let hold)? = on.first, on.count == 1 else {
      return XCTFail("expected one acquisition, got \(on)")
    }
    XCTAssertNil(hold.seconds)
    XCTAssertTrue(state.isOn)
    XCTAssertEqual(state.apply(.status), [])
    XCTAssertEqual(state.apply(.toggle(minutes: 5)), [.release], "toggle ignores minutes to stop")
    XCTAssertFalse(state.isOn)
  }

  func testOnReplacesTheHoldSoTheNewBoundCountsFromNow() {
    var state = CaffeinateState()
    guard case .acquire(let timed)? = state.apply(.on(minutes: 5)).first else {
      return XCTFail("expected an acquisition")
    }
    XCTAssertEqual(timed.seconds, 300)
    let replaced = state.apply(.on(minutes: nil))
    XCTAssertEqual(replaced.count, 2)
    XCTAssertEqual(replaced.first, .release)
    guard case .acquire(let unbounded)? = replaced.last else {
      return XCTFail("expected a new acquisition, got \(replaced)")
    }
    XCTAssertNil(unbounded.seconds)
    XCTAssertNotEqual(unbounded.generation, timed.generation)
    XCTAssertEqual(state.hold, unbounded)
  }

  /// A replaced hold's bound must not end its successor.
  func testOnlyTheCurrentHoldExpires() {
    var state = CaffeinateState()
    guard case .acquire(let first)? = state.apply(.on(minutes: 1)).first else {
      return XCTFail("expected an acquisition")
    }
    guard case .acquire(let second)? = state.apply(.on(minutes: 2)).last else {
      return XCTFail("expected an acquisition")
    }
    XCTAssertEqual(state.expire(first.generation), [])
    XCTAssertEqual(state.hold, second)
    XCTAssertEqual(state.expire(second.generation), [.release])
    XCTAssertNil(state.hold)
    XCTAssertEqual(state.expire(second.generation), [], "an expired hold expires once")
  }

  func testAFailedAcquisitionHoldsNothing() {
    var state = CaffeinateState()
    guard case .acquire(let hold)? = state.apply(.on(minutes: nil)).first else {
      return XCTFail("expected an acquisition")
    }
    state.acquisitionFailed(hold.generation &+ 1)
    XCTAssertTrue(state.isOn, "a stale failure leaves the hold alone")
    state.acquisitionFailed(hold.generation)
    XCTAssertFalse(state.isOn)
  }

  // MARK: - Commands

  func testCommandsParseAndRoundTripTheirMinutes() {
    let cases: [(String, URLCommand)] = [
      ("caffeinate on", .caffeinate(.on(minutes: nil))),
      ("caffeinate on --minutes=30", .caffeinate(.on(minutes: 30))),
      ("caffeinate off", .caffeinate(.off)),
      ("caffeinate toggle", .caffeinate(.toggle(minutes: nil))),
      ("caffeinate toggle --minutes=1", .caffeinate(.toggle(minutes: 1))),
      ("caffeinate status", .caffeinate(.status)),
    ]
    for (text, command) in cases {
      let words = text.split(separator: " ").map(String.init)
      XCTAssertEqual(parseMappingCommand(argv: ["flash"] + words), .flashCommand(command), text)
      XCTAssertEqual(command.diagnosticDescription, "flash " + text)
      XCTAssertEqual(NormalModeDispatcher.commandLineCoreCommand(":" + text), command, text)
    }
    let largest = "--minutes=\(CaffeinateRequest.maximumMinutes)"
    XCTAssertEqual(
      parseMappingCommand(argv: ["flash", "caffeinate", "on", largest]),
      .flashCommand(.caffeinate(.on(minutes: CaffeinateRequest.maximumMinutes))))
    for minutes in ["0", "-5", "1h", "", "\(CaffeinateRequest.maximumMinutes + 1)"] {
      for action in ["on", "toggle"] {
        XCTAssertNil(
          parseMappingCommand(argv: ["flash", "caffeinate", action, "--minutes=\(minutes)"]),
          "\(action) \(minutes)")
      }
    }
    XCTAssertNil(parseMappingCommand(argv: ["flash", "caffeinate", "off", "--minutes=5"]))
    XCTAssertNil(parseMappingCommand(argv: ["flash", "caffeinate", "status", "--minutes=5"]))
  }

  /// The plugin's positional words are gone, with no alias.
  func testRetiredCaffeinatePluginWordsAreRejected() {
    for argv in [["flash", "caffeinate", "on", "5"], ["flash", "caffeinate"]] {
      XCTAssertNil(parseMappingCommand(argv: argv), "\(argv)")
    }
    XCTAssertNil(NormalModeDispatcher.commandLineCoreCommand(":caffeinate on 5"))
    XCTAssertFalse(PluginRepository.declaresCommand("caffeinate"))
    let config = ConfigLoader.parse(
      """
      [mode.normal.mappings]
      "<leader>c" = ["flash", "caffeinate", "on", "5"]
      "<leader>a" = ["flash", "caffeinate", "toggle"]
      """)
    XCTAssertTrue(
      config.loadingDiagnostics.contains { $0.message.contains("<leader>c") },
      "\(config.loadingDiagnostics.map(\.message))")
    XCTAssertTrue(
      config.mode.normal.contains {
        $0.action == .flashCommand(.caffeinate(.toggle(minutes: nil)))
      })
  }

  func testTheStatusValueIsOnWhileHeld() {
    let held = FlashStatusBarTemplateEngine.formatContext(FlashStatusBarContext(caffeinate: true))
    XCTAssertEqual(held.values["flash.caffeinate"], "on")
    let free = FlashStatusBarTemplateEngine.formatContext(FlashStatusBarContext())
    XCTAssertEqual(free.values["flash.caffeinate"], "")
    XCTAssertEqual(FlashStatusBarTemplateEngine.sdkValue(for: "flash.caffeinate"), .caffeinate)
  }

  // MARK: - Controller

  private func perform(
    _ controller: CaffeinateController, _ request: CaffeinateRequest
  ) -> Result<Bool, CaffeinateError> {
    let done = expectation(description: "\(request)")
    var result: Result<Bool, CaffeinateError>?
    controller.perform(request) {
      result = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    return result ?? .failure(.assertion(kIOReturnTimeout))
  }

  /// Let the main-queue `onChange` hops that precede this point run.
  private func drainMain() {
    let drained = expectation(description: "main drained")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 5)
  }

  func testABoundedHoldArmsItsExpiryAndReleasesWhenItFires() {
    let queue = DispatchQueue(label: "caffeinate-test")
    let power = StubPower()
    let expiry = StubExpiry()
    var changes: [Bool] = []
    let controller = CaffeinateController(
      queue: queue, power: power, expiry: expiry.expiry, onChange: { changes.append($0) })

    XCTAssertEqual(perform(controller, .on(minutes: 2)), .success(true))
    XCTAssertEqual(power.acquired, [120])
    XCTAssertEqual(expiry.armed.map(\.afterMs), [120_000])
    drainMain()
    XCTAssertEqual(changes, [true])

    queue.sync { expiry.armed[0].body() }
    drainMain()
    XCTAssertEqual(power.released, [[1]])
    XCTAssertEqual(changes, [true, false])
    XCTAssertEqual(perform(controller, .status), .success(false))
  }

  func testReplacingAHoldCancelsItsExpiryAndIgnoresItsLateFire() {
    let queue = DispatchQueue(label: "caffeinate-test")
    let power = StubPower()
    let expiry = StubExpiry()
    var changes: [Bool] = []
    let controller = CaffeinateController(
      queue: queue, power: power, expiry: expiry.expiry, onChange: { changes.append($0) })

    XCTAssertEqual(perform(controller, .on(minutes: 1)), .success(true))
    XCTAssertEqual(perform(controller, .on(minutes: nil)), .success(true))
    XCTAssertEqual(power.acquired, [60, nil])
    XCTAssertEqual(power.released, [[1]])
    XCTAssertEqual(expiry.cancels, 1)
    XCTAssertEqual(expiry.armed.count, 1, "an unbounded hold arms nothing")

    queue.sync { expiry.armed[0].body() }
    XCTAssertEqual(power.released, [[1]], "the replaced hold's fire releases nothing")
    XCTAssertEqual(perform(controller, .status), .success(true))

    XCTAssertEqual(perform(controller, .toggle(minutes: nil)), .success(false))
    XCTAssertEqual(power.released, [[1], [2]])
    drainMain()
    XCTAssertEqual(changes, [true, false])
  }

  func testAFailedAssertionReportsAndHoldsNothing() {
    let queue = DispatchQueue(label: "caffeinate-test")
    let power = StubPower()
    power.failure = .assertion(kIOReturnNoMemory)
    let expiry = StubExpiry()
    var changes: [Bool] = []
    let controller = CaffeinateController(
      queue: queue, power: power, expiry: expiry.expiry, onChange: { changes.append($0) })

    XCTAssertEqual(perform(controller, .on(minutes: 5)), .failure(.assertion(kIOReturnNoMemory)))
    XCTAssertTrue(expiry.armed.isEmpty)
    XCTAssertEqual(perform(controller, .status), .success(false))
    drainMain()
    XCTAssertEqual(changes, [])
  }

  func testShutdownReleasesTheHold() {
    let queue = DispatchQueue(label: "caffeinate-test")
    let power = StubPower()
    let expiry = StubExpiry()
    let controller = CaffeinateController(
      queue: queue, power: power, expiry: expiry.expiry, onChange: { _ in })
    XCTAssertEqual(perform(controller, .on(minutes: 30)), .success(true))
    controller.shutdown()
    XCTAssertEqual(power.released, [[1]])
    XCTAssertEqual(expiry.cancels, 1)
  }

  /// The production expiry is one deadline on the shared clock: it fires on
  /// the controller's queue, and a cancelled one never fires.
  func testThePollExpiryFiresOnTheControllerQueueAndCancels() {
    let queue = DispatchQueue(label: "caffeinate-test")
    let expiry = CaffeinateController.Expiry.poll(on: queue, scheduler: PollScheduler())
    let fired = expectation(description: "the armed expiry fires")
    queue.async {
      expiry.arm(10) {
        dispatchPrecondition(condition: .onQueue(queue))
        fired.fulfill()
      }
    }
    wait(for: [fired], timeout: 5)

    let cancelled = expectation(description: "a cancelled expiry fires")
    cancelled.isInverted = true
    queue.async {
      expiry.arm(10) { cancelled.fulfill() }
      expiry.cancel()
    }
    wait(for: [cancelled], timeout: 1.5)
  }

  /// `flash caffeinate status` prints the state; on, off and toggle print
  /// the state they left and still show it, being changes, not questions.
  func testTheStateIsEveryRequestsOutput() {
    XCTAssertEqual(CaffeinateRequest.status.output(on: true), "caffeinate on")
    XCTAssertEqual(CaffeinateRequest.off.output(on: false), "caffeinate off")
    XCTAssertFalse(CaffeinateRequest.status.showsWherever)
    for request in [CaffeinateRequest.on(minutes: nil), .off, .toggle(minutes: 5)] {
      XCTAssertTrue(request.showsWherever, "\(request)")
    }
  }
}
