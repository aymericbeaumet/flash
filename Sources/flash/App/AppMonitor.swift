import AppKit
import ApplicationServices
import FlashCore
import FlashProviders
import os

/// Coordinates discovery + hint assignment for the focused app only.
///
/// Every `discoverAsync` call dispatches a fresh AX walk on the serial
/// `axQueue` and never reads from a precomputed cache. We deliberately do
/// **not** speculatively warm a cache on workspace/AX notifications: those
/// notifications miss enough state changes (in-page scrolling, JS-driven
/// DOM updates, focus changes that don't fire AX events) that any cached
/// result is liable to be wrong by the time the user asks for hints. We
/// pay the walk cost on every activation in exchange for "what you see is
/// what you click".
final class AppMonitor {
  private let registry: ProviderRegistry

  private let axQueue = DispatchQueue(label: "flash.ax", qos: .userInitiated)

  // MARK: Config (shared between main + axQueue)
  //
  // Cheap lock — held only for the duration of a struct copy. AppDelegate
  // writes via `updateConfig` when the user edits config.toml; axQueue
  // reads via `snapshotConfig` at the start of each walk.

  private var config: Config
  private var configLock = os_unfair_lock_s()

  private func snapshotConfig() -> Config {
    os_unfair_lock_lock(&configLock)
    defer { os_unfair_lock_unlock(&configLock) }
    return config
  }

  /// Called by the AppDelegate config file-watcher whenever ~/.config/flash/config.toml
  /// changes. Atomically swaps the shared config.
  func updateConfig(_ cfg: Config) {
    os_unfair_lock_lock(&configLock)
    config = cfg
    os_unfair_lock_unlock(&configLock)
  }

  init(registry: ProviderRegistry, config: Config) {
    self.registry = registry
    self.config = config
  }

  func start() {}
  func stop() {}

  func currentContext() -> AppContext? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return makeContext(for: app)
  }

  // MARK: Discovery

  /// Activation hot path. Always walks on the serial AX queue and hops
  /// back to main with the result. No cache, no precompute — the walk is
  /// the only source of truth.
  func discoverAsync(
    context: AppContext,
    profiler: FlashProfiler? = nil,
    completion: @escaping ([AssignedHint]) -> Void
  ) {
    let cfg = snapshotConfig()
    let enqueueNs = profiler?.intervalStart()
    axQueue.async { [weak self] in
      guard let self else { return }
      if let enqueueNs {
        self.finishQueueWait(profiler, since: enqueueNs)
      }
      profiler?.mark("walk_start")
      let hints = self.runAndAssign(context: context, cfg: cfg, profiler: profiler)
      profiler?.mark("walk_done", detail: "hints=\(hints.count)")
      DispatchQueue.main.async { completion(hints) }
    }
  }

  private func finishQueueWait(_ profiler: FlashProfiler?, since start: UInt64) {
    profiler?.finishInterval("ax_queue_wait", since: start)
  }

  private func runAndAssign(context: AppContext, cfg: Config, profiler: FlashProfiler? = nil)
    -> [AssignedHint]
  {
    let walkStart = profiler?.intervalStart()
    configureDebugSinks(for: cfg, triggerMs: profiler?.triggerMs)
    let targets = walkFocused(context: context, profiler: profiler)
    if let walkStart {
      profiler?.finishInterval("walk_all", since: walkStart, detail: "targets=\(targets.count)")
    }
    let resolved = Alphabet.resolve(cfg.hints.keys)
    let assignStart = profiler?.intervalStart()
    let hints = HintAssigner.assign(
      targets: targets,
      alphabet: resolved.chars,
      leftHand: resolved.leftHand,
      minLength: cfg.hints.minLength
    )
    if let assignStart {
      profiler?.finishInterval(
        "assign_hints", since: assignStart, detail: "targets=\(targets.count) hints=\(hints.count)")
    }
    return hints
  }

  // MARK: Discovery
  //
  // Two layers of filtering keep hints on only the pixels the user can
  // actually see:
  //
  //   1. `WindowSnapshot` does a painter's-algorithm pass over the
  //      CGWindowList z-order (front → back), subtracting each window's
  //      bounds from those below it. The result is the focused pid's
  //      genuinely-visible region — the parts of its windows that
  //      aren't covered by anything in front. This handles same-app
  //      occlusion (a modal sheet hiding its parent window's buttons)
  //      and the menu bar / Dock / status items covering the top/edge
  //      strips.
  //
  //   2. Per-target visibility check: a target survives only if its
  //      centre falls inside the focused app's visible region. AX rects
  //      from scrolled-off rows, modal-covered fields, and DOM rects
  //      from minimised browser tabs all get dropped here.
  //
  // After both filters, the candidates go through a smaller-frame-wins
  // dedup: when a parent (e.g. a 400×300 card wrapper) and its smaller
  // child (e.g. a 24×24 link) overlap by ≥70%, the smaller one
  // survives. That's what makes the actual link/button get the hint
  // instead of an un-clickable wrapper.
  private func walkFocused(
    context focused: AppContext,
    profiler: FlashProfiler? = nil
  ) -> [JumpTarget] {
    let primaryH = primaryScreenHeight()
    let snapshotStart = profiler?.intervalStart()
    let snapshot = WindowSnapshot.build(
      primaryH: primaryH,
      onlyComputingVisibleRegionsFor: focused.processID
    )
    if let snapshotStart {
      profiler?.finishInterval(
        "window_snapshot",
        since: snapshotStart,
        detail: "windows=\(snapshot.entries.count)"
      )
    }
    let region = snapshot.visibleRegions[focused.processID] ?? []
    if region.isEmpty { return [] }
    let providerContext = clip(focused, to: union(of: region))
    let chain = registry.chain(for: focused)
    var collected: [JumpTarget] = []
    collected.reserveCapacity(256)
    var browserDOMSucceeded = false
    for provider in chain {
      let providerStart = profiler?.intervalStart()
      let prunedWeb = browserDOMSucceeded && provider is AccessibilityProvider
      let results: [JumpTarget]
      if prunedWeb, let ax = provider as? AccessibilityProvider {
        results =
          (try? ax.discover(
            in: providerContext, deadline: .distantFuture, descendIntoWebAreas: false)) ?? []
      } else {
        results = (try? provider.discover(in: providerContext, deadline: .distantFuture)) ?? []
      }
      var kept = 0
      var hidden = 0
      for t in results {
        let mid = CGPoint(x: t.frame.midX, y: t.frame.midY)
        var visible = false
        for r in region where r.contains(mid) {
          visible = true
          break
        }
        if !visible {
          hidden += 1
          continue
        }
        collected.append(t)
        kept += 1
      }
      if provider is BrowserScriptProvider, kept > 0 {
        browserDOMSucceeded = true
      }
      if let providerStart {
        profiler?.finishInterval(
          "provider.\(provider.identifier)",
          since: providerStart,
          detail:
            "raw=\(results.count) kept=\(kept) hidden=\(hidden) web_pruned=\(prunedWeb)"
        )
      }
    }

    let dedupStart = profiler?.intervalStart()
    var merged: [JumpTarget] = []
    merged.reserveCapacity(collected.count)
    collected.sort { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
    var dedup = SpatialDedup()
    var duplicate = 0
    for t in collected {
      if dedup.contains(t.frame) {
        duplicate += 1
        continue
      }
      dedup.insert(t.frame)
      merged.append(t)
    }
    if let dedupStart {
      profiler?.finishInterval(
        "dedup_targets",
        since: dedupStart,
        detail: "candidates=\(collected.count) kept=\(merged.count) duplicate=\(duplicate)"
      )
    }

    let sortStart = profiler?.intervalStart()
    merged.sort { lhs, rhs in
      let lhsTop = lhs.frame.maxY
      let rhsTop = rhs.frame.maxY
      if abs(lhsTop - rhsTop) > 8 { return lhsTop > rhsTop }
      if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
      if lhs.frame.minY != rhs.frame.minY { return lhs.frame.minY > rhs.frame.minY }
      if lhs.frame.width != rhs.frame.width { return lhs.frame.width < rhs.frame.width }
      if lhs.frame.height != rhs.frame.height { return lhs.frame.height < rhs.frame.height }
      return lhs.id < rhs.id
    }
    if let sortStart {
      profiler?.finishInterval("sort_targets", since: sortStart, detail: "targets=\(merged.count)")
    }
    return merged
  }

  private func clip(_ context: AppContext, to frame: CGRect) -> AppContext {
    AppContext(
      bundleIdentifier: context.bundleIdentifier,
      processID: context.processID,
      runningApp: context.runningApp,
      frontWindowFrame: frame.isNull ? context.frontWindowFrame : frame,
      allScreensFrame: context.allScreensFrame
    )
  }

  private func union(of rects: [CGRect]) -> CGRect {
    var out: CGRect = .null
    for rect in rects { out = out.union(rect) }
    return out
  }

  private func primaryScreenHeight() -> CGFloat {
    if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
      return primary.frame.height
    }
    return NSScreen.main?.frame.height ?? 1080
  }

  /// Toggle the file-backed debug sinks based on the current config.
  /// Called at the start of every walk so config hot-reloads take
  /// effect on the very next activation. The trigger timestamp is
  /// propagated so each dump line / log line can be correlated to the
  /// activation that produced it.
  ///   - `dump_ax`   → AX walker writes per-element trace to
  ///                   ~/Library/Logs/Flash/ax-dump.log (rewritten per walk).
  ///   - `dump_logs` → FlashLog mirrors all stderr writes to
  ///                   ~/Library/Logs/Flash/flash.log (appended).
  private func configureDebugSinks(for cfg: Config, triggerMs: UInt64?) {
    FlashLog.setMirrorToFile(cfg.debug.dumpLogs)

    let ax = registry.providers.first { $0 is AccessibilityProvider } as? AccessibilityProvider
    if let ax {
      ax.triggerMs = triggerMs
      if cfg.debug.dumpAx {
        let home = FileManager.default.homeDirectoryForCurrentUser
        ax.dumpURL =
          home
          .appendingPathComponent("Library/Logs/Flash/ax-dump.log")
      } else {
        ax.dumpURL = nil
      }
    }
  }

  // MARK: Context

  private func makeContext(for app: NSRunningApplication) -> AppContext? {
    let pid = app.processIdentifier
    guard pid > 0 else { return nil }

    var screenFrame: CGRect = .null
    for s in NSScreen.screens { screenFrame = screenFrame.union(s.frame) }
    if screenFrame.isNull { screenFrame = .zero }

    // Deliberately no AX IPC here. `makeContext` runs on the main thread
    // every time the user activates, and a single kAXFocusedWindowAttribute
    // call on a cold AX server can add 100-300 ms of latency to the
    // overlay appearing. The AX queue builds a WindowServer visibility
    // snapshot and passes a clipped context to providers, so the
    // centre-in-visible check works without needing a precomputed AX
    // window frame from main.
    return AppContext(
      bundleIdentifier: app.bundleIdentifier ?? "",
      processID: pid,
      runningApp: app,
      frontWindowFrame: screenFrame,
      allScreensFrame: screenFrame
    )
  }
}

/// Spatial-hash dedup keyed on a 256-pixel grid. For N=1500 targets the old
/// `seen.contains(where:)` was O(N²) — 1.1M `CGRect.intersection` calls in
/// the worst case. Bucketing collapses it to ~O(N) since the average number
/// of rectangles overlapping any single bucket is small.
private struct SpatialDedup {
  private static let cellSize: CGFloat = 256
  private var buckets: [Int64: [CGRect]] = [:]

  private static func key(_ x: Int, _ y: Int) -> Int64 {
    (Int64(x) << 32) | (Int64(y) & 0xffff_ffff)
  }

  private func bucketRange(_ rect: CGRect) -> (xMin: Int, xMax: Int, yMin: Int, yMax: Int) {
    let xMin = Int((rect.minX / Self.cellSize).rounded(.down))
    let xMax = Int((rect.maxX / Self.cellSize).rounded(.down))
    let yMin = Int((rect.minY / Self.cellSize).rounded(.down))
    let yMax = Int((rect.maxY / Self.cellSize).rounded(.down))
    return (xMin, xMax, yMin, yMax)
  }

  func contains(_ rect: CGRect) -> Bool {
    let r = bucketRange(rect)
    for x in r.xMin...r.xMax {
      for y in r.yMin...r.yMax {
        guard let bucket = buckets[Self.key(x, y)] else { continue }
        for other in bucket where overlapsSubstantially(other, rect) { return true }
      }
    }
    return false
  }

  mutating func insert(_ rect: CGRect) {
    let r = bucketRange(rect)
    for x in r.xMin...r.xMax {
      for y in r.yMin...r.yMax {
        buckets[Self.key(x, y), default: []].append(rect)
      }
    }
  }

  private func overlapsSubstantially(_ a: CGRect, _ b: CGRect) -> Bool {
    let inter = a.intersection(b)
    if inter.isNull { return false }
    let interArea = inter.width * inter.height
    let smaller = min(a.width * a.height, b.width * b.height)
    return smaller > 0 && interArea / smaller > 0.7
  }
}

/// Z-order snapshot of every on-screen window, with each window's
/// genuinely-visible portion already computed. Built from a single
/// `CGWindowListCopyWindowInfo` call.
///
/// The painter's algorithm: iterate windows front → back (the order
/// CGWindowList returns them in). For each window, subtract every
/// already-seen (higher-z) window's bounds from this one's. What's left
/// is the part of the window the user can actually see. Then push this
/// window's bounds onto the occluder list so the next window down gets
/// chopped by it too.
///
/// Higher-layer windows (the Dock, the menu bar, status items, the
/// notification centre) are kept as occluders but excluded from the
/// per-pid region map — they're not user-clickable surfaces Flash should
/// hint, but they DO cover stuff behind them, so they need to chop the
/// regions of the apps they overlay.
struct WindowSnapshot {
  struct Entry {
    let pid: pid_t
    let layer: Int
    /// NSScreen-coord bounds (origin bottom-left of primary).
    let nsBounds: CGRect
  }

  /// All on-screen windows in z-order (front-most first).
  let entries: [Entry]

  /// Per-pid disjoint rectangles in NSScreen coords that represent the
  /// pid's currently-visible pixels (after subtracting every higher-z
  /// window). Empty for pids that are fully occluded.
  let visibleRegions: [pid_t: [CGRect]]

  static func build(primaryH: CGFloat, onlyComputingVisibleRegionsFor focusedPid: pid_t)
    -> WindowSnapshot
  {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
      return WindowSnapshot(entries: [], visibleRegions: [:])
    }

    var entries: [Entry] = []
    entries.reserveCapacity(info.count)
    for w in info {
      guard let wpid = w[kCGWindowOwnerPID as String] as? Int32,
        let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
        let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
      else { continue }
      // Skip zero-area or pathological bounds — they can't occlude
      // anything and can't host hints.
      if cgBounds.width <= 0 || cgBounds.height <= 0 { continue }
      let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
      let ns = CGRect(
        x: cgBounds.minX,
        y: primaryH - cgBounds.minY - cgBounds.height,
        width: cgBounds.width,
        height: cgBounds.height
      )
      entries.append(Entry(pid: pid_t(wpid), layer: layer, nsBounds: ns))
    }

    // The "active window" is the front-most layer-0 window owned by the
    // focused pid. CGWindowList returns windows in z-order, so the
    // first hit is the right one. Every other window — including other
    // windows of the same app on another monitor — is treated purely
    // as an occluder, never as a hintable surface. This is what keeps
    // hints scoped to the single active window.
    var activeWindowIndex: Int? = nil
    for (idx, e) in entries.enumerated() where e.layer == 0 && e.pid == focusedPid {
      activeWindowIndex = idx
      break
    }

    var byPid: [pid_t: [CGRect]] = [:]
    var occluders: [CGRect] = []
    occluders.reserveCapacity(entries.count)
    for (idx, e) in entries.enumerated() {
      if idx == activeWindowIndex {
        var fragments: [CGRect] = [e.nsBounds]
        for occluder in occluders {
          if fragments.isEmpty { break }
          var next: [CGRect] = []
          next.reserveCapacity(fragments.count * 2)
          for frag in fragments {
            subtract(frag, hole: occluder, into: &next)
          }
          // Fragmentation guard. A window cross-hatched by many
          // higher-z windows can blow up the fragment count
          // quadratically; cap at 32 — we only need the
          // *approximate* visible region, not pixel-perfect.
          if next.count > 32 {
            fragments = next
            break
          }
          fragments = next
        }
        if !fragments.isEmpty {
          byPid[e.pid, default: []].append(contentsOf: fragments)
        }
      }
      occluders.append(e.nsBounds)
    }

    return WindowSnapshot(entries: entries, visibleRegions: byPid)
  }

  /// Rectangle subtraction in NSScreen-coord (Y-up) space. Returns up to
  /// four non-overlapping fragments: top strip, bottom strip, left
  /// strip (within the y-range of the hole), right strip. The math is
  /// symmetric in Y so this also works in Y-down — the strip labels
  /// are only descriptive.
  private static func subtract(_ rect: CGRect, hole: CGRect, into out: inout [CGRect]) {
    let i = rect.intersection(hole)
    if i.isNull || i.width <= 0 || i.height <= 0 {
      out.append(rect)
      return
    }
    if i.equalTo(rect) {
      // Fully consumed by the hole — nothing left to emit.
      return
    }
    // Top strip (above the hole in Y-up).
    if i.maxY < rect.maxY {
      out.append(CGRect(x: rect.minX, y: i.maxY, width: rect.width, height: rect.maxY - i.maxY))
    }
    // Bottom strip (below the hole).
    if i.minY > rect.minY {
      out.append(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: i.minY - rect.minY))
    }
    // Left strip (only within the y-range of the hole).
    if i.minX > rect.minX {
      out.append(CGRect(x: rect.minX, y: i.minY, width: i.minX - rect.minX, height: i.height))
    }
    // Right strip (likewise).
    if i.maxX < rect.maxX {
      out.append(CGRect(x: i.maxX, y: i.minY, width: rect.maxX - i.maxX, height: i.height))
    }
  }
}
