import AppKit
import ApplicationServices
import os
import FlashCore

/// Coordinates discovery + hint assignment for the focused app.
///
/// Two pipelines feed the same `TargetCache`:
///
/// 1. **Eager precompute** runs in the background on a serial AX queue
///    whenever we get a signal that the front-app's UI changed — workspace
///    activation, AX window-moved/resized, focused-element changed. The
///    cache entry includes the *assigned hint labels*, not just the
///    discovered targets, so the activation hot path can both skip the AX
///    walk **and** the hint assignment when there's a hit.
///
/// 2. **On-demand discovery** is what `discoverAsync` does on the hot path.
///    Cache hit → call back inline. Miss → dispatch to the AX queue, walk,
///    assign labels, hop to main with the result.
///
/// All AX traversal runs on `axQueue`, a single serial queue. This is the
/// invariant that fixed the earlier non-determinism: the AX server returns
/// stable child orderings when only one walker is in flight at a time. Both
/// pipelines coordinate through `precomputeGen` (so stale precompute work is
/// skipped at queue head) and `precomputeSuspended` (so a queued precompute
/// drops itself when activation has already taken priority).
final class AppMonitor {
    private let registry: ProviderRegistry
    private let cache: TargetCache

    private let axQueue = DispatchQueue(label: "flash.ax", qos: .userInitiated)
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []

    /// AX observers actively invalidate the cache when the source window
    /// state changes, so the TTL is a backstop, not a freshness driver. Keep
    /// it long enough that repeated activations on a stable window keep
    /// hitting cache for free.
    private let cacheTTL: TimeInterval = 60.0

    // MARK: Config (shared between main + axQueue)
    //
    // Cheap lock — held only for the duration of a struct copy. AppDelegate
    // writes via `updateConfig` when the user edits config.toml; axQueue
    // reads via `snapshotConfig` at the start of each walk. The lock guards
    // against torn struct reads (the old `configRef` closure had a
    // tasterity-vs-tearing data race on the multi-field Config).

    private var config: Config
    private var configLock = os_unfair_lock_s()

    private func snapshotConfig() -> Config {
        os_unfair_lock_lock(&configLock)
        defer { os_unfair_lock_unlock(&configLock) }
        return config
    }

    /// Called by the AppDelegate config file-watcher whenever ~/.config/flash/config.toml
    /// changes. Atomically swaps the shared config and clears the precomputed
    /// hint cache — its labels were generated against the previous alphabet
    /// and would be stale.
    func updateConfig(_ cfg: Config) {
        os_unfair_lock_lock(&configLock)
        config = cfg
        os_unfair_lock_unlock(&configLock)
        cache.clear()
    }

    // MARK: Precompute coordination
    //
    // Two pieces of state both touched from main and axQueue. They share one
    // lock because they're updated as a unit by the activation path
    // (suspend + read gen) and because the lock is held only across a few
    // word-sized reads/writes.

    private var precomputeGen: UInt64 = 0
    private var precomputeSuspended: Bool = false
    private var precomputeLock = os_unfair_lock_s()
    private var precomputeDebounce: DispatchWorkItem?

    private func setPrecomputeSuspended(_ v: Bool) {
        os_unfair_lock_lock(&precomputeLock)
        precomputeSuspended = v
        os_unfair_lock_unlock(&precomputeLock)
    }

    private func isPrecomputeSuspended() -> Bool {
        os_unfair_lock_lock(&precomputeLock)
        defer { os_unfair_lock_unlock(&precomputeLock) }
        return precomputeSuspended
    }

    /// Bumps the generation and returns the new value. Called only from main
    /// (inside `schedulePrecompute`); the lock is taken for the same reason
    /// reads from axQueue are locked — to make the cross-thread access
    /// formally race-free under TSan.
    private func bumpPrecomputeGen() -> UInt64 {
        os_unfair_lock_lock(&precomputeLock)
        precomputeGen &+= 1
        let v = precomputeGen
        os_unfair_lock_unlock(&precomputeLock)
        return v
    }

    private func currentPrecomputeGen() -> UInt64 {
        os_unfair_lock_lock(&precomputeLock)
        defer { os_unfair_lock_unlock(&precomputeLock) }
        return precomputeGen
    }

    init(registry: ProviderRegistry, cache: TargetCache, config: Config) {
        self.registry = registry
        self.cache = cache
        self.config = config
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        let activate = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.installAXObserver(for: app)
            self.schedulePrecompute(for: app)
        }
        let terminate = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            self.cache.invalidate(pid: pid)
            if let observer = self.observers.removeValue(forKey: pid) {
                // Detach the observer's run-loop source before letting it
                // deallocate. Without this the source dangles on the main
                // run loop with a freed callback target — a slow leak that
                // accumulates over long sessions of app-launch/quit churn.
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }
        workspaceTokens.append(contentsOf: [activate, terminate])

        if let front = NSWorkspace.shared.frontmostApplication {
            installAXObserver(for: front)
            schedulePrecompute(for: front)
        }
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { nc.removeObserver(token) }
        workspaceTokens.removeAll()
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
    }

    func currentContext() -> AppContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return makeContext(for: app)
    }

    // MARK: Discovery

    /// Activation hot path. Cache hit → calls `completion` synchronously on
    /// the current run loop. Cache miss → dispatches to the serial AX queue,
    /// runs the walk + assignment, and hops back to main to invoke
    /// `completion`. Pending precomputes on the AX queue see
    /// `precomputeSuspended = true` and short-circuit, so the activation
    /// walk doesn't queue behind redundant work.
    func discoverAsync(context: AppContext, completion: @escaping ([AssignedHint]) -> Void) {
        let cfg = snapshotConfig()
        let alphaKey = cfg.alphabetKey
        if let entry = cacheHit(for: context, alphabetKey: alphaKey) {
            completion(entry.hints)
            return
        }
        // The activation walk is about to be enqueued. Any precompute work
        // currently sitting on axQueue should drop itself instead of
        // running first. The flag flips back to false after our walk
        // completes (whether we hit cache, walk, or get cancelled).
        setPrecomputeSuspended(true)
        // Cancel any debounced precompute that hasn't dispatched yet.
        precomputeDebounce?.cancel()

        axQueue.async { [weak self] in
            guard let self else { return }
            // Re-check the cache after acquiring the AX queue. If a
            // workspace precompute landed while we were dispatching, we
            // should reuse its result instead of repeating the walk.
            if let entry = self.cacheHit(for: context, alphabetKey: alphaKey) {
                self.setPrecomputeSuspended(false)
                DispatchQueue.main.async { completion(entry.hints) }
                return
            }
            let hints = self.runAndAssign(context: context, cfg: cfg)
            self.setPrecomputeSuspended(false)
            DispatchQueue.main.async { completion(hints) }
        }
    }

    private func cacheHit(for context: AppContext, alphabetKey: String) -> TargetCache.Entry? {
        guard let entry = cache.read(
            pid: context.processID,
            currentFrame: context.frontWindowFrame,
            alphabetKey: alphabetKey,
            ttl: cacheTTL
        ), entry.bundleID == context.bundleIdentifier else { return nil }
        return entry
    }

    private func runAndAssign(context: AppContext, cfg: Config) -> [AssignedHint] {
        let targets = runChain(for: context, deadlineMs: cfg.providers.deadlineMsCold)
        let resolved = Alphabet.resolve(cfg.hints.keys)
        let hints = HintAssigner.assign(
            targets: targets,
            alphabet: resolved.chars,
            leftHand: resolved.leftHand,
            minLength: cfg.hints.minLength
        )
        cache.write(.init(
            pid: context.processID,
            bundleID: context.bundleIdentifier,
            windowFrame: context.frontWindowFrame,
            hints: hints,
            alphabetKey: cfg.alphabetKey,
            timestamp: Date()
        ))
        return hints
    }

    // MARK: Precompute

    /// Workspace-activation precompute: we want this to start *immediately*
    /// so that by the time the user's ctrl+space round-trips through Karabiner
    /// + open(1) + Apple Events (~50-100 ms), the walk + label assignment is
    /// finished and the activation reads everything from cache. AX-observer
    /// callbacks call this with `debounceMs > 0` to coalesce window-resize
    /// bursts.
    private func schedulePrecompute(for app: NSRunningApplication, debounceMs: Int = 0) {
        precomputeDebounce?.cancel()
        let myGen = bumpPrecomputeGen()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Superseded by a newer schedule? Drop.
            if self.currentPrecomputeGen() != myGen { return }
            guard let ctx = self.makeContext(for: app) else { return }
            let cfg = self.snapshotConfig()
            self.axQueue.async { [weak self] in
                guard let self else { return }
                // Activation has priority — bail if it's about to claim the
                // queue. This is the cheap unfair-lock check, not a
                // main-thread hop.
                if self.isPrecomputeSuspended() { return }
                // Did a newer precompute schedule arrive while we were
                // queued? If so, we're stale.
                if self.currentPrecomputeGen() != myGen { return }
                let alphaKey = cfg.alphabetKey
                if self.cacheHit(for: ctx, alphabetKey: alphaKey) != nil { return }
                _ = self.runAndAssign(context: ctx, cfg: cfg)
            }
        }
        precomputeDebounce = item
        if debounceMs > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(debounceMs), execute: item)
        } else {
            DispatchQueue.main.async(execute: item)
        }
    }

    // MARK: AX observation

    private func installAXObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0 else { return }
        if observers[pid] != nil { return }

        var observerRef: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<AppMonitor>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async {
                monitor.invalidateAndReschedule()
            }
        }
        guard AXObserverCreate(pid, callback, &observerRef) == .success,
              let observer = observerRef else { return }

        // The run-loop source has to be attached on whichever loop should
        // receive callbacks. That's main, and the call is local (no IPC).
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer

        // The expensive part — AXObserverAddNotification round-trips to the
        // target app's AX server, six times. Six IPCs on cold AX can add up
        // to hundreds of ms. Move them off the main thread so they never
        // delay the activation hot path.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        axQueue.async {
            let axApp = AXUIElementCreateApplication(pid)
            let notifications: [String] = [
                kAXFocusedWindowChangedNotification,
                kAXMainWindowChangedNotification,
                kAXWindowMovedNotification,
                kAXWindowResizedNotification,
                kAXFocusedUIElementChangedNotification,
                kAXSelectedChildrenChangedNotification,
            ]
            for n in notifications {
                AXObserverAddNotification(observer, axApp, n as CFString, refcon)
            }
        }
    }

    private func invalidateAndReschedule() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        cache.invalidate(pid: app.processIdentifier)
        // Coalesce rapid AX bursts (window drag/resize fires many notifications
        // per second). For the workspace activate path we skip the debounce.
        schedulePrecompute(for: app, debounceMs: 40)
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
        // overlay appearing. The walk inside AccessibilityProvider already
        // discovers and clips per-window from kAXWindowsAttribute (running
        // on the AX queue), so the centre-in-visible check works without
        // needing a precomputed window frame from main.
        return AppContext(
            bundleIdentifier: app.bundleIdentifier ?? "",
            processID: pid,
            runningApp: app,
            frontWindowFrame: screenFrame,
            allScreensFrame: screenFrame
        )
    }

    // MARK: Chain execution

    private func runChain(for context: AppContext, deadlineMs: Int) -> [JumpTarget] {
        let deadline = Date().addingTimeInterval(TimeInterval(deadlineMs) / 1000.0)
        let chain = registry.chain(for: context)
        var merged: [JumpTarget] = []
        merged.reserveCapacity(256)
        var dedup = SpatialDedup()
        for provider in chain {
            if Date() > deadline { break }
            let results = (try? provider.discover(in: context, deadline: deadline)) ?? []
            for t in results {
                if dedup.contains(t.frame) { continue }
                dedup.insert(t.frame)
                merged.append(t)
            }
        }
        // Total order (no ties). This is what makes the key↔element mapping
        // deterministic: same set of targets in the same screen positions
        // always yields the same order, so HintAssigner always emits the same
        // label for the same element. Reading order first (top→bottom →
        // left→right), then deterministic fallbacks on size and id.
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
        return merged
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
        // 32-bit cell coords packed into 64 bits. Cell coords are tiny
        // (screen / 256), so 32 bits per axis is overkill but free.
        (Int64(x) << 32) | (Int64(y) & 0xffffffff)
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
