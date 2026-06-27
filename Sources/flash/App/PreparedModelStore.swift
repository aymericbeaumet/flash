import Darwin
import FlashCore
import Foundation

struct PreparedModel {
  let pid: pid_t
  let targets: [JumpTarget]
  let hints: [AssignedHint]
  let computedAt: DispatchTime
  let dirtyToken: UInt64
  let configRevision: UInt64

  var isEmptyReady: Bool { hints.isEmpty }
}

struct PreparedModelStore {
  private var models: [pid_t: PreparedModel] = [:]
  private var rebuilding: Set<pid_t> = []
  private var queuedAfterRebuild: Set<pid_t> = []

  mutating func store(_ model: PreparedModel) {
    models[model.pid] = model
  }

  mutating func discardModel(pid: pid_t) {
    models.removeValue(forKey: pid)
  }

  mutating func remove(pid: pid_t) {
    models.removeValue(forKey: pid)
    rebuilding.remove(pid)
    queuedAfterRebuild.remove(pid)
  }

  mutating func removeAll() {
    models.removeAll()
    rebuilding.removeAll()
    queuedAfterRebuild.removeAll()
  }

  func lookup(
    pid: pid_t,
    dirtyToken: UInt64,
    configRevision: UInt64,
    now: DispatchTime,
    freshnessMs: Int
  ) -> PreparedModel? {
    guard let model = models[pid] else { return nil }
    guard model.dirtyToken == dirtyToken else { return nil }
    guard model.configRevision == configRevision else { return nil }
    let ageNs = now.uptimeNanoseconds - model.computedAt.uptimeNanoseconds
    let ageMs = Double(ageNs) / 1_000_000
    guard ageMs <= Double(freshnessMs) else { return nil }
    return model
  }

  mutating func beginRebuild(pid: pid_t) -> Bool {
    if rebuilding.contains(pid) {
      queuedAfterRebuild.insert(pid)
      return false
    }
    rebuilding.insert(pid)
    return true
  }

  mutating func finishRebuild(pid: pid_t) -> Bool {
    rebuilding.remove(pid)
    return queuedAfterRebuild.remove(pid) != nil
  }

  func isRebuilding(pid: pid_t) -> Bool {
    rebuilding.contains(pid)
  }
}
