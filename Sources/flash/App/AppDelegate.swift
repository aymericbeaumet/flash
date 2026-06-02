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
    /// AX trust is checked once per session — until we observe `true`, we
    /// re-query each time. Once granted, the value is sticky for the rest
    /// of the run. Saves one IPC per activation in the steady state.
    private var cachedAccessibilityTrusted: Bool = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = ConfigLoader.load()
        registry = ProviderRegistry(config: config)
        monitor = AppMonitor(registry: registry, cache: cache, configRef: { [weak self] in self?.config ?? .default })
        monitor.start()

        overlay = OverlayPanel()
        overlay.coordinator = self
        overlay.overlayConfig = config.overlay
        overlay.debugConfig = config.debug

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

        activationInFlight = true
        monitor.discoverAsync(context: context) { [weak self] targets in
            guard let self else { return }
            self.activationInFlight = false
            // If we were dismissed (Esc) before the walk finished, skip render.
            guard self.sourceAppPID == context.processID else { return }
            if targets.isEmpty { return }
            let resolved = self.config.resolvedAlphabet
            let hints = HintAssigner.assign(
                targets: targets,
                alphabet: resolved.chars,
                leftHand: resolved.leftHand,
                minLength: self.config.hints.minLength
            )
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
        overlay.hide()
        currentHints = []
        currentPrefix = ""
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

        let upper = currentPrefix.uppercased()
        let matches = currentHints.filter { $0.label.uppercased().hasPrefix(upper) }
        if matches.count == 1 && matches[0].label.uppercased() == upper {
            commit(hint: matches[0])
        } else if matches.isEmpty {
            cancelOverlay()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
            _ = ActionDispatcher.perform(action, on: hint.target, pid: pid, clickPoint: clickPoint)
        }
        currentHints = []
        currentPrefix = ""
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
            self.config = ConfigLoader.load()
            self.overlay.overlayConfig = self.config.overlay
            self.overlay.debugConfig = self.config.debug
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configSource = source
    }

    private func logPermissionState() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            fputs("flash: Accessibility permission not granted. Grant it in System Settings → Privacy & Security → Accessibility for /Applications/Flash.app.\n", stderr)
        }
    }
}
