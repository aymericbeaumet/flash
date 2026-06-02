import Foundation
import FlashCore

final class TargetCache {
    struct Entry {
        let pid: pid_t
        let bundleID: String
        let frame: CGRect
        let targets: [JumpTarget]
        let timestamp: Date
    }

    private let queue = DispatchQueue(label: "flash.targetcache", attributes: .concurrent)
    private var byPID: [pid_t: Entry] = [:]

    func read(pid: pid_t) -> Entry? {
        queue.sync { byPID[pid] }
    }

    func write(_ entry: Entry) {
        queue.async(flags: .barrier) { self.byPID[entry.pid] = entry }
    }

    func invalidate(pid: pid_t) {
        queue.async(flags: .barrier) { self.byPID[pid] = nil }
    }

    func clear() {
        queue.async(flags: .barrier) { self.byPID.removeAll() }
    }
}
