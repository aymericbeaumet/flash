import FlashCore
import Foundation
import IOKit.pwr_mgt

/// `caffeinate on [--minutes=N]`, `caffeinate off`,
/// `caffeinate toggle [--minutes=N]` and `caffeinate status`.
enum CaffeinateRequest: Hashable {
  case on(minutes: Int?)
  case off
  case toggle(minutes: Int?)
  case status

  /// The largest `--minutes`, as `caffeinate -t` took them: the bound in
  /// milliseconds stays well inside `Int`, so no deadline arithmetic
  /// overflows.
  static let maximumMinutes = Int(UInt32.max)

  /// What the CLI prints and the command line shows once it ran.
  func output(on: Bool) -> String { on ? "caffeinate on" : "caffeinate off" }

  /// On, off and toggle change the state, so their alert shows wherever
  /// they ran; `status` asks, and its caller presents the answer.
  var showsWherever: Bool { self != .status }

  var name: CommandName {
    switch self {
    case .on: return CommandName("caffeinate", "on")
    case .off: return CommandName("caffeinate", "off")
    case .toggle: return CommandName("caffeinate", "toggle")
    case .status: return CommandName("caffeinate", "status")
    }
  }

  var argTokens: [String] {
    switch self {
    case .on(let minutes?), .toggle(let minutes?): return ["--minutes=\(minutes)"]
    default: return []
    }
  }
}

/// The keep-awake as a value: nothing held, or one hold of the power
/// assertions, bounded or not. Transitions are pure and return the effects
/// `CaffeinateController` performs.
struct CaffeinateState: Equatable {
  struct Hold: Equatable {
    /// Tells this hold from every other, so the expiry of one that was
    /// replaced or released cannot end its successor.
    let generation: UInt64
    /// How long it lasts; nil until `caffeinate off`.
    let seconds: Int?
  }

  enum Effect: Equatable {
    /// Release the assertions held now and cancel their expiry.
    case release
    /// Take the assertions for `hold`, and arm its expiry when it is bounded.
    case acquire(Hold)
  }

  private(set) var hold: Hold?
  private var lastGeneration: UInt64 = 0

  var isOn: Bool { hold != nil }

  /// `on` replaces a hold, so a new bound counts from now; `toggle` starts
  /// one only when none is held; `off` and `status` never start one.
  mutating func apply(_ request: CaffeinateRequest) -> [Effect] {
    switch request {
    case .status: return []
    case .off: return stop()
    case .on(let minutes): return start(minutes: minutes)
    case .toggle(let minutes): return isOn ? stop() : start(minutes: minutes)
    }
  }

  /// The bound of hold `generation` ran out. Nothing happens for a hold that
  /// is already gone.
  mutating func expire(_ generation: UInt64) -> [Effect] {
    guard hold?.generation == generation else { return [] }
    return stop()
  }

  /// Taking the assertions of hold `generation` failed: nothing is held.
  mutating func acquisitionFailed(_ generation: UInt64) {
    if hold?.generation == generation { hold = nil }
  }

  private mutating func start(minutes: Int?) -> [Effect] {
    let effects = stop()
    lastGeneration &+= 1
    let next = Hold(generation: lastGeneration, seconds: minutes.map { $0 * 60 })
    hold = next
    return effects + [.acquire(next)]
  }

  private mutating func stop() -> [Effect] {
    guard hold != nil else { return [] }
    hold = nil
    return [.release]
  }
}

enum CaffeinateError: LocalizedError, Equatable {
  case assertion(IOReturn)

  var errorDescription: String? {
    switch self {
    case .assertion(let status):
      return "caffeinate: power assertion failed (\(String(format: "0x%08x", status)))"
    }
  }
}

/// Power-management assertions, behind a seam so the keep-awake is tested
/// without holding the test machine awake.
protocol PowerAssertionProviding {
  /// Take every assertion `caffeinate -dimsu` takes; `seconds` bounds them.
  func acquire(seconds: Int?) throws -> [IOPMAssertionID]
  func release(_ assertions: [IOPMAssertionID])
}

/// What `/usr/bin/caffeinate -dimsu [-t seconds]` holds: the display (`-d`),
/// idle system sleep (`-i`), the disk (`-m`), system sleep on AC (`-s`), and
/// a user-activity declaration that wakes the display (`-u`). A bound is
/// powerd's own timeout, which turns the assertions off at the deadline even
/// while Flash's polls are held for a locked screen.
struct IOKitPowerAssertions: PowerAssertionProviding {
  static let name = "Flash caffeinate" as CFString
  static let types = [
    "PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep", "PreventDiskIdle",
    "PreventSystemSleep",
  ]

  func acquire(seconds: Int?) throws -> [IOPMAssertionID] {
    var taken: [IOPMAssertionID] = []
    for type in Self.types {
      var id = IOPMAssertionID(kIOPMNullAssertionID)
      let status = IOPMAssertionCreateWithDescription(
        type as CFString, Self.name, nil, nil, nil, CFTimeInterval(seconds ?? 0), nil, &id)
      guard status == kIOReturnSuccess else {
        release(taken)
        throw CaffeinateError.assertion(status)
      }
      taken.append(id)
    }
    var activity = IOPMAssertionID(kIOPMNullAssertionID)
    if IOPMAssertionDeclareUserActivity(Self.name, kIOPMUserActiveLocal, &activity)
      == kIOReturnSuccess
    {
      taken.append(activity)
    }
    return taken
  }

  func release(_ assertions: [IOPMAssertionID]) {
    for id in assertions { IOPMAssertionRelease(id) }
  }
}

/// Owns the resident's keep-awake. The state and every assertion call stay
/// on one serial queue, off the main thread. A bounded hold arms a deadline
/// on the shared clock (`PollScheduler`); when it fires, the hold is released
/// and `#{flash.caffeinate}` clears. The assertions belong to the resident
/// process, so they end with it as well as at `shutdown`.
final class CaffeinateController {
  /// The bounded hold's expiry, armed and cancelled on the controller's
  /// queue and firing there.
  struct Expiry {
    var arm: (_ afterMs: Int, _ body: @escaping () -> Void) -> Void
    var cancel: () -> Void

    /// One `PollDeadline` on `queue`, armed only while a bounded hold lasts.
    /// `low`: powerd already enforces the bound, so a late tick only delays
    /// the status value.
    static func poll(on queue: DispatchQueue, scheduler: PollScheduler = .shared) -> Expiry {
      let deadline = PollDeadline(
        "core:caffeinate", priority: .low, on: queue, scheduler: scheduler)
      return Expiry(
        arm: { afterMs, body in deadline.arm(afterMs: afterMs, body) },
        cancel: { deadline.cancel() })
    }
  }

  private let queue: DispatchQueue
  private let power: any PowerAssertionProviding
  private let expiry: Expiry
  /// On main, with whether the Mac is held awake, whenever that changes.
  private let onChange: (Bool) -> Void
  private var state = CaffeinateState()
  private var held: [IOPMAssertionID] = []

  init(
    queue: DispatchQueue = DispatchQueue(label: "flash.caffeinate", qos: .userInitiated),
    power: any PowerAssertionProviding = IOKitPowerAssertions(),
    expiry: Expiry? = nil,
    onChange: @escaping (Bool) -> Void
  ) {
    self.queue = queue
    self.power = power
    self.expiry = expiry ?? .poll(on: queue)
    self.onChange = onChange
  }

  /// Apply `request`; `completion` gets whether the Mac is now held awake,
  /// on main.
  func perform(
    _ request: CaffeinateRequest, completion: @escaping (Result<Bool, CaffeinateError>) -> Void
  ) {
    queue.async { [self] in
      let result = transition { $0.apply(request) }
      DispatchQueue.main.async { completion(result) }
    }
  }

  /// Release whatever is held, before the resident exits.
  func shutdown() {
    queue.sync { _ = transition { $0.apply(.off) } }
  }

  /// On the queue: one transition, its effects, and the change it made.
  private func transition(
    _ change: (inout CaffeinateState) -> [CaffeinateState.Effect]
  ) -> Result<Bool, CaffeinateError> {
    let wasOn = state.isOn
    var failure: CaffeinateError?
    for effect in change(&state) {
      switch effect {
      case .release:
        expiry.cancel()
        power.release(held)
        held = []
      case .acquire(let hold):
        do {
          held = try power.acquire(seconds: hold.seconds)
        } catch {
          state.acquisitionFailed(hold.generation)
          failure = error as? CaffeinateError ?? .assertion(kIOReturnError)
          continue
        }
        if let seconds = hold.seconds {
          expiry.arm(seconds * 1000) { [weak self] in
            guard let self else { return }
            _ = self.transition { $0.expire(hold.generation) }
          }
        }
      }
    }
    let isOn = state.isOn
    if isOn != wasOn {
      FlashLog.info("[caffeinate] \(isOn ? "on" : "off")", source: "core:Caffeinate")
      DispatchQueue.main.async { [onChange] in onChange(isOn) }
    }
    if let failure { return .failure(failure) }
    return .success(isOn)
  }
}
