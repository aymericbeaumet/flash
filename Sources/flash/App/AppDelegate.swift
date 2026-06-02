import AppKit
import ApplicationServices
import FlashCore

final class AppDelegate: NSObject, NSApplicationDelegate, OverlayCoordinator {
    private var config = Config.default
    private var registry: ProviderRegistry!
    private var cache = TargetCache()
    private var monitor: AppMonitor!
    private var overlay: OverlayPanel!
    private var urlHandler: URLEventHandler!
    private var configSource: DispatchSourceFileSystemObject?

    private var currentHints: [AssignedHint] = []
    private var currentPrefix: String = ""
    private var pendingAction: JumpAction = .leftClick
    private var sourceAppPID: pid_t?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var resignKeyToken: NSObjectProtocol?
    /// Set while an activation walk is in flight on the AX queue. New URL
    /// events that arrive during this window are dropped, not queued. Same
    /// guard rejects re-entry if hints are already on screen.
    private var activationInFlight: Bool = false
    /// Bumped on every `activate(rightClick:)` *and* every `cancelOverlay()`.
    /// The discovery completion captures the value at activation time and
    /// only renders if it still matches when the walk finishes. This is what
    /// prevents a stale walk from rendering hints over the wrong app after
    /// the user dismisses or switches focus mid-flight.
    private var activationGen: UInt64 = 0
    /// AX trust is checked once per session — until we observe `true`, we
    /// re-query each time. Once granted, the value is sticky for the rest
    /// of the run. Saves one IPC per activation in the steady state.
    /// Reset to `false` if an activation walk returns zero targets, which
    /// is the symptom of permission revocation mid-session.
    private var cachedAccessibilityTrusted: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = ConfigLoader.load()
        registry = ProviderRegistry(config: config)
        monitor = AppMonitor(registry: registry, cache: cache, config: config)
        monitor.start()

        overlay = OverlayPanel()
        overlay.coordinator = self
        overlay.overlayConfig = config.overlay
        overlay.debugConfig = config.debug
        // Pay the layer-allocation cost at launch instead of on the first
        // activation. 256 covers the steady state for most apps; further
        // growth uses the regular dequeue/alloc fallback.
        overlay.warmPool(count: 256)

        urlHandler = URLEventHandler { [weak self] cmd in
            guard let self else { return }
            switch cmd {
            case .activate(let right): self.activate(rightClick: right)
            case .cancel: self.cancelOverlay()
            case .quit: NSApp.terminate(nil)
            }
        }

        watchConfigFile()
        logPermissionState()
        installDismissObservers()
    }

    private func installDismissObservers() {
        // The user pressing Cmd-Tab, opening Mission Control, clicking another
        // app's window, switching Spaces, etc. should immediately hide the
        // overlay — its hint labels were computed against the previous front
        // app's geometry and would be wrong (and visually confusing) anywhere
        // else. Use the workspace's notification for app switches, plus
        // panel-level resignKey as a belt-and-suspenders catch for cases where
        // focus leaves Flash without an app switch (Spaces, full-screen apps,
        // some screen-saver paths).
        let nc = NSWorkspace.shared.notificationCenter
        let appSwitch = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // Ignore Flash itself activating (it shouldn't, but be safe).
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier == Bundle.main.bundleIdentifier {
                return
            }
            self.cancelOverlay()
        }
        let activeSpace = nc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.cancelOverlay() }
        workspaceTokens = [appSwitch, activeSpace]

        resignKeyToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: overlay,
            queue: .main
        ) { [weak self] _ in
            // Only dismiss if hints are actually showing — resignKey also fires
            // when hide() is invoked, which would otherwise create a loop.
            guard let self, !self.currentHints.isEmpty else { return }
            self.cancelOverlay()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Activation

    private func activate(rightClick: Bool) {
        // Drop concurrent / redundant triggers. A press during an in-flight
        // walk, or while hints are already on screen, is a no-op — never a
        // queued second activation. This is what makes rapid ctrl+space
        // presses behave: one walk, one overlay, no multi-fire backlog.
        if activationInFlight || !currentHints.isEmpty { return }

        guard let context = monitor.currentContext() else { return }
        sourceAppPID = context.processID
        pendingAction = rightClick ? .rightClick : .leftClick

        overlay.overlayConfig = config.overlay
        overlay.debugConfig = config.debug

        if !isAccessibilityTrusted() {
            promptForAccessibility()
            return
        }

        activationGen &+= 1
        let myGen = activationGen
        activationInFlight = true
        monitor.discoverAsync(context: context) { [weak self] hints in
            guard let self else { return }
            self.activationInFlight = false
            // The walk is done; gate is open for the next activation
            // regardless of whether *this* walk's result is still relevant.
            guard self.activationGen == myGen else { return }
            if hints.isEmpty {
                // Empty result is also the symptom of accessibility
                // permission being revoked between activations: AX walks
                // silently return [] when the process is no longer trusted.
                // Cheap to re-check — and we want the permission banner to
                // appear instead of the user staring at nothing.
                if !PermissionCheck.isAccessibilityTrusted {
                    self.cachedAccessibilityTrusted = false
                    self.promptForAccessibility()
                }
                return
            }
            self.currentHints = hints
            self.currentPrefix = ""
            self.overlay.display(hints: hints)
        }
    }

    private func isAccessibilityTrusted() -> Bool {
        if cachedAccessibilityTrusted { return true }
        let trusted = PermissionCheck.isAccessibilityTrusted
        if trusted { cachedAccessibilityTrusted = true }
        return trusted
    }

    private func cancelOverlay() {
        // The fast no-op exit: dismissal observers fire on every app switch,
        // including when no overlay is up. Skip the layer-recycle churn when
        // there's nothing to dismiss.
        if currentHints.isEmpty && !activationInFlight { return }
        overlay.hide()
        currentHints = []
        currentPrefix = ""
        sourceAppPID = nil
        // Invalidate any in-flight discovery walk's right to render. We
        // *don't* clear `activationInFlight` here — the walk is still
        // running on the AX queue and clearing the flag would let a fresh
        // activation arrive and race with the previous walk's completion.
        // Once the walk does complete, it checks the generation and bails.
        activationGen &+= 1
    }

    private var lastPermissionPromptAt: Date?

    private func promptForAccessibility() {
        // Open the Privacy & Security → Accessibility pane directly.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            let now = Date()
            if let last = lastPermissionPromptAt, now.timeIntervalSince(last) < 5 {
                // Settings was already opened recently; don't re-open.
            } else {
                NSWorkspace.shared.open(url)
                lastPermissionPromptAt = now
            }
        }
        let bundlePath = Bundle.main.bundlePath
        let lines = [
            "Flash needs Accessibility permission",
            "to read clickable elements from the focused app",
            "and to dispatch the click on commit.",
            "",
            "System Settings → Privacy & Security → Accessibility",
            "",
            "If Flash is NOT in the list:",
            "  Click '+' and add this exact path:",
            "  \(bundlePath)",
            "  Then enable the toggle.",
            "",
            "If Flash IS already in the list (toggle ON):",
            "  The grant is bound to the previous binary's hash.",
            "  Toggle Flash OFF then ON to re-bind to the current build.",
            "  (./Scripts/bundle.sh resets this for you next time.)",
            "",
            "System Settings has been opened.",
        ]
        overlay.displayBanner(lines.joined(separator: "\n"), durationMs: 10_000)
    }

    // MARK: OverlayCoordinator

    func overlayDidCancel() {
        cancelOverlay()
    }

    func overlayDidCommit(prefix: String) {
        if prefix == "__BACKSPACE__" {
            if !currentPrefix.isEmpty {
                currentPrefix.removeLast()
                overlay.filter(prefix: currentPrefix, hints: currentHints)
            }
            return
        }
        for ch in prefix.lowercased() {
            currentPrefix.append(ch)
        }
        overlay.filter(prefix: currentPrefix, hints: currentHints)

        // Single pass: count matches and remember the first one. Avoids
        // building a [AssignedHint] array per keystroke (was a 1-N alloc
        // every time the user typed a character). The hints carry a
        // pre-uppercased `display` field, so we don't pay an `uppercased()`
        // per chip per keystroke either.
        let upper = currentPrefix.uppercased()
        var matchCount = 0
        var firstMatch: AssignedHint?
        for h in currentHints where h.display.hasPrefix(upper) {
            matchCount += 1
            if matchCount == 1 {
                firstMatch = h
            } else {
                break
            }
        }
        if matchCount == 0 {
            cancelOverlay()
        } else if matchCount == 1, let m = firstMatch, m.display == upper {
            commit(hint: m)
        }
    }

    func overlayDidUpdatePrefix(_ prefix: String) {
        if prefix == "__BACKSPACE__" {
            if !currentPrefix.isEmpty {
                currentPrefix.removeLast()
                overlay.filter(prefix: currentPrefix, hints: currentHints)
            }
        } else {
            currentPrefix = prefix
            overlay.filter(prefix: currentPrefix, hints: currentHints)
        }
    }

    private func commit(hint: AssignedHint) {
        let action = pendingAction
        let pid = sourceAppPID
        // Compute the chip's centre BEFORE hiding the overlay so the dispatcher
        // can synthesize a click at the same on-screen point the user just saw.
        let chip = OverlayPanel.chipFrame(for: hint, fontSize: CGFloat(config.overlay.fontSize))
        let clickPoint = CGPoint(x: chip.midX, y: chip.midY)

        overlay.hide()
        // Restore focus to the source app before dispatching, so AXPress / the
        // synthesized click both reach the intended window.
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        // Hold the activation gate closed across the click dispatch. Without
        // this, the 20-ms delay below opens a window where a fresh
        // ctrl+space can land and start a second walk, and *this* commit's
        // click would then fire during the new activation (clicking
        // whatever the user was about to hint, not what they committed to).
        activationInFlight = true
        activationGen &+= 1
        currentHints = []
        currentPrefix = ""
        sourceAppPID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
            _ = ActionDispatcher.perform(action, on: hint.target, pid: pid, clickPoint: clickPoint)
            self?.activationInFlight = false
        }
    }

    // MARK: Config hot reload

    private func watchConfigFile() {
        let path = ConfigLoader.defaultPath.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let cfg = ConfigLoader.load()
            self.config = cfg
            self.overlay.overlayConfig = cfg.overlay
            self.overlay.debugConfig = cfg.debug
            // Publish to AppMonitor under its internal lock — this also
            // clears the precompute cache, whose hint labels are stale if
            // the alphabet changed.
            self.monitor.updateConfig(cfg)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configSource = source
    }

    private func logPermissionState() {
        let trusted = AXIsProcessTrusted()
        // Seed the activation-path cache so the very first ctrl+space
        // doesn't pay the AX IPC cost just to discover the user already
        // granted permission at some prior session.
        if trusted { cachedAccessibilityTrusted = true }
        if !trusted {
            fputs("flash: Accessibility permission not granted. Grant it in System Settings → Privacy & Security → Accessibility for /Applications/Flash.app.\n", stderr)
        }
    }
}
