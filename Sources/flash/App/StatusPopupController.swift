import AppKit
import FlashTerminal

private final class StatusPopupPanel: NSPanel {
  var focusLost: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  init() {
    super.init(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: true)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    hidesOnDeactivate = false
    acceptsMouseMovedEvents = true
    level = OverlayPanel.statusBarClickWindowLevel
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
  }

  override func resignKey() {
    super.resignKey()
    focusLost?()
  }
}

/// Owns only presentation. The registry continues parsing PTYs after this panel hides.
final class StatusPopupController {
  let terminals: StatusTerminalRegistry
  private(set) var presentation: StatusPopupPresentation = .hidden
  private(set) var content: String = ""
  private let panel = StatusPopupPanel()
  private let windowActionsEnabled: Bool
  private let container = NSView(frame: .zero)
  let terminalView = TerminalView(frame: .zero)
  private var documents: [String: TerminalDocument] = [:]
  private struct DocumentRevision: Equatable {
    var segments: [FlashStatusTextSegment]
    var columns: Int
    var rows: Int
  }
  private var documentRevisions: [String: DocumentRevision] = [:]
  private var lastLifecycleName: String?
  private var lastLifecycleFields: [String: String] = [:]
  private var lastLayoutName: String?
  private var lastLayoutFields: [String: String] = [:]
  private let exitLabel = NSTextField(labelWithString: "")
  private var region: StatusBarPopupRegion?
  private var visibleFrame = CGRect.zero
  private var style = Config.StatusBar.PopupStyle()
  private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
  var willFocus: (() -> Void)?
  var willDismissFocus: (() -> Void)?
  var didDismissFocus: ((String) -> Void)?
  var didDismiss: ((String) -> Void)?
  var inputInterceptor: ((NSEvent) -> Bool)?

  var frame: CGRect { panel.frame }
  var exitStatusText: String { exitLabel.stringValue }
  var isVisible: Bool { presentation.identity != nil }
  var focusedName: String? { presentation.isFocused ? presentation.identity?.name : nil }

  init(terminals: StatusTerminalRegistry, windowActionsEnabled: Bool = true) {
    self.terminals = terminals
    self.windowActionsEnabled = windowActionsEnabled
    container.wantsLayer = true
    container.layer?.masksToBounds = true
    container.addSubview(terminalView)
    container.addSubview(exitLabel)
    panel.contentView = container
    panel.focusLost = { [weak self] in
      guard let self, self.presentation.isFocused else { return }
      self.dismiss(reason: "focus_lost")
    }
    terminalView.onFocusRequested = { [weak self] in self?.focus() }
    terminalView.inputInterceptor = { [weak self] event in self?.inputInterceptor?(event) ?? false }
    terminals.willChange = { [weak self] changes in
      guard let self, let name = self.presentation.identity?.name else { return }
      if changes.contains(.remove(name)) {
        self.dismiss(reason: "terminal_removed")
      } else if changes.contains(.replace(name)), self.presentation.isFocused {
        self.willDismissFocus?()
      }
    }
    terminals.didChange = { [weak self] in
      guard let self, let region = self.region, self.isVisible else { return }
      self.layout(region: region)
    }
  }

  func preview(
    _ region: StatusBarPopupRegion, pointer: CGPoint,
    visibleFrame: CGRect, style: Config.StatusBar.PopupStyle, font: NSFont
  ) {
    guard !presentation.isStandalone else { return }
    if presentation.isFocused {
      if presentation.identity?.name == region.name {
        self.region = region
        self.style = style
        self.font = font
        self.visibleFrame = visibleFrame
        layout(region: region)
        return
      }
      return
    }
    self.region = region
    self.visibleFrame = visibleFrame
    self.style = style
    self.font = font
    transition(.anchor(name: region.name, point: pointer))
    layout(region: region)
    terminalView.isRenderingEnabled = true
    if windowActionsEnabled { panel.orderFrontRegardless() }
    logLifecycle(reason: "preview")
  }

  func showTerminal(
    name: String, visibleFrame: CGRect, style: Config.StatusBar.PopupStyle, font: NSFont
  ) {
    guard terminals.sessions[name] != nil, terminals.definitions[name] != nil else { return }
    let alreadyFocused = presentation == .terminal(name: name)
    if isVisible && !alreadyFocused { dismiss(reason: "terminal_replaced") }
    let terminalRegion = StatusBarPopupRegion(rect: .zero, name: name, content: "")
    region = terminalRegion
    self.visibleFrame = visibleFrame
    self.style = style
    self.font = font
    transition(.terminal(name: name))
    layout(region: terminalRegion)
    terminalView.isRenderingEnabled = true
    if !alreadyFocused { willFocus?() }
    activateTerminalInput()
    logLifecycle(reason: "terminal_opened")
  }

  func repositionTerminal(visibleFrame: CGRect) {
    guard presentation.isStandalone, let region else { return }
    self.visibleFrame = visibleFrame
    layout(region: region)
  }

  func refresh(_ regions: [StatusBarPopupRegion]) {
    guard !presentation.isStandalone else { return }
    guard let name = presentation.identity?.name else { return }
    guard let updated = regions.first(where: { $0.name == name }) else {
      dismiss(reason: "region_removed")
      return
    }
    region = updated
    layout(region: updated)
  }

  func updateStyle(_ style: Config.StatusBar.PopupStyle) {
    self.style = style
    if isVisible, let region { layout(region: region) }
  }

  func leaveAnchor() {
    guard presentation.applying(.leaveAnchor) != presentation else { return }
    dismiss(reason: "anchor_left")
  }

  func dismiss(reason: String = "dismiss") {
    let previousName = presentation.identity?.name
    let wasFocused = presentation.isFocused
    if wasFocused { willDismissFocus?() }
    transition(.dismiss)
    terminalView.isRenderingEnabled = false
    terminalView.bind(session: nil)
    if windowActionsEnabled { panel.orderOut(nil) }
    logLifecycle(reason: reason)
    region = nil
    if wasFocused { didDismissFocus?(reason) }
    if let previousName { didDismiss?(previousName) }
  }

  func focus() {
    guard isVisible, !presentation.isFocused else { return }
    transition(.focus)
    willFocus?()
    activateTerminalInput()
    logLifecycle(reason: "focus")
  }

  private func activateTerminalInput() {
    guard windowActionsEnabled else { return }
    NSApp.activate()
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(terminalView)
  }

  private func diagnosticState() -> [String: String] {
    [
      "state":
        !isVisible
        ? "hidden"
        : presentation.isStandalone ? "terminal" : presentation.isFocused ? "focused" : "preview",
      "rendering_enabled": String(terminalView.isRenderingEnabled),
      "frame_ready": String(terminalView.terminalFrame != nil),
      "panel_visible": String(panel.isVisible),
      "window_actions_enabled": String(windowActionsEnabled),
    ]
  }

  private func logLifecycle(reason: String) {
    let fields = diagnosticState()
    let name = presentation.identity?.name
    guard lastLifecycleName != name || lastLifecycleFields != fields else { return }
    let popupName = name ?? lastLifecycleName
    lastLifecycleName = name
    lastLifecycleFields = fields
    var details = fields
    details["reason"] = reason
    details["popup_id"] = popupName.map(StatusFormatDocument.stableID) ?? "none"
    details["content_bytes"] = String(content.utf8.count)
    FlashLog.debug(
      "Status popup presentation changed", fields: details,
      source: "core:StatusPopupController.presentation")
    if !isVisible {
      lastLayoutName = nil
      lastLayoutFields = [:]
    }
  }

  private func transition(_ event: StatusPopupPresentation.Event) {
    let next = presentation.applying(event)
    guard next != presentation else { return }
    presentation = next
    if next == .hidden {
      terminalView.isRenderingEnabled = false
      if windowActionsEnabled { panel.orderOut(nil) }
    }
  }

  private func layout(region: StatusBarPopupRegion) {
    guard let identity = presentation.identity else { return }
    if terminalView.font != font { terminalView.font = font }
    let colors = StatusPopupColors(style)
    let foreground = colors.foreground
    let background = colors.background
    if terminalView.foreground != foreground { terminalView.foreground = foreground }
    if terminalView.background != background { terminalView.background = background }
    let cell = terminalView.cellSize
    let inset = CGFloat(style.padding + style.borderWidth)
    let maximumColumns = max(1, Int((visibleFrame.width - inset * 2) / max(1, cell.width)))
    let maximumRows = max(1, Int((visibleFrame.height - inset * 2) / max(1, cell.height)))
    let columns: Int
    let rows: Int
    var exitText = ""
    var footerHeight: CGFloat = 0
    var sourceKind = "terminal"
    var documentCache = "none"
    if let session = terminals.sessions[region.name],
      let definition = terminals.definitions[region.name]
    {
      switch session.state {
      case .exited(let code):
        exitText = "Exited (\(code))"
        if terminals.automaticallyRestarts(name: region.name) {
          exitText += " · restarting automatically"
        }
      case .failed(let message): exitText = message
      default: break
      }
      footerHeight =
        exitText.isEmpty
        ? 0 : min(cell.height, max(0, visibleFrame.height - inset * 2 - cell.height))
      columns = min(maximumColumns, definition.columns)
      rows = min(
        max(1, Int((visibleFrame.height - inset * 2 - footerHeight) / cell.height)), definition.rows
      )
      terminalView.bind(session: session)
      session.resize(columns: columns, rows: rows)
    } else {
      sourceKind = "document"
      let segments = region.document ?? FlashStatusBarRenderer.segments(from: region.content)
      let text = segments.filter { !$0.ignore }.map(\.text).joined()
      let available = min(
        maximumColumns,
        max(1, Int((CGFloat(style.maxWidth) - inset * 2) / max(1, cell.width))))
      let grid = Self.documentGrid(
        text: text, availableColumns: available, maximumRows: maximumRows)
      columns = grid.columns
      rows = grid.rows
      let document = documents[region.name] ?? TerminalDocument(columns: columns, rows: rows)
      documents[region.name] = document
      let revision = DocumentRevision(segments: segments, columns: columns, rows: rows)
      documentCache = documentRevisions[region.name] == revision ? "reused" : "replaced"
      if documentRevisions[region.name] != revision {
        document.replace(data: Self.documentVT(segments), columns: columns, rows: rows)
        documentRevisions[region.name] = revision
      }
      if documents.count > 32,
        let stale = documents.keys.sorted().first(where: { $0 != region.name })
      {
        documents.removeValue(forKey: stale)
        documentRevisions.removeValue(forKey: stale)
      }
      terminalView.bind(document: document)
    }
    content = region.content
    let layout = OverlayPanel.statusBarPopupLayout(
      textSize: CGSize(
        width: CGFloat(columns) * cell.width, height: CGFloat(rows) * cell.height + footerHeight),
      padding: CGFloat(style.padding), borderWidth: CGFloat(style.borderWidth))
    let target: CGRect
    if let anchor = identity.anchor {
      target = OverlayPanel.statusBarPopupFrame(
        pointer: anchor,
        popupSize: layout.popupSize, visibleFrame: visibleFrame, offset: CGFloat(style.offset))
    } else {
      target = CGRect(
        x: visibleFrame.midX - layout.popupSize.width / 2,
        y: visibleFrame.midY - layout.popupSize.height / 2,
        width: layout.popupSize.width, height: layout.popupSize.height)
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    container.layer?.backgroundColor = terminalView.background.cgColor
    container.layer?.borderColor = colors.border.cgColor
    container.layer?.borderWidth = CGFloat(style.borderWidth)
    container.layer?.cornerRadius = CGFloat(style.cornerRadius)
    panel.setFrame(target, display: false)
    terminalView.frame = CGRect(
      x: layout.labelFrame.minX, y: layout.labelFrame.minY + footerHeight,
      width: layout.labelFrame.width, height: CGFloat(rows) * cell.height)
    exitLabel.stringValue = exitText
    exitLabel.isHidden = exitText.isEmpty
    exitLabel.font = font
    exitLabel.textColor = foreground
    exitLabel.frame = CGRect(
      x: layout.labelFrame.minX, y: layout.labelFrame.minY,
      width: layout.labelFrame.width, height: footerHeight)
    CATransaction.commit()
    let fields = [
      "source_kind": sourceKind,
      "columns": String(columns),
      "rows": String(rows),
      "content_bytes": String(region.content.utf8.count),
      "document_cache": documentCache,
      "width": String(Double(target.width)),
      "height": String(Double(target.height)),
      "footer_visible": String(!exitText.isEmpty),
    ]
    if lastLayoutName != region.name || lastLayoutFields != fields {
      lastLayoutName = region.name
      lastLayoutFields = fields
      var details = fields.merging(diagnosticState()) { _, state in state }
      details["reason"] = "layout"
      details["popup_id"] = StatusFormatDocument.stableID(region.name)
      FlashLog.debug(
        "Status popup layout changed", fields: details,
        source: "core:StatusPopupController.layout")
    }
  }

  static func documentVT(_ segments: [FlashStatusTextSegment]) -> Data {
    var result = ""
    for segment in segments where !segment.ignore {
      var codes = ["0"]
      if segment.bold { codes.append("1") }
      if segment.dim { codes.append("2") }
      if segment.italics { codes.append("3") }
      if segment.underline {
        let underline: Int
        switch segment.underlineStyle {
        case .single: underline = 1
        case .double: underline = 2
        case .curly: underline = 3
        case .dotted: underline = 4
        case .dashed: underline = 5
        }
        codes.append("4:\(underline)")
      }
      if segment.blink || segment.breathing { codes.append("5") }
      if segment.hidden { codes.append("8") }
      if segment.strikethrough { codes.append("9") }
      if segment.overline { codes.append("53") }
      codes.append(contentsOf: Self.underlineColorCodes(segment.underlineColor))
      if segment.reverse { codes.append("7") }
      codes.append(contentsOf: Self.colorCodes(segment.foreground, foreground: true))
      codes.append(contentsOf: Self.colorCodes(segment.background, foreground: false))
      result += "\u{1B}[" + codes.joined(separator: ";") + "m"
      let hyperlink = segment.link.flatMap { target -> String? in
        guard !target.isEmpty, target.utf8.count <= 8192,
          !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return target
      }
      if let hyperlink { result += "\u{1B}]8;;" + hyperlink + "\u{1B}\\" }
      result += TerminalDocument.sanitize(text: segment.text).replacingOccurrences(
        of: "\n", with: "\r\n")
      if hyperlink != nil { result += "\u{1B}]8;;\u{1B}\\" }
    }
    result += "\u{1B}[0m"
    return Data(result.utf8)
  }

  static func documentGrid(text: String, availableColumns: Int, maximumRows: Int) -> (
    columns: Int, rows: Int
  ) {
    let lines = TerminalDocument.sanitize(text: text).split(
      separator: "\n", omittingEmptySubsequences: false)
    let widths = lines.map { line -> Int in
      var width = 0
      for character in line {
        width +=
          character == "\t" ? 8 - width % 8 : TerminalDocument.cellWidth(of: String(character))
      }
      return width
    }
    let columns = max(1, min(availableColumns, widths.max() ?? 1))
    var rows = 0
    for line in lines {
      rows += 1
      var column = 0
      for character in line {
        let width =
          character == "\t"
          ? min(columns - column, 8 - column % 8)
          : TerminalDocument.cellWidth(of: String(character))
        if width > 0, column >= columns || column + width > columns {
          rows += 1
          column = 0
        }
        column += width
      }
    }
    return (columns, max(1, min(maximumRows, rows)))
  }

  private static func underlineColorCodes(_ color: FlashStatusTextColor) -> [String] {
    switch color {
    case .defaultForeground, .defaultBackground: return ["59"]
    case .palette(let value): return ["58", "5", String(value)]
    case .rgb(let value):
      return ["58", "2", String(value >> 16 & 255), String(value >> 8 & 255), String(value & 255)]
    }
  }

  private static func colorCodes(_ color: FlashStatusTextColor, foreground: Bool) -> [String] {
    let base = foreground ? "38" : "48"
    switch color {
    case .defaultForeground: return [foreground ? "39" : "49"]
    case .defaultBackground: return [foreground ? "39" : "49"]
    case .palette(let index): return [base, "5", String(index)]
    case .rgb(let rgb):
      return [base, "2", String((rgb >> 16) & 255), String((rgb >> 8) & 255), String(rgb & 255)]
    }
  }

}

struct StatusPopupColors {
  let foreground: NSColor
  let background: NSColor
  let border: NSColor

  init(_ style: Config.StatusBar.PopupStyle) {
    foreground = Self.color(style.foreground) ?? .textColor
    background = Self.color(style.background) ?? .windowBackgroundColor
    border = Self.color(style.borderColor) ?? .clear
  }

  private static func color(_ hex: String) -> NSColor? {
    guard hex.hasPrefix("#"), let number = UInt32(hex.dropFirst(), radix: 16) else { return nil }
    let rgba = hex.count == 9 ? number : (number << 8) | 255
    return NSColor(
      srgbRed: CGFloat((rgba >> 24) & 255) / 255,
      green: CGFloat((rgba >> 16) & 255) / 255, blue: CGFloat((rgba >> 8) & 255) / 255,
      alpha: CGFloat(rgba & 255) / 255)
  }
}
