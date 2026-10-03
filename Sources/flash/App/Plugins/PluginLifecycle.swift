import Foundation

/// Pure ownership model for one plugin definition. Every attempt and delayed
/// effect belongs to a generation; stopping or replacing it invalidates all
/// outstanding work, including work that has not spawned a child yet.
struct PluginLifecycle {
  enum State: Equatable {
    case initial, idle, installing, launching, running, backoff, stopped, failed
  }

  enum Event {
    case start(resident: Bool)
    case activate
    case reload(resident: Bool)
    case installed(UInt64)
    case initialized(UInt64)
    case interrupted(UInt64)
    case retry(UInt64)
    case reject(UInt64)
    case stop
  }

  enum Effect: Equatable {
    case teardown
    case start(UInt64)
    case retry(UInt64, Int)
    case park
  }

  private(set) var state: State = .initial
  private(set) var generation: UInt64 = 0
  private(set) var failures: [TimeInterval] = []

  var runtimeState: PluginRuntimeState {
    switch state {
    case .initial, .idle, .backoff, .stopped: return .stopped
    case .installing: return .installing
    case .launching: return .launching
    case .running: return .running
    case .failed: return .failed
    }
  }

  mutating func transition(
    _ event: Event, now: TimeInterval, restartLimit: Int,
    restartWindow: TimeInterval, restartDelay: (Int) -> Int
  ) -> [Effect] {
    switch event {
    case .start(let resident):
      guard state == .initial || state == .stopped else { return [] }
      state = .idle
      return resident ? begin() : []
    case .activate:
      guard state == .idle || state == .initial else { return [] }
      return begin()
    case .reload(let resident):
      generation &+= 1
      failures.removeAll()
      state = .idle
      return [.teardown] + (resident ? begin() : [])
    case .installed(let token):
      guard token == generation, state == .installing else { return [] }
      state = .launching
      return []
    case .initialized(let token):
      guard token == generation, state == .launching else { return [] }
      state = .running
      // A handshake is not evidence of sustained health. Failures expire
      // from the rolling window when the next failure is observed.
      return []
    case .interrupted(let token):
      guard token == generation,
        state == .installing || state == .launching || state == .running
      else { return [] }
      failures.removeAll { $0 < now - restartWindow }
      failures.append(now)
      if failures.count > restartLimit {
        state = .failed
        return [.teardown, .park]
      }
      state = .backoff
      return [.teardown, .retry(generation, restartDelay(failures.count - 1))]
    case .retry(let token):
      guard token == generation, state == .backoff else { return [] }
      return begin()
    case .reject(let token):
      guard token == generation, state != .stopped else { return [] }
      state = .failed
      return [.teardown, .park]
    case .stop:
      generation &+= 1
      state = .stopped
      return [.teardown]
    }
  }

  private mutating func begin() -> [Effect] {
    generation &+= 1
    state = .installing
    return [.start(generation)]
  }
}
