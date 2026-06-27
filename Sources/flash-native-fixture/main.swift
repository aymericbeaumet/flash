import AppKit
import Foundation

private func argumentValue(_ name: String) -> String? {
  let args = CommandLine.arguments
  guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
    return nil
  }
  return args[index + 1]
}

private func hasArgument(_ name: String) -> Bool {
  CommandLine.arguments.contains(name)
}

final class NativeFixtureDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
  NSPopoverDelegate, NSTableViewDataSource, NSTableViewDelegate
{
  private let stateURL: URL?
  private let opensMenuOnLaunch: Bool
  private var window: NSWindow?
  private var statusItem: NSStatusItem?
  private var statusPopover: NSPopover?
  private let rows = ["Row Alpha", "Row Beta", "Row Gamma"]
  private var state: [String: Int] = [
    "context_menu": 0,
    "duplicate": 0,
    "icon": 0,
    "primary": 0,
    "radio": 0,
    "status_popover_closed": 0,
    "status_popover": 0,
    "toggle": 0,
  ]

  init(statePath: String?, opensMenuOnLaunch: Bool) {
    if let statePath {
      self.stateURL = URL(fileURLWithPath: statePath)
    } else {
      self.stateURL = nil
    }
    self.opensMenuOnLaunch = opensMenuOnLaunch
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    writeState()

    let window = NSWindow(
      contentRect: NSRect(x: 120, y: 120, width: 820, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "Flash Native Fixture"
    window.isReleasedWhenClosed = false
    self.window = window

    let content = NSView(frame: window.contentView?.bounds ?? .zero)
    content.autoresizingMask = [.width, .height]
    window.contentView = content

    let title = NSTextField(labelWithString: "Flash Native Fixture")
    title.frame = NSRect(x: 24, y: 585, width: 320, height: 24)
    title.font = .systemFont(ofSize: 18, weight: .semibold)
    content.addSubview(title)

    let primary = NSButton(title: "Primary Action", target: self, action: #selector(primaryPressed))
    primary.frame = NSRect(x: 24, y: 528, width: 150, height: 34)
    primary.bezelStyle = .rounded
    primary.setAccessibilityIdentifier("flash-native-primary")
    content.addSubview(primary)

    let toggle = NSButton(
      checkboxWithTitle: "Toggle Option", target: self, action: #selector(togglePressed))
    toggle.frame = NSRect(x: 200, y: 530, width: 170, height: 28)
    toggle.setAccessibilityIdentifier("flash-native-toggle")
    content.addSubview(toggle)

    let disabled = NSButton(title: "Disabled Action", target: nil, action: nil)
    disabled.frame = NSRect(x: 400, y: 528, width: 150, height: 34)
    disabled.bezelStyle = .rounded
    disabled.isEnabled = false
    disabled.setAccessibilityIdentifier("flash-native-disabled")
    content.addSubview(disabled)

    let hidden = NSButton(title: "Hidden Action", target: nil, action: nil)
    hidden.frame = NSRect(x: 580, y: 528, width: 130, height: 34)
    hidden.bezelStyle = .rounded
    hidden.isHidden = true
    hidden.setAccessibilityIdentifier("flash-native-hidden")
    content.addSubview(hidden)

    let icon = NSButton(title: "", target: self, action: #selector(iconPressed))
    icon.frame = NSRect(x: 24, y: 478, width: 42, height: 34)
    icon.bezelStyle = .rounded
    icon.image = makeIconImage()
    icon.setAccessibilityLabel("Icon Action")
    icon.setAccessibilityIdentifier("flash-native-icon")
    content.addSubview(icon)

    let duplicateA = NSButton(
      title: "Duplicate Action", target: self, action: #selector(duplicatePressed))
    duplicateA.frame = NSRect(x: 92, y: 478, width: 145, height: 34)
    duplicateA.bezelStyle = .rounded
    duplicateA.setAccessibilityIdentifier("flash-native-duplicate-a")
    content.addSubview(duplicateA)

    let duplicateB = NSButton(
      title: "Duplicate Action", target: self, action: #selector(duplicatePressed))
    duplicateB.frame = NSRect(x: 256, y: 478, width: 145, height: 34)
    duplicateB.bezelStyle = .rounded
    duplicateB.setAccessibilityIdentifier("flash-native-duplicate-b")
    content.addSubview(duplicateB)

    let radio = NSButton(
      radioButtonWithTitle: "Radio Choice", target: self, action: #selector(radioPressed))
    radio.frame = NSRect(x: 426, y: 482, width: 150, height: 26)
    radio.setAccessibilityIdentifier("flash-native-radio")
    content.addSubview(radio)

    let popup = NSPopUpButton(
      frame: NSRect(x: 24, y: 420, width: 180, height: 32), pullsDown: false)
    popup.addItems(withTitles: ["Menu Choice", "Second Choice", "Third Choice"])
    popup.setAccessibilityIdentifier("flash-native-popup")
    popup.setAccessibilityLabel("Menu Choice")
    content.addSubview(popup)

    let search = NSSearchField(frame: NSRect(x: 230, y: 420, width: 220, height: 28))
    search.placeholderString = "Native Search Field"
    search.stringValue = ""
    search.setAccessibilityIdentifier("flash-native-search")
    search.setAccessibilityLabel("Native Search Field")
    content.addSubview(search)

    let disabledText = NSTextField(frame: NSRect(x: 480, y: 420, width: 190, height: 28))
    disabledText.placeholderString = "Disabled Text Field"
    disabledText.isEnabled = false
    disabledText.setAccessibilityIdentifier("flash-native-disabled-text")
    disabledText.setAccessibilityLabel("Disabled Text Field")
    content.addSubview(disabledText)

    let textArea = NSTextView(frame: NSRect(x: 0, y: 0, width: 245, height: 80))
    textArea.string = "Notes fixture text"
    textArea.setAccessibilityIdentifier("flash-native-notes")
    textArea.setAccessibilityLabel("Native Notes Area")
    let textAreaScroll = NSScrollView(frame: NSRect(x: 24, y: 314, width: 260, height: 86))
    textAreaScroll.documentView = textArea
    textAreaScroll.hasVerticalScroller = true
    content.addSubview(textAreaScroll)

    let tabs = NSTabView(frame: NSRect(x: 320, y: 292, width: 300, height: 108))
    let general = NSTabViewItem(identifier: "general")
    general.label = "General Tab"
    general.view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 70))
    let advanced = NSTabViewItem(identifier: "advanced")
    advanced.label = "Advanced Tab"
    advanced.view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 70))
    tabs.addTabViewItem(general)
    tabs.addTabViewItem(advanced)
    tabs.setAccessibilityIdentifier("flash-native-tabs")
    content.addSubview(tabs)

    let slider = NSSlider(value: 35, minValue: 0, maxValue: 100, target: nil, action: nil)
    slider.frame = NSRect(x: 650, y: 340, width: 130, height: 24)
    slider.setAccessibilityIdentifier("flash-native-slider")
    slider.setAccessibilityLabel("Native Slider")
    content.addSubview(slider)

    let image = NSImageView(frame: NSRect(x: 678, y: 400, width: 44, height: 44))
    image.image = makeIconImage()
    image.setAccessibilityIdentifier("flash-native-decorative-image")
    image.setAccessibilityLabel("Decorative Image")
    content.addSubview(image)

    let tableLabel = NSTextField(labelWithString: "Rows")
    tableLabel.frame = NSRect(x: 24, y: 272, width: 100, height: 20)
    content.addSubview(tableLabel)

    let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 260, height: 130))
    table.setAccessibilityIdentifier("flash-native-table")
    table.headerView = nil
    table.delegate = self
    table.dataSource = self
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    column.width = 250
    table.addTableColumn(column)
    let scroll = NSScrollView(frame: NSRect(x: 24, y: 124, width: 280, height: 130))
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    content.addSubview(scroll)

    let openMenuButton = NSButton(
      title: "Open Fixture Menu", target: self, action: #selector(openFixtureMenu))
    openMenuButton.frame = NSRect(x: 340, y: 206, width: 170, height: 34)
    openMenuButton.bezelStyle = .rounded
    openMenuButton.setAccessibilityIdentifier("flash-native-open-menu")
    content.addSubview(openMenuButton)

    let contextTarget = NSButton(title: "Context Target", target: self, action: nil)
    contextTarget.frame = NSRect(x: 540, y: 206, width: 150, height: 34)
    contextTarget.bezelStyle = .rounded
    contextTarget.setAccessibilityIdentifier("flash-native-context-target")
    contextTarget.menu = makeContextMenu()
    content.addSubview(contextTarget)

    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    installStatusItem()

    if opensMenuOnLaunch {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600)) { [weak self] in
        self?.showFixtureMenu(anchor: openMenuButton)
      }
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }

  func tableView(
    _ tableView: NSTableView,
    viewFor tableColumn: NSTableColumn?,
    row: Int
  ) -> NSView? {
    let identifier = NSUserInterfaceItemIdentifier("cell")
    let text: NSTextField
    if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
      text = reused
    } else {
      text = NSTextField(labelWithString: "")
      text.identifier = identifier
    }
    text.stringValue = rows[row]
    text.setAccessibilityLabel(rows[row])
    return text
  }

  @objc private func primaryPressed() {
    state["primary", default: 0] += 1
    writeState()
  }

  @objc private func togglePressed(_ sender: NSButton) {
    state["toggle"] = sender.state == .on ? 1 : 0
    writeState()
  }

  @objc private func iconPressed() {
    state["icon", default: 0] += 1
    writeState()
  }

  @objc private func duplicatePressed() {
    state["duplicate", default: 0] += 1
    writeState()
  }

  @objc private func radioPressed(_ sender: NSButton) {
    state["radio"] = sender.state == .on ? 1 : 0
    writeState()
  }

  @objc private func openFixtureMenu(_ sender: NSButton) {
    showFixtureMenu(anchor: sender)
  }

  private func showFixtureMenu(anchor sender: NSButton) {
    let menu = NSMenu(title: "Fixture Menu")
    menu.addItem(withTitle: "Menu Item Alpha", action: nil, keyEquivalent: "")
    menu.addItem(withTitle: "Menu Item Beta", action: nil, keyEquivalent: "")
    menu.popUp(
      positioning: nil, at: NSPoint(x: sender.bounds.minX, y: sender.bounds.minY), in: sender)
  }

  private func makeContextMenu() -> NSMenu {
    let menu = NSMenu(title: "Fixture Context Menu")
    menu.delegate = self
    let alpha = NSMenuItem(
      title: "Context Item Alpha",
      action: #selector(contextMenuItemPressed),
      keyEquivalent: "")
    alpha.target = self
    menu.addItem(alpha)
    let beta = NSMenuItem(
      title: "Context Item Beta",
      action: #selector(contextMenuItemPressed),
      keyEquivalent: "")
    beta.target = self
    menu.addItem(beta)
    return menu
  }

  func menuWillOpen(_ menu: NSMenu) {
    if menu.title == "Fixture Context Menu" {
      state["context_menu", default: 0] += 1
      writeState()
    }
  }

  @objc private func contextMenuItemPressed() {
    writeState()
  }

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem = item
    guard let button = item.button else { return }
    button.title = "FlashNativeStatus"
    button.target = self
    button.action = #selector(toggleStatusPopover)
    button.setAccessibilityLabel("FlashNativeStatus")
    button.setAccessibilityIdentifier("flash-native-status-item")
  }

  @objc private func toggleStatusPopover(_ sender: NSStatusBarButton) {
    if statusPopover?.isShown == true {
      statusPopover?.performClose(sender)
      return
    }
    state["status_popover", default: 0] += 1
    writeState()
    let popover = NSPopover()
    popover.behavior = .transient
    popover.delegate = self
    popover.contentSize = NSSize(width: 260, height: 120)
    let controller = NSViewController()
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 120))
    let title = NSTextField(labelWithString: "Fixture Status Popover")
    title.frame = NSRect(x: 16, y: 78, width: 220, height: 22)
    title.setAccessibilityIdentifier("flash-native-status-popover-title")
    view.addSubview(title)
    let field = NSTextField(frame: NSRect(x: 16, y: 36, width: 220, height: 28))
    field.placeholderString = "Status Popover Input"
    field.setAccessibilityLabel("Status Popover Input")
    field.setAccessibilityIdentifier("flash-native-status-popover-input")
    view.addSubview(field)
    controller.view = view
    popover.contentViewController = controller
    statusPopover = popover
    popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
  }

  func popoverDidClose(_ notification: Notification) {
    state["status_popover_closed", default: 0] += 1
    writeState()
  }

  private func writeState() {
    guard let stateURL else { return }
    let payload = state.map { "\"\($0.key)\":\($0.value)" }.sorted().joined(separator: ",")
    try? FileManager.default.createDirectory(
      at: stateURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try? "{\(payload)}\n".write(to: stateURL, atomically: true, encoding: .utf8)
  }
}

private func makeIconImage() -> NSImage {
  let image = NSImage(size: NSSize(width: 18, height: 18))
  image.lockFocus()
  NSColor.systemBlue.setFill()
  NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14)).fill()
  NSColor.white.setFill()
  NSBezierPath(rect: NSRect(x: 8, y: 5, width: 2, height: 8)).fill()
  NSBezierPath(rect: NSRect(x: 5, y: 8, width: 8, height: 2)).fill()
  image.unlockFocus()
  image.isTemplate = false
  return image
}

let delegate = NativeFixtureDelegate(
  statePath: argumentValue("--state-file"),
  opensMenuOnLaunch: hasArgument("--open-menu-on-launch"))
let app = NSApplication.shared
app.delegate = delegate
app.run()
