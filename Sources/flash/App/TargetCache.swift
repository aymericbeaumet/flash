import Foundation
import FlashCore

/// In-memory cache of precomputed targets per app pid.
///
/// Reads happen on the main thread (activation hot path); writes happen on the
/// AX queue (precompute) or main thread (activation walk write-back). A barrier
/// on the concurrent queue keeps reads cheap.
final class TargetCache {
    struct Entry {
        let pid: pid_t
        let bundleID: String
        let windowFrame: CGRect
        let targets: [JumpTarget]
        let timestamp: Date
    }

    private let queue = DispatchQueue(label: "flash.targetcache", attributes: .concurrent)
    private var byPID: [pid_t: Entry] = [:]

    /// Returns a cache hit only when the pid matches, the cached `windowFrame`
    /// matches `currentFrame` exactly, and the entry is within `ttl` seconds.
    func read(pid: pid_t, currentFrame: CGRect, ttl: TimeInterval) -> Entry? {
        queue.sync {
            guard let entry = byPID[pid] else { return nil }
            guard Date().timeIntervalSince(entry.timestamp) <= ttl else { return nil }
            guard entry.windowFrame == currentFrame else { return nil }
            return entry
        }
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
