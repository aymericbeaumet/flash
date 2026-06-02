import AppKit
import ApplicationServices
import FlashCore

/// Coordinates discovery of jump targets for the focused app.
///
/// Two pipelines feed the same `TargetCache`:
///
/// 1. **Eager precompute** runs in the background on a serial AX queue whenever
///    we get a signal that the front-app's UI changed — workspace activation,
///    AX window-moved/resized, focused-element changed. The result lands in the
///    cache *before* the user typically presses ctrl+space, so the activation
///    path can return instantly.
///
/// 2. **On-demand discovery** is what `discover(now:)` does on the hot path.
///    It first reads the cache; on hit (same pid, same window frame, within
///    TTL) it returns instantly. On miss it synchronously dispatches a walk to
///    the same serial AX queue and waits — typically ~30 ms with the leaf-role
///    pruning in place.
///
/// All AX traversal runs on `axQueue`, a single serial queue. This is the
/// invariant that fixed the earlier non-determinism: the AX server returns
/// stable child orderings when only one walker is in flight at a time. If both
/// pipelines tried to walk concurrently, AX could (and did) return different
/// snapshots to each caller.
final class AppMonitor {
    private let registry: ProviderRegistry
    private let cache: TargetCache
    private let configRef: () -> Config

    private let axQueue = DispatchQueue(label: "flash.ax", qos: .userInitiated)
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var precomputeDebounce: DispatchWorkItem?

    /// AX observers actively invalidate the cache when the source window
    /// state changes, so the TTL is a backstop, not a freshness driver. Keep
    /// it long enough that repeated activations on a stable window keep
    /// hitting cache for free.
    private let cacheTTL: TimeInterval = 60.0

    init(registry: ProviderRegistry, cache: TargetCache, configRef: @escaping () -> Config) {
        self.registry = registry
        self.cache = cache
        self.configRef = configRef
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
            self.cache.invalidate(pid: app.processIdentifier)
            self.observers.removeValue(forKey: app.processIdentifier)
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
        observers.removeAll()
    }

    func currentContext() -> AppContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return makeContext(for: app)
    }

    // MARK: Discovery

    /// Synchronous discover — kept for compatibility / non-hot-path callers.
    /// The activation hot path uses `discoverAsync` instead so the main
    /// thread can return immediately and incoming URL events get dropped if
    /// a walk is already in flight.
    func discover(now context: AppContext) -> [JumpTarget] {
        if let entry = cacheHit(for: context) { return entry.targets }
        let cfg = configRef()
        return axQueue.sync { runWithCacheCheck(context: context, cfg: cfg) }
    }

    /// Activation hot path. Cache hit → calls `completion` synchronously on
    /// the current run loop. Cache miss → dispatches to the serial AX queue,
    /// runs the walk, and hops back to main to invoke `completion`. This
    /// means `activate(rightClick:)` in AppDelegate returns immediately,
    /// keeping main thread responsive so a follow-up ctrl+space press can be
    /// rejected by the inflight flag instead of being queued behind a slow
    /// sync dispatch.
    func discoverAsync(context: AppContext, completion: @escaping ([JumpTarget]) -> Void) {
        if let entry = cacheHit(for: context) {
            completion(entry.targets)
            return
        }
        let cfg = configRef()
        axQueue.async {
            let targets = self.runWithCacheCheck(context: context, cfg: cfg)
            DispatchQueue.main.async { completion(targets) }
        }
    }

    private func cacheHit(for context: AppContext) -> TargetCache.Entry? {
        guard let entry = cache.read(
            pid: context.processID,
            currentFrame: context.frontWindowFrame,
            ttl: cacheTTL
        ), entry.bundleID == context.bundleIdentifier else { return nil }
        return entry
    }

    private func runWithCacheCheck(context: AppContext, cfg: Config) -> [JumpTarget] {
        // Re-check the cache after acquiring the AX queue. If a workspace
        // precompute landed while we were dispatching, we should reuse its
        // result instead of repeating the walk.
        if let entry = cacheHit(for: context) { return entry.targets }
        let targets = runChain(for: context, deadlineMs: cfg.providers.deadlineMsCold)
        cache.write(.init(
            pid: context.processID,
            bundleID: context.bundleIdentifier,
            windowFrame: context.frontWindowFrame,
            targets: targets,
            timestamp: Date()
        ))
        return targets
    }

    // MARK: Precompute

    /// Workspace-activation precompute: we want this to start *immediately*
    /// so that by the time the user's ctrl+space round-trips through Karabiner
    /// + open(1) + Apple Events (~50-100 ms), the walk is finished and the
    /// activation reads from cache. AX-observer callbacks call this with
    /// `debounceMs > 0` to coalesce window-resize-drag bursts.
    private func schedulePrecompute(for app: NSRunningApplication, debounceMs: Int = 0) {
        precomputeDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let ctx = self.makeContext(for: app) else { return }
            let cfg = self.configRef()
            self.axQueue.async {
                let targets = self.runChain(for: ctx, deadlineMs: cfg.providers.deadlineMsCold)
                self.cache.write(.init(
                    pid: ctx.processID,
                    bundleID: ctx.bundleIdentifier,
                    windowFrame: ctx.frontWindowFrame,
                    targets: targets,
                    timestamp: Date()
                ))
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
        var seen: [CGRect] = []
        var merged: [JumpTarget] = []
        for provider in chain {
            if Date() > deadline { break }
            let results = (try? provider.discover(in: context, deadline: deadline)) ?? []
            for t in results {
                if seen.contains(where: { rectsOverlapSubstantially($0, t.frame) }) { continue }
                seen.append(t.frame)
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

    private func rectsOverlapSubstantially(_ a: CGRect, _ b: CGRect) -> Bool {
        let inter = a.intersection(b)
        if inter.isNull { return false }
        let interArea = inter.width * inter.height
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 && interArea / smaller > 0.7
    }
}
