import AppKit
import ApplicationServices
import os
import FlashCore
import FlashProviders

/// Coordinates discovery + hint assignment for the focused app (and, when
/// `hints.scope` extends beyond it, for the other visible apps on the active
/// monitor or every monitor).
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
///    Cache hit → call back inline. Miss → dispatch to the AX queue, walk
///    every context the current scope demands, assign labels, hop to main
///    with the result.
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
    private let observerQueue = DispatchQueue(label: "flash.ax-observer", qos: .utility)
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
    // reads via `snapshotConfig` at the start of each walk.

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
    func discoverAsync(
        context: AppContext,
        profiler: FlashProfiler? = nil,
        completion: @escaping ([AssignedHint]) -> Void
    ) {
        let cfg = snapshotConfig()
        let alphaKey = cfg.alphabetKey
        if let entry = cacheHit(for: context, alphabetKey: alphaKey) {
            profiler?.mark("cache_hit_main", detail: "hints=\(entry.hints.count)")
            completion(entry.hints)
            return
        }
        profiler?.mark("cache_miss_main", detail: "pid=\(context.processID)")
        setPrecomputeSuspended(true)
        precomputeDebounce?.cancel()

        let enqueueNs = profiler?.intervalStart()
        axQueue.async { [weak self] in
            guard let self else { return }
            if let enqueueNs {
                self.finishQueueWait(profiler, since: enqueueNs)
            }
            if let entry = self.cacheHit(for: context, alphabetKey: alphaKey) {
                profiler?.mark("cache_hit_ax", detail: "hints=\(entry.hints.count)")
                self.setPrecomputeSuspended(false)
                DispatchQueue.main.async { completion(entry.hints) }
                return
            }
            profiler?.mark("walk_start", detail: "scope=\(cfg.hints.scope.rawValue)")
            let hints = self.runAndAssign(context: context, cfg: cfg, profiler: profiler)
            self.setPrecomputeSuspended(false)
            profiler?.mark("walk_done", detail: "hints=\(hints.count)")
            DispatchQueue.main.async { completion(hints) }
        }
    }

    private func finishQueueWait(_ profiler: FlashProfiler?, since start: UInt64) {
        profiler?.finishInterval("ax_queue_wait", since: start)
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

    private func runAndAssign(context: AppContext, cfg: Config, profiler: FlashProfiler? = nil) -> [AssignedHint] {
        let walkStart = profiler?.intervalStart()
        let targets = walkAllForScope(focused: context, scope: cfg.hints.scope, profiler: profiler)
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
            profiler?.finishInterval("assign_hints", since: assignStart, detail: "targets=\(targets.count) hints=\(hints.count)")
        }
        cache.write(.init(
            pid: context.processID,
            bundleID: context.bundleIdentifier,
            windowFrame: context.frontWindowFrame,
            hints: hints,
            alphabetKey: cfg.alphabetKey,
            timestamp: Date()
        ))
        profiler?.mark("cache_write", detail: "hints=\(hints.count)")
        return hints
    }

    // MARK: Multi-app discovery
    //
    // Two layers of filtering keep hints on only the pixels the user can
    // actually see, regardless of scope:
    //
    //   1. `WindowSnapshot` does a painter's-algorithm pass over the
    //      CGWindowList z-order (front → back), subtracting each window's
    //      bounds from those below it. The result is a per-pid set of
    //      visible rectangles — the parts of each app's windows that
    //      aren't covered by anything in front. With scope=`everywhere`
    //      this is what stops Flash from drawing hints on a buried Safari
    //      tab whose toolbar isn't actually visible behind the active
    //      app's window. With scope=`active_app` it also handles
    //      same-app occlusion (a modal sheet hiding its parent window's
    //      buttons).
    //
    //   2. Per-target visibility check: a target survives only if its
    //      centre falls inside the owning pid's visible region. AX rects
    //      from scrolled-off rows, modal-covered fields, and DOM rects
    //      from minimised browser tabs all get dropped here.
    //
    // The first pass is also the source of the `expandContexts` filter:
    // an app with an empty visible region (fully occluded) is never
    // walked at all, so the AX IPC budget is spent on apps the user can
    // currently see.

    /// Resolve the list of `AppContext`s to walk for a given scope and run
    /// the provider chain against each, merging results with spatial dedup.
    /// The focused app is always walked first so its targets win on overlap
    /// with background apps.
    private func walkAllForScope(
        focused: AppContext,
        scope: Config.Scope,
        profiler: FlashProfiler? = nil
    ) -> [JumpTarget] {
        let primaryH = primaryScreenHeight()
        let snapshotStart = profiler?.intervalStart()
        let snapshot = WindowSnapshot.build(
            primaryH: primaryH,
            onlyComputingVisibleRegionsFor: scope == .activeApp ? focused.processID : nil
        )
        if let snapshotStart {
            let visiblePidCount = snapshot.visibleRegions.count
            profiler?.finishInterval(
                "window_snapshot",
                since: snapshotStart,
                detail: "windows=\(snapshot.entries.count) visible_pids=\(visiblePidCount)"
            )
        }
        let contexts = expandContexts(focused: focused, scope: scope, snapshot: snapshot)
        profiler?.mark("contexts", detail: "count=\(contexts.count)")
        var merged: [JumpTarget] = []
        merged.reserveCapacity(256)
        var dedup = SpatialDedup()
        for ctx in contexts {
            let region = snapshot.visibleRegions[ctx.processID] ?? []
            if region.isEmpty { continue }
            let providerContext = context(ctx, clippedTo: union(of: region))
            let chain = registry.chain(for: ctx)
            var browserDOMSucceeded = false
            for provider in chain {
                let providerStart = profiler?.intervalStart()
                let prunedWeb = browserDOMSucceeded && provider is AccessibilityProvider
                let results: [JumpTarget]
                if prunedWeb, let ax = provider as? AccessibilityProvider {
                    results = (try? ax.discover(in: providerContext, deadline: .distantFuture, descendIntoWebAreas: false)) ?? []
                } else {
                    results = (try? provider.discover(in: providerContext, deadline: .distantFuture)) ?? []
                }
                var kept = 0
                var hidden = 0
                var duplicate = 0
                for t in results {
                    let mid = CGPoint(x: t.frame.midX, y: t.frame.midY)
                    var visible = false
                    for r in region where r.contains(mid) { visible = true; break }
                    if !visible {
                        hidden += 1
                        continue
                    }
                    if dedup.contains(t.frame) {
                        duplicate += 1
                        continue
                    }
                    dedup.insert(t.frame)
                    merged.append(t)
                    kept += 1
                }
                if provider is BrowserScriptProvider, kept > 0 {
                    browserDOMSucceeded = true
                }
                if let providerStart {
                    profiler?.finishInterval(
                        "provider.\(provider.identifier)",
                        since: providerStart,
                        detail: "pid=\(ctx.processID) raw=\(results.count) kept=\(kept) hidden=\(hidden) duplicate=\(duplicate) web_pruned=\(prunedWeb)"
                    )
                }
            }
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

    private func context(_ context: AppContext, clippedTo frame: CGRect) -> AppContext {
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

    private func expandContexts(focused: AppContext, scope: Config.Scope, snapshot: WindowSnapshot) -> [AppContext] {
        switch scope {
        case .activeApp:
            return [focused]
        case .activeMonitor:
            let active = activeMonitorFrame(for: focused.processID, snapshot: snapshot)
            return contextsForVisibleApps(focused: focused, monitorFilter: active, snapshot: snapshot)
        case .everywhere:
            return contextsForVisibleApps(focused: focused, monitorFilter: nil, snapshot: snapshot)
        }
    }

    /// Enumerate apps that have a non-empty visible region, in z-order
    /// (front-most first). The focused app is always first. Background
    /// apps without a Dock icon (`activationPolicy != .regular`) are
    /// excluded — they're typically menu-bar utilities whose AX trees
    /// aren't user-clickable surfaces.
    private func contextsForVisibleApps(focused: AppContext, monitorFilter: CGRect?, snapshot: WindowSnapshot) -> [AppContext] {
        var orderedPids: [pid_t] = [focused.processID]
        var seen: Set<pid_t> = [focused.processID]

        for entry in snapshot.entries {
            if entry.layer != 0 { continue }
            if seen.contains(entry.pid) { continue }
            guard let region = snapshot.visibleRegions[entry.pid], !region.isEmpty else { continue }
            if let monitor = monitorFilter {
                if !region.contains(where: { $0.intersects(monitor) }) { continue }
            }
            seen.insert(entry.pid)
            orderedPids.append(entry.pid)
        }

        var contexts: [AppContext] = []
        contexts.reserveCapacity(orderedPids.count)
        for pid in orderedPids {
            if pid == focused.processID {
                contexts.append(focused)
                continue
            }
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  let ctx = makeContext(for: app) else { continue }
            contexts.append(ctx)
        }
        return contexts
    }

    /// The "active monitor" is the screen containing the focused app's
    /// frontmost layer-0 window. CGWindowList preserves z-order, so the
    /// first entry with the focused pid in the snapshot is its top window.
    /// Falls back to `NSScreen.main` (and then the first screen) when no
    /// window is found — happens if the focused app is briefly minimised
    /// while Flash activates.
    private func activeMonitorFrame(for focusedPid: pid_t, snapshot: WindowSnapshot) -> CGRect {
        for entry in snapshot.entries where entry.layer == 0 && entry.pid == focusedPid {
            let center = CGPoint(x: entry.nsBounds.midX, y: entry.nsBounds.midY)
            for screen in NSScreen.screens where screen.frame.contains(center) {
                return screen.frame
            }
            break
        }
        return NSScreen.main?.frame ?? NSScreen.screens.first?.frame ?? .zero
    }

    private func primaryScreenHeight() -> CGFloat {
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return primary.frame.height
        }
        return NSScreen.main?.frame.height ?? 1080
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
            if self.currentPrecomputeGen() != myGen { return }
            guard let ctx = self.makeContext(for: app) else { return }
            let cfg = self.snapshotConfig()
            self.axQueue.async { [weak self] in
                guard let self else { return }
                if self.isPrecomputeSuspended() { return }
                if self.currentPrecomputeGen() != myGen { return }
                let alphaKey = cfg.alphabetKey
                if self.cacheHit(for: ctx, alphabetKey: alphaKey) != nil { return }
                let profiler = FlashProfiler(kind: "precompute", debug: cfg.debug, slowLogsEnabled: false)
                profiler.mark("precompute_start", detail: "pid=\(ctx.processID) bundle=\(ctx.bundleIdentifier) scope=\(cfg.hints.scope.rawValue)")
                _ = self.runAndAssign(context: ctx, cfg: cfg, profiler: profiler)
                profiler.finish(outcome: "done", detail: "pid=\(ctx.processID) bundle=\(ctx.bundleIdentifier)")
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

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer

        // The expensive part — AXObserverAddNotification round-trips to the
        // target app's AX server, six times. Six IPCs on cold AX can add up
        // to hundreds of ms. Move them off the main thread so they never
        // delay the activation hot path.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        observerQueue.async {
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

    static func build(primaryH: CGFloat, onlyComputingVisibleRegionsFor focusedPid: pid_t? = nil) -> WindowSnapshot {
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

        var byPid: [pid_t: [CGRect]] = [:]
        var occluders: [CGRect] = []
        occluders.reserveCapacity(entries.count)
        for e in entries {
            // Layer-0 windows produce hintable surfaces; higher-layer
            // windows only act as occluders.
            let shouldComputeVisibleRegion = e.layer == 0 && (focusedPid == nil || focusedPid == e.pid)
            if shouldComputeVisibleRegion {
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
