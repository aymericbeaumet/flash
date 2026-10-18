import Foundation

/// Request order for one source's catalog snapshots. Replies are prepared on
/// a concurrent queue, so a reply for a request made earlier can finish after
/// a later one for the same source and would put deleted rows back. Each
/// request is stamped when it is made, and only a stamp newer than the last
/// one accepted for that source may be deferred or published.
struct CandidateSnapshotOrdering: Equatable {
  private var accepted: [String: UInt64] = [:]
  private var serial: UInt64 = 0

  /// Stamp a request for `sourceID`.
  mutating func stamp(_ sourceID: String) -> UInt64 {
    serial &+= 1
    return serial
  }

  /// True when `stamp` is newer than every reply accepted for `sourceID`, and
  /// records it; a reply that lost the race is dropped.
  mutating func accept(_ sourceID: String, stamp: UInt64) -> Bool {
    if let latest = accepted[sourceID], latest >= stamp { return false }
    accepted[sourceID] = stamp
    return true
  }
}
