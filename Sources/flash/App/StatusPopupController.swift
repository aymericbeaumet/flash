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
    animationBehavior = .none
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

/// Owns only presentation: which popup shows, where, and in which state. The
/// registry owns every session and keeps parsing PTYs after this panel hides;
/// each showing tells it once, on dismissal, that the showing ended.
final class StatusPopupController {
  let terminals: StatusTerminalRegistry
  private(set) var presentation: StatusPopupPresentation = .hidden
  private(set) var content: String = ""
  private(set) var isContentSnapshot = false
  private let panel = StatusPopupPanel()
  private let windowActionsEnabled: Bool
  private let container = NSView(frame: .zero)
  let terminalView = TerminalView(frame: .zero)
  private var lastLifecycleName: String?
  private var lastLifecycleFields: [String: String] = [:]
  private var lastLayoutName: String?
  private var lastLayoutFields: [String: String] = [:]
  private let exitLabel = NSTextField(labelWithString: "")
  private var region: StatusBarPopupRegion?
  private var visibleFrame = CGRect.zero
  private var style = Config.PopupStyle()
  private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
  var willFocus: (() -> Void)?
  var willDismissFocus: (() -> Void)?
  var didDismissFocus: ((String) -> Void)?
  /// Observation only: the registry has already been told the showing ended.
  var didDismiss: ((String) -> Void)?
  var inputInterceptor: ((NSEvent) -> Bool)?

  var frame: CGRect { panel.frame }
  /// `[overlay] screen_capture` for the popup panel.
  var sharingType: NSWindow.SharingType {
    get { panel.sharingType }
    set { panel.sharingType = newValue }
  }
  var exitStatusText: String { exitLabel.stringValue }
  var isVisible: Bool { presentation.identity != nil }
  var focusedName: String? { presentation.isFocused ? presentation.identity?.name : nil }

  func containsSnapshotAnchor(_ point: CGPoint) -> Bool {
    isContentSnapshot && region?.rect.contains(point) == true
  }

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
    visibleFrame: CGRect, style: Config.PopupStyle, font: NSFont,
    preservingContent: Bool = false
  ) {
    guard !presentation.isStandalone else { return }
    guard !isContentSnapshot || preservingContent else { return }
    if presentation.isFocused {
      if presentation.identity?.name == region.name {
        if terminals.isPager(region.name) { return }
        self.region = region
        self.style = style
        self.font = font
        self.visibleFrame = visibleFrame
        layout(region: region)
        return
      }
      return
    }
    if let previous = presentation.identity?.name, previous != region.name,
      terminals.isPager(previous)
    {
      dismiss(reason: "popup_changed")
    }
    isContentSnapshot = preservingContent
    self.region = region
    self.visibleFrame = visibleFrame
    self.style = style
    self.font = font
    transition(.anchor(name: region.name, point: pointer))
    layout(region: region)
    // A terminal popup whose session is gone dismissed itself in layout.
    guard isVisible else { return }
    terminalView.isRenderingEnabled = true
    if windowActionsEnabled { panel.orderFrontRegardless() }
    logLifecycle(reason: "preview")
  }

  /// Show `name` standalone, centred on `visibleFrame` and focused. A
  /// terminal popup needs its registry session; a text popup brings the
  /// document it opens with and keeps it until an explicit restart.
  func show(
    name: String, document: [FlashStatusTextSegment]? = nil, visibleFrame: CGRect,
    style: Config.PopupStyle, font: NSFont
  ) {
    let isTerminal = terminals.definitions[name] != nil
    guard isTerminal ? terminals.session(named: name) != nil : document != nil else { return }
    let alreadyFocused = presentation == .standalone(name: name)
    if isVisible && !alreadyFocused { dismiss(reason: "terminal_replaced") }
    let standaloneRegion =
      alreadyFocused
      ? region ?? StatusBarPopupRegion(rect: .zero, name: name, content: "")
      : StatusBarPopupRegion(
        rect: .zero, name: name,
        content: document.map { $0.filter { !$0.ignore }.map(\.text).joined() } ?? "",
        document: document)
    region = standaloneRegion
    self.visibleFrame = visibleFrame
    self.style = style
    self.font = font
    transition(.standalone(name: name))
    layout(region: standaloneRegion)
    guard isVisible else { return }
    terminalView.isRenderingEnabled = true
    if !alreadyFocused { willFocus?() }
    activateTerminalInput()
    logLifecycle(reason: "terminal_opened")
  }

  /// A standalone popup follows its screen's visible frame: recentred, and a
  /// size given in percentages resizes its PTY.
  func repositionStandalone(visibleFrame: CGRect) {
    guard presentation.isStandalone, let region else { return }
    self.visibleFrame = visibleFrame
    layout(region: region)
  }

  func refresh(_ regions: [StatusBarPopupRegion]) {
    guard !presentation.isStandalone else { return }
    guard let name = presentation.identity?.name else { return }
    guard let updated = regions.first(where: { $0.name == name }) else {
      if isContentSnapshot { return }
      dismiss(reason: "region_removed")
      return
    }
    if terminals.isPager(name), presentation.isFocused || isContentSnapshot {
      let segments = updated.document ?? FlashStatusBarRenderer.segments(from: updated.content)
      terminals.stagePopup(name: name, data: Self.documentVT(segments))
      return
    }
    if isContentSnapshot { return }
    region = updated
    layout(region: updated)
  }

  /// A standalone text popup keeps the document it opened with; the latest
  /// collected one waits for an explicit restart, as in a focused pager.
  func stageStandalone(_ documents: [String: [FlashStatusTextSegment]]) {
    guard presentation.isStandalone, let name = presentation.identity?.name,
      terminals.isPager(name), let document = documents[name]
    else { return }
    terminals.stagePopup(name: name, data: Self.documentVT(document))
  }

  func updateStyle(_ style: Config.PopupStyle) {
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
    isContentSnapshot = false
    if wasFocused { didDismissFocus?(reason) }
    guard let previousName else { return }
    terminals.hide(previousName)
    didDismiss?(previousName)
  }

  func focus() {
    guard isVisible, !presentation.isFocused, let name = presentation.identity?.name else { return }
    transition(.focus)
    terminals.freezePopup(name: name) { [weak self] in
      guard let self, self.presentation.isFocused, self.presentation.identity?.name == name else {
        return
      }
      self.willFocus?()
      self.activateTerminalInput()
      self.logLifecycle(reason: "focus")
    }
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
        : presentation.isStandalone ? "standalone" : presentation.isFocused ? "focused" : "preview",
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
    terminalView.drawsCursor = next.isFocused || next.isStandalone
    if next == .hidden {
      terminalView.isRenderingEnabled = false
      if windowActionsEnabled { panel.orderOut(nil) }
    }
  }

  private func layout(region: StatusBarPopupRegion) {
    guard let identity = presentation.identity else { return }
    terminalView.drawsCursor = presentation.isFocused || presentation.isStandalone
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
    /// `less` owns the last row for its prompt. A hover preview is a rendered
    /// document, so that row is a blank strip under the text; clip it instead
    /// of showing it. A focused pager keeps it — that is where `/` search
    /// input and less's own messages appear.
    var clipsTrailingRow = false
    var exitText = ""
    var footerHeight: CGFloat = 0
    var sourceKind = "terminal"
    if let definition = terminals.definitions[region.name] {
      guard let session = terminals.session(named: region.name) else {
        dismiss(reason: "terminal_missing")
        return
      }
      exitText = Self.exitFooter(session.state, lifecycle: definition.lifecycle)
      footerHeight =
        exitText.isEmpty
        ? 0 : min(cell.height, max(0, visibleFrame.height - inset * 2 - cell.height))
      let grid = definition.size.grid(
        visible: visibleFrame.size, cell: cell, inset: inset, reservedHeight: footerHeight)
      columns = grid.columns
      rows = grid.rows
      clipsTrailingRow = Self.hidesBlankTerminalRow(
        lastRow: Self.lastRowText(of: session.frame), rows: rows,
        interactive: presentation.isFocused || presentation.isStandalone)
      terminalView.bind(session: session)
      session.setColors(foreground: foreground, background: background)
      session.resize(columns: columns, rows: rows)
    } else {
      sourceKind = "pager"
      let segments = region.document ?? FlashStatusBarRenderer.segments(from: region.content)
      let text = segments.filter { !$0.ignore }.map(\.text).joined()
      let available = min(
        maximumColumns,
        max(1, Int((CGFloat(style.maxWidth) - inset * 2) / max(1, cell.width))))
      let grid = Self.documentGrid(
        text: text, availableColumns: available, maximumRows: max(1, maximumRows - 1))
      columns = available
      rows = min(maximumRows, grid.rows + 1)
      clipsTrailingRow = Self.hidesPagerPromptRow(
        rows: rows, interactive: presentation.isFocused || presentation.isStandalone)
      let session: TerminalSession
      if let existing = terminals.session(named: region.name),
        presentation.isFocused || isContentSnapshot
      {
        session = existing
      } else {
        session = terminals.preparePager(
          name: region.name, data: Self.documentVT(segments), columns: columns, rows: rows)
      }
      terminalView.bind(session: session)
      session.setColors(foreground: foreground, background: background)
      session.resize(columns: columns, rows: rows)
    }
    content = region.content
    // The session keeps every row; only the drawn height shrinks, so the
    // clipped prompt row never reaches the screen.
    let visibleRows = rows - (clipsTrailingRow ? 1 : 0)
    let layout = OverlayPanel.statusBarPopupLayout(
      textSize: CGSize(
        width: CGFloat(columns) * cell.width,
        height: CGFloat(visibleRows) * cell.height + footerHeight),
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
      width: layout.labelFrame.width, height: CGFloat(visibleRows) * cell.height)
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
      result += TerminalText.sanitize(text: segment.text).replacingOccurrences(
        of: "\n", with: "\r\n")
      if hyperlink != nil { result += "\u{1B}]8;;\u{1B}\\" }
    }
    result += "\u{1B}[0m"
    return Data(result.utf8)
  }

  /// The footer under a terminal whose process is gone: a persistent one
  /// restarts, and a fresh one keeps its last screen, footed only when its
  /// status says it failed.
  static func exitFooter(
    _ state: TerminalSessionState, lifecycle: Config.PopupLifecycle
  ) -> String {
    switch state {
    case .exited(let code) where lifecycle == .persistent:
      return "Exited (\(code)) · restarting automatically"
    case .exited(let code): return code == 0 ? "" : "Exited (\(code))"
    case .failed(.commandNotFound(let command)):
      return "\(command): command not found · install it, then Command-R"
    case .failed(let failure) where failure.isPermanent:
      return "\(failure.description) · Command-R retries"
    case .failed(let failure): return failure.description
    case .idle, .running, .stopped: return ""
    }
  }

  /// A key press on a fresh popup whose process has ended closes it: nothing
  /// is left to read it. Releases and modifier changes do nothing, and
  /// Command-C and Command-V keep their local copy and paste.
  static func closesEndedPopup(_ event: NSEvent) -> Bool {
    guard event.type == .keyDown else { return false }
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else {
      return true
    }
    let key = event.charactersIgnoringModifiers?.lowercased()
    return key != "c" && key != "v"
  }

  /// `less` keeps the last row for its prompt. A preview is a rendered
  /// document, so that row is a blank strip below the text and gets clipped;
  /// an interactive pager keeps it, because that is where `/` search input
  /// and less's own messages land. A one-row popup keeps it either way —
  /// there is nothing left to show otherwise.
  static func hidesPagerPromptRow(rows: Int, interactive: Bool) -> Bool {
    rows > 1 && !interactive
  }

  /// The same rule for a configured terminal: a full-screen program keeps its
  /// last row for messages and prompts, and leaves it blank the rest of the
  /// time (newsboat's message line, for instance). A hover preview clips that
  /// blank strip; a focused or pinned popup keeps it, because that is where an
  /// interactive program reports errors and takes `/` input. Only a row that
  /// is actually empty is clipped, so a program using every row is untouched.
  static func hidesBlankTerminalRow(lastRow: String?, rows: Int, interactive: Bool) -> Bool {
    guard !interactive, rows > 1, let lastRow else { return false }
    return lastRow.trimmingCharacters(in: .whitespaces).isEmpty
  }

  /// The drawn text of a frame's last row, or nil before the first frame.
  static func lastRowText(of frame: TerminalFrame?) -> String? {
    guard let frame, frame.rows > 0, frame.columns > 0 else { return nil }
    let start = (frame.rows - 1) * frame.columns
    guard start >= 0, start + frame.columns <= frame.cells.count else { return nil }
    return frame.cells[start..<(start + frame.columns)].map(\.text).joined()
  }

  static func documentGrid(text: String, availableColumns: Int, maximumRows: Int) -> (
    columns: Int, rows: Int
  ) {
    // Printable ASCII and newlines: one cell per byte, no sanitizing, and a
    // line wraps every `columns` cells. Calendars and plugin details are
    // almost always this.
    if text.utf8.allSatisfy({ $0 == 0x0A || (0x20..<0x7F).contains($0) }) {
      var widths: [Int] = []
      var width = 0
      for byte in text.utf8 {
        if byte == 0x0A {
          widths.append(width)
          width = 0
        } else {
          width += 1
        }
      }
      widths.append(width)
      let columns = max(1, min(availableColumns, widths.max() ?? 1))
      let rows = widths.reduce(0) { $0 + 1 + max(0, $1 - 1) / columns }
      return (columns, max(1, min(maximumRows, rows)))
    }
    return measuredDocumentGrid(
      text: text, availableColumns: availableColumns, maximumRows: maximumRows)
  }

  /// Every character measured through the terminal's width tables.
  static func measuredDocumentGrid(text: String, availableColumns: Int, maximumRows: Int) -> (
    columns: Int, rows: Int
  ) {
    let lines = TerminalText.sanitize(text: text).split(
      separator: "\n", omittingEmptySubsequences: false)
    let widths = lines.map { line -> Int in
      var width = 0
      for character in line {
        width +=
          character == "\t" ? 8 - width % 8 : TerminalText.cellWidth(of: String(character))
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
          : TerminalText.cellWidth(of: String(character))
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

  init(_ style: Config.PopupStyle) {
    background = Self.color(style.background) ?? .windowBackgroundColor
    border = Self.color(style.borderColor) ?? .clear
    // Terminal text is opaque: a translucent foreground is mixed over the
    // background it is drawn on.
    let foreground = Self.color(style.foreground) ?? .textColor
    let opaqueBackground = background.withAlphaComponent(1)
    self.foreground =
      foreground.alphaComponent < 1
      ? opaqueBackground.blended(
        withFraction: foreground.alphaComponent, of: foreground.withAlphaComponent(1))
        ?? foreground
      : foreground
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
