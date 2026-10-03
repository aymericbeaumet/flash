import Foundation

/// The one clock behind every plugin's idle-liveness probe. A running plugin
/// joins; a `.low` cadence on the shared `PollScheduler` — registered only
/// while at least one plugin runs — asks each member whether it has been
/// silent past `PluginProcess.idleBeforePingMs` with nothing in flight, and
/// that member pings itself. Twenty plugins cost one wake-up per sweep
/// instead of twenty self-re-arming timers, and a chatty plugin costs none.
///
/// The sweep runs at half the idle threshold, so a silent plugin is pinged
/// after between one and one and a half thresholds of silence.
final class PluginLivenessSweep {
  static let shared = PluginLivenessSweep()
  static let clientID = "core:plugin_liveness"

  private struct Member {
    weak var process: PluginProcess?
  }

  private let scheduler: PollScheduler
  private let queue = DispatchQueue(label: "flash.plugin.liveness", qos: .utility)
  /// Queue-confined.
  private var members: [ObjectIdentifier: Member] = [:]
  /// Queue-confined: the registered sweep period, nil while unregistered.
  private var registeredPeriodMs: Int?

  init(scheduler: PollScheduler = .shared) {
    self.scheduler = scheduler
  }

  static func periodMs(idleBeforePingMs: Int) -> Int {
    max(PollScheduler.minimumIntervalMs, idleBeforePingMs / 2)
  }

  /// `process` finished initializing: it is swept until it leaves.
  func join(_ process: PluginProcess) {
    queue.async { [self] in
      members[ObjectIdentifier(process)] = Member(process: process)
      reconcile()
    }
  }

  /// `process` is stopping: it is no longer swept, and the last one to leave
  /// releases the cadence.
  func leave(_ process: PluginProcess) {
    let id = ObjectIdentifier(process)
    queue.async { [self] in
      members.removeValue(forKey: id)
      reconcile()
    }
  }

  private func sweep() {
    members = members.filter { $0.value.process != nil }
    for member in members.values { member.process?.checkIdleLiveness() }
    reconcile()
  }

  /// Registered exactly while a member exists, at the period the current
  /// idle threshold implies.
  private func reconcile() {
    let wanted =
      members.isEmpty
      ? nil : Self.periodMs(idleBeforePingMs: PluginProcess.idleBeforePingMs)
    guard wanted != registeredPeriodMs else { return }
    registeredPeriodMs = wanted
    guard let period = wanted else {
      scheduler.unregister(Self.clientID)
      return
    }
    scheduler.register(Self.clientID, everyMs: period, priority: .low, on: queue) {
      [weak self] in self?.sweep()
    }
  }
}
