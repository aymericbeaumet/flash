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

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = ConfigLoader.load()
        registry = ProviderRegistry(config: config)
        monitor = AppMonitor(registry: registry, cache: cache, configRef: { [weak self] in self?.config ?? .default })
        monitor.start()

        overlay = OverlayPanel()
        overlay.coordinator = self
        overlay.overlayConfig = config.overlay

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Activation

    private func activate(rightClick: Bool) {
        guard let context = monitor.currentContext() else { return }
        sourceAppPID = context.processID
        let action: JumpAction = rightClick ? .rightClick : .leftClick
        pendingAction = action

        overlay.overlayConfig = config.overlay
        if !PermissionCheck.isAccessibilityTrusted {
            promptForAccessibility()
            return
        }

        let targets = monitor.discover(now: context)
        if targets.isEmpty { return }
        let alphabet = config.resolvedAlphabet
        let hints = HintAssigner.assign(targets: targets, alphabet: alphabet, minLength: config.hints.minLength)
        currentHints = hints
        currentPrefix = ""
        overlay.display(hints: hints)
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

    func overlayDidCommit(prefix: String, withShift: Bool) {
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
            commit(hint: matches[0], withShift: withShift)
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

    private func commit(hint: AssignedHint, withShift: Bool) {
        let action: JumpAction = (withShift && config.hints.shiftMeansRightClick) ? .rightClick : pendingAction
        overlay.hide()
        // Restore focus to the source app before dispatching, so AX press/click goes to the right window.
        if let pid = sourceAppPID, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
            _ = ActionDispatcher.perform(action, on: hint.target)
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
