import Darwin
import FlashCore

/// How `discoverAsync` produced an activation's hints: the path it logs as
/// `[discover] complete` and whether a degenerate first walk was walked again
/// (a retry or the readiness ladder). The latency probe derives `prepared=`
/// and `outcome=` from it.
struct DiscoveryOutcome: Equatable {
  var path: String
  var retried = false

  var preparedHit: Bool { path == "prepared_model" || path == "prepared_model_filter" }
  var prepared: HintLatencyProbe.Prepared { preparedHit ? .hit : .miss }
}

/// What an activation does about a walk that looks degenerate
/// (`AppMonitor.discoveryLooksDegenerate`).
enum DegenerateRepair: Equatable {
  /// The empty walk is the answer: serve it (silently, when empty).
  case none
  /// Walk once more after a fixed settle, and serve the fuller result.
  case retry(afterMs: Int)
  /// Probe the tree's readiness on each step; walk once when it is ready, or
  /// at the last step, and serve the fuller result.
  case readinessLadder([Int])
}

/// Waits between readiness probes for a runtime that builds its tree
/// asynchronously (`AppTraits.buildsAccessibilityTreeAsynchronously`). Each
/// wait is scheduled with `asyncAfter`, never slept, and a probe is a bounded
/// read (`AccessibilityReadiness`). The last step walks without probing, so
/// the ladder always ends in one walk; its total (1.5 s) bounds how long a
/// genuinely empty app keeps an activation waiting. The first step gives a
/// just-woken tree a short beat; each later one roughly doubles, since the
/// measured "tree not ready" walks (1–5 ms, zero targets) cluster right after
/// a focus change and a tree that needs longer is rare.
enum ReadinessLadder {
  static let delaysMs = [50, 100, 200, 400, 750]

  static func delayMs(step: Int) -> Int? {
    delaysMs.indices.contains(step) ? delaysMs[step] : nil
  }

  static func probesBeforeWalking(step: Int) -> Bool {
    step < delaysMs.count - 1
  }
}

extension AppMonitor {
  /// The single settle before re-walking an app whose tree is built on
  /// demand (AppKit, SwiftUI, UIKit): nothing is being built asynchronously,
  /// so there is no readiness to probe.
  static let activationRetryDelayMs = 150

  /// A degenerate activation walk is repaired by how the app builds its
  /// tree. A volatile provider (tmux) that declined, in an app whose own tree
  /// never produced targets, leaves nothing to repair: the terminal's AX tree
  /// is empty, and retrying it only delays the silent end.
  static func degenerateRepair(
    engine: AppTraits.Engine?, afterVolatileDecline: Bool, lastHealthy: Int?
  ) -> DegenerateRepair {
    if afterVolatileDecline, lastHealthy == nil { return .none }
    if AppTraits(engine: engine).buildsAccessibilityTreeAsynchronously {
      return .readinessLadder(ReadinessLadder.delaysMs)
    }
    return .retry(afterMs: activationRetryDelayMs)
  }

  /// Background readiness re-walks allowed per focus of an app, each one a
  /// ladder ending in one walk.
  static let backgroundReadinessRewalksPerFocus = 2

  /// Whether a focus change waits for the tree before its first walk: only
  /// for runtimes that build it asynchronously, and only when Flash warms the
  /// app in the background at all.
  static func focusRefreshAwaitsReadiness(traits: AppTraits?, onDemand: Bool) -> Bool {
    !onDemand && traits?.buildsAccessibilityTreeAsynchronously == true
  }
}

/// Evidence that background walks of an app are useless: its hints come from
/// a volatile provider (tmux in a terminal) and its own Accessibility tree
/// keeps walking empty. After `threshold` consecutive empty automatic walks
/// the gate closes and the app gets no automatic walks — focus, AX events,
/// maintenance, readiness — until an activation finds targets in its tree, a
/// configuration change, or the app quits. Terminals that expose real AX
/// targets (iTerm2, Terminal, Ghostty) never close it: judged by walks, never
/// by bundle identifier.
struct EmptyBackgroundWalkGate: Equatable {
  static let threshold = 5

  private var streaks: [pid_t: Int] = [:]
  private var gated: Set<pid_t> = []

  func isGated(_ pid: pid_t) -> Bool { gated.contains(pid) }

  /// Record one automatic walk; true exactly when it closes the gate.
  mutating func noteBackgroundWalk(pid: pid_t, targets: Int, hasVolatileProvider: Bool) -> Bool {
    guard hasVolatileProvider, targets == 0 else {
      streaks.removeValue(forKey: pid)
      return false
    }
    let streak = streaks[pid, default: 0] + 1
    streaks[pid] = streak
    guard streak >= Self.threshold else { return false }
    return gated.insert(pid).inserted
  }

  /// An activation found targets in the app's own tree; true when that
  /// reopened the gate.
  mutating func noteActivationTargets(pid: pid_t) -> Bool {
    streaks.removeValue(forKey: pid)
    return gated.remove(pid) != nil
  }

  mutating func forget(pid: pid_t) {
    streaks.removeValue(forKey: pid)
    gated.remove(pid)
  }

  mutating func reset() {
    streaks.removeAll()
    gated.removeAll()
  }
}
