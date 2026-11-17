import AppKit

/// What the About window's update line shows after a check or an install.
struct AboutUpdateStatus: Equatable {
  var message: String
  /// The release the button installs next, when there is one.
  var installVersion: String?
}

/// The About window's update button, wired by `AppDelegate` to the same
/// check and install the `updates` commands run.
struct AboutUpdateActions {
  var check: (@escaping (AboutUpdateStatus) -> Void) -> Void
  var install: (@escaping (AboutUpdateStatus) -> Void) -> Void
}

/// The one sanctioned NSStatusItem: a menu-bar bolt with exactly three
/// entries — About, Open Configuration, Quit. `[app] menu_bar_icon = false`
/// removes it; everything Flash does stays reachable through the CLI and
/// mappings without it. This is deliberately NOT a preferences surface —
/// configuration lives in the TOML file the middle entry opens.
/// All entry points run on the main thread (config load/reload) — AppKit's
/// status bar APIs require it.
final class StatusItemController: NSObject {
  private var statusItem: NSStatusItem?
  var aboutVisibilityDidChange: ((Bool) -> Void)?
  /// The About window became or stopped being the key window.
  var aboutKeyDidChange: (() -> Void)?
  var updateActions: AboutUpdateActions?
  private var updateButton: NSButton?
  private var updateLabel: NSTextField?
  private var aboutInstallVersion: String?

  func apply(enabled: Bool) {
    if enabled {
      guard statusItem == nil else { return }
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
      let icon = NSImage(
        systemSymbolName: "bolt.fill", accessibilityDescription: "Flash")
      icon?.isTemplate = true
      item.button?.image = icon
      let menu = NSMenu()
      menu.addItem(
        NSMenuItem(title: "About Flash", action: #selector(showAbout), keyEquivalent: ""))
      menu.addItem(
        NSMenuItem(
          title: "Open Configuration", action: #selector(openConfiguration), keyEquivalent: ""))
      menu.addItem(.separator())
      menu.addItem(NSMenuItem(title: "Quit Flash", action: #selector(quit), keyEquivalent: ""))
      for entry in menu.items { entry.target = self }
      item.menu = menu
      statusItem = item
    } else if let item = statusItem {
      NSStatusBar.system.removeStatusItem(item)
      statusItem = nil
    }
  }

  private var aboutPanel: NSWindow?
  private static let repoURL = URL(string: "https://github.com/aymericbeaumet/flash")!
  /// `[app] hide_from_capture` for the About window, made or not yet.
  var hidesFromCapture = false {
    didSet {
      guard hidesFromCapture != oldValue else { return }
      aboutPanel?.sharingType = CaptureSharing.sharingType(hidden: hidesFromCapture)
    }
  }

  var focusedAboutWindowFrame: CGRect? {
    guard NSApp.isActive, let aboutPanel, aboutPanel.isVisible, aboutPanel.isKeyWindow else {
      return nil
    }
    return aboutPanel.frame
  }

  @objc func showAbout() {
    // A small custom About panel instead of orderFrontStandardAboutPanel:
    // the standard panel's credit links don't reliably open in an
    // LSUIElement app, and a real button through NSWorkspace always does.
    // LSUIElement apps also don't front panels unless activated first.
    //
    // While the About window is open Flash joins the app switcher (policy
    // .regular) so the user can Cmd-Tab back to it; the moment it closes
    // Flash returns to its headless accessory policy. This transient flip
    // is the sanctioned exception to the no-Dock-presence rule.
    aboutVisibilityDidChange?(true)
    presentAboutPanel(aboutWindow())
  }

  /// The one About window, made on first use and kept; never shown here.
  func aboutWindow() -> NSWindow {
    if let panel = aboutPanel { return panel }
    let name =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Flash"
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    // Display the abbreviated hash; the full one is still in Info.plist for
    // anyone who needs an exact ref.
    let fullCommit =
      Bundle.main.object(forInfoDictionaryKey: "FlashGitCommit") as? String ?? "unknown"
    let commit = fullCommit == "unknown" ? fullCommit : String(fullCommit.prefix(7))

    let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
    icon.setFrameSize(NSSize(width: 64, height: 64))

    let title = NSTextField(labelWithString: name)
    title.font = .boldSystemFont(ofSize: 15)

    let versionLabel = NSTextField(labelWithString: "Version \(version)")
    versionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    versionLabel.textColor = .secondaryLabelColor

    let commitLabel = NSTextField(labelWithString: commit)
    commitLabel.font = .monospacedSystemFont(
      ofSize: NSFont.smallSystemFontSize, weight: .regular)
    commitLabel.textColor = .secondaryLabelColor
    commitLabel.isSelectable = true
    // No focus ring: selecting the hash (or clicking the link below) should
    // never draw a border around the control.
    commitLabel.focusRingType = .none

    let repoButton = NSButton(
      title: "github.com/aymericbeaumet/flash", target: self, action: #selector(openRepo))
    repoButton.bezelStyle = .inline
    repoButton.focusRingType = .none

    let updateButton = NSButton(
      title: "Check for Updates…", target: self, action: #selector(updateButtonClicked))
    updateButton.bezelStyle = .rounded
    updateButton.isHidden = updateActions == nil
    self.updateButton = updateButton

    let updateLabel = NSTextField(wrappingLabelWithString: "")
    updateLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    updateLabel.textColor = .secondaryLabelColor
    updateLabel.alignment = .center
    updateLabel.preferredMaxLayoutWidth = 280
    updateLabel.isHidden = true
    self.updateLabel = updateLabel

    let stack = NSStackView(views: [
      icon, title, versionLabel, commitLabel, updateButton, updateLabel, repoButton,
    ])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 32, left: 56, bottom: 32, right: 56)

    // A real NSWindow, not an NSPanel: panels draw a compact title bar with
    // a left-aligned title and hide on app deactivation — the About window
    // wants a standard, centered title and normal persistence.
    let panel = AboutWindow(
      contentRect: .zero,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    panel.title = "About"
    panel.sharingType = CaptureSharing.sharingType(hidden: hidesFromCapture)
    panel.contentView = stack
    var contentSize = stack.fittingSize
    contentSize.width = max(contentSize.width, 340)
    panel.setContentSize(contentSize)
    panel.isReleasedWhenClosed = false
    // NSPanel hides itself when the app deactivates by default — clicking
    // anywhere else made the About window vanish. It should stay up until
    // explicitly closed.
    panel.hidesOnDeactivate = false
    NotificationCenter.default.addObserver(
      self, selector: #selector(aboutPanelWillClose(_:)),
      name: NSWindow.willCloseNotification, object: panel)
    NotificationCenter.default.addObserver(
      self, selector: #selector(aboutPanelResignedKey(_:)),
      name: NSWindow.didResignKeyNotification, object: panel)
    NotificationCenter.default.addObserver(
      self, selector: #selector(aboutPanelBecameKey(_:)),
      name: NSWindow.didBecomeKeyNotification, object: panel)
    aboutPanel = panel
    return panel
  }

  private func presentAboutPanel(_ panel: NSWindow) {
    AppActivation.setPolicy(.regular)
    panel.center()
    panel.makeKeyAndOrderFront(nil)
    AppActivation.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    DispatchQueue.main.async { [weak panel] in
      guard let panel, panel.isVisible else { return }
      AppActivation.activate(ignoringOtherApps: true)
      panel.makeKeyAndOrderFront(nil)
    }
  }

  @objc private func aboutPanelResignedKey(_ note: Notification) {
    FlashLog.debug(
      "[about] resigned_key visible=\(aboutPanel?.isVisible ?? false) "
        + "occluded=\(!(aboutPanel?.occlusionState.contains(.visible) ?? true))")
    aboutKeyDidChange?()
  }

  @objc private func aboutPanelBecameKey(_ note: Notification) {
    aboutKeyDidChange?()
  }

  /// Whether the About window is shown and is the key window: then it owns
  /// the keyboard, as any window does. AppKit state only, no IPC.
  var aboutWindowIsKey: Bool {
    guard let panel = aboutPanel else { return false }
    return panel.isVisible && panel.isKeyWindow
  }

  @objc private func aboutPanelWillClose(_ note: Notification) {
    FlashLog.debug("[about] will_close")
    // Leave the app switcher again — Flash is headless outside the About
    // window's lifetime.
    AppActivation.setPolicy(.accessory)
    aboutVisibilityDidChange?(false)
  }

  /// One check, or the install it found, at a time; the line under the
  /// button says what happened.
  @objc private func updateButtonClicked() {
    guard let actions = updateActions, let button = updateButton, let label = updateLabel else {
      return
    }
    let installing = aboutInstallVersion != nil
    button.isEnabled = false
    label.isHidden = false
    label.stringValue = installing ? "Installing…" : "Checking…"
    fitAboutPanel()
    let done: (AboutUpdateStatus) -> Void = { [weak self] status in
      guard let self else { return }
      self.aboutInstallVersion = status.installVersion
      self.updateLabel?.stringValue = status.message
      self.updateLabel?.isHidden = status.message.isEmpty
      self.updateButton?.title =
        status.installVersion.map { "Install \($0)…" } ?? "Check for Updates…"
      self.updateButton?.isEnabled = true
      self.fitAboutPanel()
    }
    if installing { actions.install(done) } else { actions.check(done) }
  }

  private func fitAboutPanel() {
    guard let panel = aboutPanel, let content = panel.contentView else { return }
    var size = content.fittingSize
    size.width = max(size.width, 340)
    panel.setContentSize(size)
  }

  @objc private func openRepo() {
    NSWorkspace.shared.open(
      Self.repoURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
  }

  /// The file may have been deleted since launch: `config edit` re-seeds the
  /// starter so the editor opens something to save into.
  @objc private func openConfiguration() {
    AppDelegate.openConfigurationFile()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}

/// The About window: close-window chords — W or Q under any mix of ⌘/⌃
/// (optionally with ⇧, e.g. ⌘⇧W / ⌘⇧Q) — close JUST this window. Flash
/// itself is a resident app and must never quit from a keystroke that was
/// aimed at a window.
private final class AboutWindow: NSWindow {
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let closeChord =
      !modifiers.isDisjoint(with: [.command, .control])
      && modifiers.subtracting([.command, .control, .shift]).isEmpty
    let key = event.charactersIgnoringModifiers?.lowercased()
    if closeChord, key == "w" || key == "q" {
      close()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}
