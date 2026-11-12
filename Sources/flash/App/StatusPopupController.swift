import AppKit
import FlashTerminal

/// Owns the keyboard presentation and the independent hover presentation.
/// Promotion moves the existing surface, so a session is never bound twice.
final class StatusPopupController {
  let terminals: StatusTerminalRegistry
  private var focused: StatusPopupSurface
  private var hover: StatusPopupSurface
  private var primary: StatusPopupSurface { focused.isVisible ? focused : hover }

  /// Avoid flashing an empty panel while a hover pager prepares its first frame.
  static let firstFrameWait: TimeInterval = 0.15
  var willFocus: (() -> Void)?
  var willDismissFocus: (() -> Void)?
  var didDismissFocus: ((String) -> Void)?
  var onFocusLost: (() -> Void)?
  var didDismiss: ((String) -> Void)?
  var didChange: (() -> Void)?
  var inputInterceptor: ((NSEvent) -> Bool)?
  var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) } {
    didSet {
      focused.terminalView.openURL = openURL
      hover.terminalView.openURL = openURL
    }
  }

  var presentation: StatusPopupPresentation { primary.presentation }
  var previewName: String? { hover.presentation.ephemeralName }
  var previewFrame: CGRect? { hover.isVisible ? hover.frame : nil }
  var anchoredName: String? {
    hover.presentation.name ?? (focused.presentation.isStandalone ? nil : focused.presentation.name)
  }
  var anchoredContent: String { hover.isVisible ? hover.content : focused.content }
  var visibleNames: Set<String> {
    Set([focused.presentation.name, hover.presentation.name].compactMap { $0 })
  }
  var focusedName: String? { focused.focusedName }
  var content: String { primary.content }
  var frame: CGRect { primary.frame }
  var terminalView: TerminalView { primary.terminalView }
  var exitStatusText: String { primary.exitStatusText }
  var isVisible: Bool { focused.isVisible || hover.isVisible }
  var isContentSnapshot: Bool { hover.isContentSnapshot }
  var isAwaitingFirstFrame: Bool { hover.isAwaitingFirstFrame }
  var sharingType: NSWindow.SharingType {
    get { focused.sharingType }
    set {
      focused.sharingType = newValue
      hover.sharingType = newValue
    }
  }

  init(terminals: StatusTerminalRegistry, windowActionsEnabled: Bool = true) {
    self.terminals = terminals
    focused = StatusPopupSurface(terminals: terminals, windowActionsEnabled: windowActionsEnabled)
    hover = StatusPopupSurface(terminals: terminals, windowActionsEnabled: windowActionsEnabled)
    for surface in [focused, hover] {
      surface.onFocusRequested = { [weak self, weak surface] in
        guard let self, let surface, surface === self.hover else { return }
        self.focus()
      }
      surface.willFocus = { [weak self] in self?.willFocus?() }
      surface.willDismissFocus = { [weak self] in self?.willDismissFocus?() }
      surface.didDismissFocus = { [weak self] reason in self?.didDismissFocus?(reason) }
      surface.onFocusLost = { [weak self] in
        guard let self else { return }
        if let onFocusLost = self.onFocusLost {
          onFocusLost()
        } else {
          self.dismiss(reason: "focus_lost")
        }
      }
      surface.didDismiss = { [weak self] name in self?.didDismiss?(name) }
      surface.didChange = { [weak self] in self?.didChange?() }
      surface.inputInterceptor = { [weak self] event in self?.inputInterceptor?(event) ?? false }
    }
    terminals.willChange = { [weak self] changes in
      guard let self else { return }
      self.hover.registryWillChange(changes)
      self.focused.registryWillChange(changes)
    }
    terminals.didChange = { [weak self] in
      guard let self else { return }
      self.focused.registryDidChange()
      self.hover.registryDidChange()
      self.didChange?()
    }
  }

  func preview(
    _ region: StatusBarPopupRegion, visibleFrame: CGRect, style: Config.PopupStyle, font: NSFont,
    preservingContent: Bool = false
  ) {
    guard region.name != focusedName else {
      dismissPreview(reason: "focused_anchor")
      return
    }
    guard !hover.isContentSnapshot || preservingContent else { return }
    if let name = hover.presentation.name, name != region.name {
      dismissPreview(reason: "anchor_changed")
    }
    hover.preview(
      region, visibleFrame: visibleFrame, style: style, font: font,
      preservingContent: preservingContent)
  }

  func show(
    name: String, document: [FlashStatusTextSegment]? = nil,
    visibleFrame: CGRect, style: Config.PopupStyle, font: NSFont
  ) {
    if terminals.definitions[name] != nil {
      guard terminals.session(named: name) != nil else { return }
    } else {
      guard document != nil else { return }
    }
    if hover.presentation.name == name {
      focused.dismiss(reason: "terminal_replaced", endsFocus: false)
      swap(&focused, &hover)
    } else {
      dismissPreview(reason: "terminal_opened")
      if focused.presentation.name != name {
        focused.dismiss(reason: "terminal_replaced", endsFocus: false)
      }
    }
    focused.show(
      name: name, document: document, visibleFrame: visibleFrame, style: style, font: font)
  }

  func focus() {
    guard hover.isVisible else { return }
    focused.dismiss(reason: "focus_transferred", endsFocus: false)
    swap(&focused, &hover)
    focused.focus()
  }

  func dismissPreview(reason: String = "dismiss") { hover.dismiss(reason: reason) }
  func leaveAnchor() { hover.leaveAnchor() }
  func dismiss(reason: String = "dismiss") {
    dismissPreview(reason: reason)
    focused.dismiss(reason: reason)
  }
  func containsSnapshotAnchor(_ point: CGPoint) -> Bool { hover.containsSnapshotAnchor(point) }
  func repositionStandalone(visibleFrame: CGRect) {
    focused.repositionStandalone(visibleFrame: visibleFrame)
  }
  func stageStandalone(_ documents: [String: [FlashStatusTextSegment]]) {
    focused.stageStandalone(documents)
  }
  func updateStyle(_ style: Config.PopupStyle) {
    focused.updateStyle(style)
    hover.updateStyle(style)
  }
  func refresh(
    _ regions: [StatusBarPopupRegion], visibleFrameContaining: (CGRect) -> CGRect? = { _ in nil }
  ) {
    focused.refresh(regions, visibleFrameContaining: visibleFrameContaining)
    hover.refresh(regions, visibleFrameContaining: visibleFrameContaining)
  }
}

extension StatusPopupController {
  /// Make Flash the active app while a popup has the keyboard. Activation
  /// is cooperative since macOS 14: a plain activation request from Flash is
  /// declined while another app is frontmost, and the popup then had the
  /// keyboard while that app stayed active, so bringing it forward again
  /// changed nothing Flash could see and the popup stayed up. Activating
  /// from the frontmost app hands the activation over, so any app coming
  /// forward afterwards (the covered one included) is an app switch the
  /// popup closes on.
  static func activateFlash() {
    if let front = NSWorkspace.shared.frontmostApplication, front != .current {
      AppActivation.activate(from: front)
    } else {
      AppActivation.activate()
    }
  }

  /// The refreshed span a shown popup hangs from: the same-named span nearest
  /// the one it hung from. A bar that re-laid out (a value got wider) moves
  /// the popup with its label, and the same label elsewhere on the bar or on
  /// another display never captures it. Ties keep the earlier span.
  static func span(
    matching current: StatusBarPopupRegion, in regions: [StatusBarPopupRegion]
  ) -> StatusBarPopupRegion? {
    func distance(_ region: StatusBarPopupRegion) -> CGFloat {
      hypot(region.rect.midX - current.rect.midX, region.rect.midY - current.rect.midY)
    }
    return regions.filter { $0.name == current.name }.min { distance($0) < distance($1) }
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
  /// Rows left undrawn under a terminal popup's screen, one always staying.
  /// A hover preview clips the blank last row a full-screen program keeps for
  /// its messages. A process that has ended can no longer draw into its blank
  /// trailing rows, so a finished report or a command that could not start
  /// loses all of them. A focused live popup keeps every row.
  static func clippedTrailingRows(
    _ rowTexts: [String]?, rows: Int, interactive: Bool, ended: Bool
  ) -> Int {
    guard rows > 1, let rowTexts, !rowTexts.isEmpty else { return 0 }
    let blank = rowTexts.reversed().prefix { $0.trimmingCharacters(in: .whitespaces).isEmpty }
      .count
    let clippable = min(blank, rows - 1)
    if ended { return clippable }
    return interactive ? 0 : min(clippable, 1)
  }

  /// The drawn text of each row of a frame, or nil before the first frame.
  static func rowTexts(of frame: TerminalFrame?) -> [String]? {
    guard let frame, frame.rows > 0, frame.columns > 0,
      frame.cells.count >= frame.rows * frame.columns
    else { return nil }
    return (0..<frame.rows).map { row in
      frame.cells[(row * frame.columns)..<((row + 1) * frame.columns)].map(\.text).joined()
    }
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
    case .label:
      return underlineColorCodes(.rgb(0xEBCB8B))
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
    case .label:
      return colorCodes(.rgb(0xEBCB8B), foreground: foreground)
    }
  }

}
