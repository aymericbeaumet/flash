import AppKit
import ApplicationServices
import FlashCore

final class AppMonitor {
    private let registry: ProviderRegistry
    private let cache: TargetCache
    private let configRef: () -> Config
    private var observers: [pid_t: AXObserver] = [:]
    private var refreshQueue = DispatchQueue(label: "flash.appmonitor.refresh", qos: .userInitiated)
    private var debounce: DispatchWorkItem?
    private var workspaceTokens: [NSObjectProtocol] = []

    init(registry: ProviderRegistry, cache: TargetCache, configRef: @escaping () -> Config) {
        self.registry = registry
        self.cache = cache
        self.configRef = configRef
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        let activate = nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.installObserver(for: app)
            self.schedulePrecompute(app: app)
        }
        let deactivate = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.cache.invalidate(pid: app.processIdentifier)
            self.observers.removeValue(forKey: app.processIdentifier)
        }
        workspaceTokens.append(contentsOf: [activate, deactivate])

        if let front = NSWorkspace.shared.frontmostApplication {
            installObserver(for: front)
            schedulePrecompute(app: front)
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

    /// Activation always runs a fresh discovery. Reading from the cache would expose the user
    /// to deadline-truncated snapshots from the background precompute, which would make hint sets
    /// flicker between presses. The precompute pipeline now serves only as a warm-up for AX
    /// (the first AX query into an app pays a one-time cost); the live result is recomputed here.
    func discover(now context: AppContext) -> [JumpTarget] {
        let cfg = configRef()
        let targets = runChain(for: context, deadlineMs: cfg.providers.deadlineMsCold)
        cache.write(.init(pid: context.processID, bundleID: context.bundleIdentifier, frame: context.frontWindowFrame, targets: targets, timestamp: Date()))
        return targets
    }

    private func makeContext(for app: NSRunningApplication) -> AppContext? {
        let pid = app.processIdentifier
        guard pid > 0 else { return nil }
        let bundleID = app.bundleIdentifier ?? ""

        var screenFrame = CGRect.null
        for s in NSScreen.screens { screenFrame = screenFrame.union(s.frame) }
        if screenFrame.isNull { screenFrame = .zero }

        var windowFrame = screenFrame
        let axApp = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let window = focused {
            var posRef: AnyObject?
            var sizeRef: AnyObject?
            if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXPositionAttribute as CFString, &posRef) == .success,
               AXUIElementCopyAttributeValue(window as! AXUIElement, kAXSizeAttribute as CFString, &sizeRef) == .success {
                var origin = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                let screenH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                    ?? NSScreen.main?.frame.height ?? 1080
                let flippedY = screenH - origin.y - size.height
                windowFrame = CGRect(x: origin.x, y: flippedY, width: size.width, height: size.height)
            }
        }

        return AppContext(
            bundleIdentifier: bundleID,
            processID: pid,
            runningApp: app,
            frontWindowFrame: windowFrame,
            allScreensFrame: screenFrame
        )
    }

    private func schedulePrecompute(app: NSRunningApplication) {
        debounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let ctx = self.makeContext(for: app) else { return }
            let cfg = self.configRef()
            let targets = self.runChain(for: ctx, deadlineMs: cfg.providers.deadlineMsCold)
            self.cache.write(.init(pid: ctx.processID, bundleID: ctx.bundleIdentifier, frame: ctx.frontWindowFrame, targets: targets, timestamp: Date()))
        }
        debounce = item
        refreshQueue.asyncAfter(deadline: .now() + .milliseconds(30), execute: item)
    }

    private func runChain(for context: AppContext, deadlineMs: Int) -> [JumpTarget] {
        let deadline = Date().addingTimeInterval(TimeInterval(deadlineMs) / 1000.0)
        let chain = registry.chain(for: context)
        var seen: [CGRect] = []
        var out: [JumpTarget] = []
        for provider in chain {
            if Date() > deadline { break }
            let results = (try? provider.discover(in: context, deadline: deadline)) ?? []
            for t in results {
                if seen.contains(where: { rectsOverlapSubstantially($0, t.frame) }) { continue }
                seen.append(t.frame)
                out.append(t)
            }
        }
        return out
    }

    private func rectsOverlapSubstantially(_ a: CGRect, _ b: CGRect) -> Bool {
        let inter = a.intersection(b)
        if inter.isNull { return false }
        let interArea = inter.width * inter.height
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 && interArea / smaller > 0.7
    }

    // MARK: AXObserver
    private func installObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0 else { return }
        if observers[pid] != nil { return }
        var observerRef: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon = refcon else { return }
            let monitor = Unmanaged<AppMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleAXNotification()
        }
        let err = AXObserverCreate(pid, callback, &observerRef)
        guard err == .success, let observer = observerRef else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let axApp = AXUIElementCreateApplication(pid)
        let notifications: [String] = [
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXFocusedUIElementChangedNotification,
        ]
        for n in notifications {
            AXObserverAddNotification(observer, axApp, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func handleAXNotification() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        schedulePrecompute(app: front)
    }
}
