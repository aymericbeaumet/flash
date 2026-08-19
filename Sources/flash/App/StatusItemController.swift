import AppKit

/// The one sanctioned NSStatusItem: a menu-bar bolt with exactly three
/// entries — About, Open Configuration, Quit. `[app] menu_bar_icon = false`
/// removes it; everything Flash does stays reachable through the CLI and
/// mappings without it. This is deliberately NOT a preferences surface —
/// configuration lives in the TOML file the middle entry opens.
/// All entry points run on the main thread (config load/reload) — AppKit's
/// status bar APIs require it.
final class StatusItemController: NSObject {
  private var statusItem: NSStatusItem?

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

  private var aboutPanel: NSPanel?
  private static let repoURL = URL(string: "https://github.com/aymericbeaumet/flash")!

  @objc private func showAbout() {
    // A small custom About panel instead of orderFrontStandardAboutPanel:
    // the standard panel's credit links don't reliably open in an
    // LSUIElement app, and a real button through NSWorkspace always does.
    // LSUIElement apps also don't front panels unless activated first.
    NSApp.activate(ignoringOtherApps: true)
    if let panel = aboutPanel {
      panel.center()
      panel.makeKeyAndOrderFront(nil)
      return
    }

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

    let stack = NSStackView(views: [icon, title, versionLabel, commitLabel, repoButton])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 32, left: 56, bottom: 32, right: 56)

    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    panel.title = "About"
    panel.contentView = stack
    var contentSize = stack.fittingSize
    contentSize.width = max(contentSize.width, 340)
    panel.setContentSize(contentSize)
    panel.isReleasedWhenClosed = false
    panel.center()
    panel.makeKeyAndOrderFront(nil)
    aboutPanel = panel
  }

  @objc private func openRepo() {
    NSWorkspace.shared.open(Self.repoURL)
  }

  @objc private func openConfiguration() {
    let url = ConfigLoader.resolvePath(
      arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
    let fm = FileManager.default
    if !fm.fileExists(atPath: url.path) {
      // First open on a fresh machine: seed an empty file so the editor
      // has something to save into.
      try? fm.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      fm.createFile(atPath: url.path, contents: Data())
    }
    NSWorkspace.shared.open(url)
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
