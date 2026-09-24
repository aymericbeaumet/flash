import Foundation

struct StatusJobSchedule: Equatable {
  enum Phase: Equatable {
    case idle(dueAt: TimeInterval)
    case running(token: UInt64, startedAt: TimeInterval, nextDueAt: TimeInterval)
  }

  private(set) var phase: Phase = .idle(dueAt: -.infinity)

  var dueAt: TimeInterval? {
    guard case .idle(let dueAt) = phase else { return nil }
    return dueAt
  }

  var startedAt: TimeInterval? {
    guard case .running(_, let startedAt, _) = phase else { return nil }
    return startedAt
  }

  func owns(_ token: UInt64) -> Bool {
    guard case .running(let current, _, _) = phase else { return false }
    return current == token
  }

  mutating func begin(token: UInt64, now: TimeInterval, interval: TimeInterval) -> Bool {
    guard let dueAt, dueAt <= now else { return false }
    phase = .running(
      token: token, startedAt: now,
      nextDueAt: interval > 0 ? now + interval : .infinity)
    return true
  }

  @discardableResult
  mutating func complete(_ token: UInt64) -> Bool {
    guard case .running(let current, _, let dueAt) = phase, current == token else { return false }
    phase = .idle(dueAt: dueAt)
    return true
  }

  mutating func reschedule(now: TimeInterval, interval: TimeInterval) {
    let due = interval > 0 ? now + interval : .infinity
    switch phase {
    case .idle: phase = .idle(dueAt: due)
    case .running(let token, let start, _):
      phase = .running(token: token, startedAt: start, nextDueAt: due)
    }
  }
}

protocol StatusCommandTask: AnyObject {
  func cancel()
}

extension StatusFormatCommandJob: StatusCommandTask {}

struct StatusCommandInvocation {
  let argv: [String]
  let environment: [String: String]
  let workingDirectory: String?
  let timeoutSeconds: TimeInterval?
}

/// Factories enqueue callbacks on the supplied serial queue after returning.
typealias StatusCommandFactory = (
  StatusCommandInvocation, DispatchQueue, @escaping (String) -> Void,
  @escaping (Int32, String) -> Void
) throws -> any StatusCommandTask
