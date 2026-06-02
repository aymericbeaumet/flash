import Foundation
import os
import FlashCore

/// In-memory cache of precomputed hints per app pid.
///
/// Reads happen on the main thread (activation hot path); writes happen on
/// the AX queue (precompute) or main thread (activation walk write-back).
/// The hot operation is a Dictionary lookup keyed by pid — far cheaper than
/// the GCD machinery a concurrent queue + barrier would impose on every
/// hit. We have exactly one reader thread (main) and at most two writer
/// threads (main + axQueue), so a single unfair lock is the right primitive.
final class TargetCache {
    struct Entry {
        let pid: pid_t
        let bundleID: String
        let windowFrame: CGRect
        let hints: [AssignedHint]
        /// Identity of the alphabet + length used to produce `hints`. If the
        /// user hot-reloads their alphabet, the cached labels are stale even
        /// though the underlying targets aren't, so this field is part of the
        /// hit predicate.
        let alphabetKey: String
        let timestamp: Date
    }

    private var lock = os_unfair_lock_s()
    private var byPID: [pid_t: Entry] = [:]

    /// Returns a cache hit only when the pid matches, the cached `windowFrame`
    /// matches `currentFrame` exactly, the alphabet key matches, and the
    /// entry is within `ttl` seconds.
    func read(pid: pid_t, currentFrame: CGRect, alphabetKey: String, ttl: TimeInterval) -> Entry? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let entry = byPID[pid] else { return nil }
        guard Date().timeIntervalSince(entry.timestamp) <= ttl else { return nil }
        guard entry.windowFrame == currentFrame else { return nil }
        guard entry.alphabetKey == alphabetKey else { return nil }
        return entry
    }

    func write(_ entry: Entry) {
        os_unfair_lock_lock(&lock)
        byPID[entry.pid] = entry
        os_unfair_lock_unlock(&lock)
    }

    func invalidate(pid: pid_t) {
        os_unfair_lock_lock(&lock)
        byPID[pid] = nil
        os_unfair_lock_unlock(&lock)
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        byPID.removeAll()
        os_unfair_lock_unlock(&lock)
    }
}
