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

  @objc private func showAbout() {
    // LSUIElement apps don't front panels unless activated first.
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(nil)
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
