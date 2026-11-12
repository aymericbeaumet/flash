import AppKit
import FlashTerminal

private final class StatusPopupPanel: NSPanel {
  var focusLost: (() -> Void)?
  var acceptsKeyboardFocus = false
  override var canBecomeKey: Bool { acceptsKeyboardFocus }
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
final class StatusPopupSurface {
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
  /// The label a preview or pinned popup hangs from, or a standalone popup's
  /// label-less stand-in.
  private var region: StatusBarPopupRegion?
  /// Where this showing hangs from its label (`hangingFrame`), cleared when
  /// it ends.
  private var hang: PopupHang?
  private var visibleFrame = CGRect.zero
  private var style = Config.PopupStyle()
  private var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
  /// A hover preview whose panel waits for its first frame.
  private(set) var isAwaitingFirstFrame = false
  private var firstFrameFallback: DispatchWorkItem?
  /// `resignKey` can re-enter while dismissal orders the panel out.
  private var resigningFocus = false
  var onFocusRequested: (() -> Void)?
  var willFocus: (() -> Void)?
  var willDismissFocus: (() -> Void)?
  var didDismissFocus: ((String) -> Void)?
  /// The popup panel lost key while a pinned or standalone popup was showing.
  /// The owner takes it off the screen; unset, the controller dismisses itself.
  var onFocusLost: (() -> Void)?
  /// Observation only: the registry has already been told the showing ended.
  var didDismiss: ((String) -> Void)?
  /// Observation only: the presentation or one of the registry's sessions
  /// changed.
  var didChange: (() -> Void)?
  var inputInterceptor: ((NSEvent) -> Bool)?

  var frame: CGRect { panel.frame }
  /// `[app] hide_from_capture` for the popup panel.
  var sharingType: NSWindow.SharingType {
    get { panel.sharingType }
    set { panel.sharingType = newValue }
  }
  var exitStatusText: String { exitLabel.stringValue }
  var isVisible: Bool { presentation.name != nil }
  var focusedName: String? { presentation.isFocused ? presentation.name : nil }

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
      guard let self, self.presentation.isFocused, !self.resigningFocus else { return }
      self.resigningFocus = true
      defer { self.resigningFocus = false }
      if let onFocusLost = self.onFocusLost {
        onFocusLost()
      } else {
        self.dismiss(reason: "focus_lost")
      }
    }
    terminalView.onFocusRequested = { [weak self] in self?.onFocusRequested?() }
    terminalView.onFrameReceived = { [weak self] in self?.showAwaitedPreview() }
    terminalView.inputInterceptor = { [weak self] event in self?.inputInterceptor?(event) ?? false }
  }

  func registryWillChange(_ changes: [StatusTerminalChange]) {
    guard let name = presentation.name else { return }
    if changes.contains(.remove(name)) {
      dismiss(reason: "terminal_removed")
    } else if changes.contains(.replace(name)), presentation.isFocused {
      willDismissFocus?()
    }
  }

  func registryDidChange() {
    guard let region, isVisible else { return }
    layout(region: region)
  }

  /// Show `region`'s popup hanging from that label; `visibleFrame` is the
  /// visible frame of the display whose bar draws it.
  func preview(
    _ region: StatusBarPopupRegion,
    visibleFrame: CGRect, style: Config.PopupStyle, font: NSFont,
    preservingContent: Bool = false
  ) {
    // A pinned popup keeps the label and screen it was pinned on (`refresh`
    // moves it with that label), and a standalone one has no label.
    guard !presentation.isFocused else { return }
    guard !isContentSnapshot || preservingContent else { return }
    if let previous = presentation.name, previous != region.name,
      terminals.isPager(previous)
    {
      dismiss(reason: "popup_changed")
    }
    isContentSnapshot = preservingContent
    self.region = region
    self.visibleFrame = visibleFrame
    self.style = style
    self.font = font
    transition(.anchor(name: region.name))
    layout(region: region)
    // A terminal popup whose session is gone dismissed itself in layout.
    guard isVisible else { return }
    terminalView.isRenderingEnabled = true
    presentPreview()
    logLifecycle(reason: "preview")
  }

  /// Order the preview's panel front once it has a frame to show, or after
  /// `firstFrameWait` at the latest.
  private func presentPreview() {
    guard terminalView.terminalFrame == nil else {
      endFirstFrameWait()
      if windowActionsEnabled { panel.orderFrontRegardless() }
      return
    }
    guard !isAwaitingFirstFrame else { return }
    isAwaitingFirstFrame = true
    let fallback = DispatchWorkItem { [weak self] in self?.showAwaitedPreview() }
    firstFrameFallback = fallback
    DispatchQueue.main.asyncAfter(
      deadline: .now() + StatusPopupController.firstFrameWait, execute: fallback)
  }

  private func showAwaitedPreview() {
    guard isAwaitingFirstFrame else { return }
    endFirstFrameWait()
    if isVisible, windowActionsEnabled { panel.orderFrontRegardless() }
  }

  private func endFirstFrameWait() {
    isAwaitingFirstFrame = false
    firstFrameFallback?.cancel()
    firstFrameFallback = nil
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
    if isVisible && presentation.name != name { dismiss(reason: "terminal_replaced") }
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

  /// `visibleFrameContaining` is the visible frame of the display that now
  /// holds the anchor. A monitor resize moves that display; keeping the frame
  /// from when the popup opened clamps it to a screen that no longer matches
  /// the label.
  func refresh(
    _ regions: [StatusBarPopupRegion],
    visibleFrameContaining: (CGRect) -> CGRect? = { _ in nil }
  ) {
    guard !presentation.isStandalone else { return }
    guard let name = presentation.name, let current = region else { return }
    guard let updated = StatusPopupController.span(matching: current, in: regions) else {
      if isContentSnapshot { return }
      dismiss(reason: "region_removed")
      return
    }
    let previousVisible = visibleFrame
    if let frame = visibleFrameContaining(updated.anchor) {
      visibleFrame = frame
    }
    if terminals.isPager(name), presentation.isFocused || isContentSnapshot {
      let segments = updated.document ?? FlashStatusBarRenderer.segments(from: updated.content)
      terminals.stagePopup(name: name, data: StatusPopupController.documentVT(segments))
      guard !isContentSnapshot else { return }
      // A focused pager keeps its document but still hangs from its label.
      var moved = current
      moved.rect = updated.rect
      moved.textBounds = updated.textBounds
      guard moved != current || visibleFrame != previousVisible else { return }
      region = moved
      layout(region: moved)
      return
    }
    if isContentSnapshot { return }
    region = updated
    layout(region: updated)
  }

  /// A standalone text popup keeps the document it opened with; the latest
  /// collected one waits for an explicit restart, as in a focused pager.
  func stageStandalone(_ documents: [String: [FlashStatusTextSegment]]) {
    guard presentation.isStandalone, let name = presentation.name,
      terminals.isPager(name), let document = documents[name]
    else { return }
    terminals.stagePopup(name: name, data: StatusPopupController.documentVT(document))
  }

  /// A showing opens centred on its label. While the label only changes
  /// width, one edge staying put (a carousel line, a metric growing), the
  /// popup stays where it is rather than sliding sideways under a reader, as
  /// long as the label's centre is still over it. A label that moved (the
  /// bar re-laid out) or a changed screen hangs it from the label afresh.
  private func hangingFrame(region: StatusBarPopupRegion, size: CGSize) -> CGRect {
    let anchor = region.anchor
    let offset = CGFloat(style.offset)
    if let hang, hang.name == region.name, hang.visibleFrame == visibleFrame,
      abs(anchor.minX - hang.anchor.minX) < 0.5 || abs(anchor.maxX - hang.anchor.maxX) < 0.5
    {
      let kept = OverlayPanel.statusBarPopupFrame(
        span: CGRect(x: hang.x, y: anchor.minY, width: 0, height: anchor.height),
        popupSize: size, visibleFrame: visibleFrame, offset: offset)
      if kept.minX <= anchor.midX, anchor.midX <= kept.maxX {
        self.hang?.anchor = anchor
        return kept
      }
    }
    hang = PopupHang(name: region.name, visibleFrame: visibleFrame, x: anchor.midX, anchor: anchor)
    return OverlayPanel.statusBarPopupFrame(
      span: anchor, popupSize: size, visibleFrame: visibleFrame, offset: offset)
  }

  private struct PopupHang {
    var name: String
    var visibleFrame: CGRect
    /// The x the popup is centred on, before clamping to the screen.
    var x: CGFloat
    /// The label as last laid out, to tell a resize from a move.
    var anchor: CGRect
  }

  func updateStyle(_ style: Config.PopupStyle) {
    self.style = style
    if isVisible, let region { layout(region: region) }
  }

  func leaveAnchor() {
    guard presentation.applying(.leaveAnchor) != presentation else { return }
    dismiss(reason: "anchor_left")
  }

  func dismiss(reason: String = "dismiss", endsFocus: Bool = true) {
    let previousName = presentation.name
    let wasFocused = presentation.isFocused
    if wasFocused { willDismissFocus?() }
    transition(.dismiss)
    endFirstFrameWait()
    terminalView.isRenderingEnabled = false
    terminalView.bind(session: nil)
    if windowActionsEnabled { panel.orderOut(nil) }
    logLifecycle(reason: reason)
    region = nil
    hang = nil
    isContentSnapshot = false
    if wasFocused && endsFocus { didDismissFocus?(reason) }
    guard let previousName else { return }
    terminals.hide(previousName)
    didDismiss?(previousName)
  }

  func focus() {
    guard isVisible, !presentation.isFocused, let name = presentation.name else { return }
    transition(.focus)
    if let region { layout(region: region) }
    terminals.freezePopup(name: name) { [weak self] in
      guard let self, self.presentation.isFocused, self.presentation.name == name else {
        return
      }
      self.willFocus?()
      self.activateTerminalInput()
      self.logLifecycle(reason: "focus")
    }
  }

  private func activateTerminalInput() {
    endFirstFrameWait()
    guard windowActionsEnabled else { return }
    StatusPopupController.activateFlash()
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
    let name = presentation.name
    guard lastLifecycleName != name || lastLifecycleFields != fields else { return }
    let popupName = name ?? lastLifecycleName
    lastLifecycleName = name
    lastLifecycleFields = fields
    var details = fields
    details["reason"] = reason
    details["popup_id"] = popupName.map(StatusFormatDocument.stableID) ?? "none"
    details["content_bytes"] = String(content.utf8.count)
    FlashLog.debug(
      "[popup] presentation_changed", fields: details,
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
    panel.acceptsKeyboardFocus = next.isFocused
    terminalView.drawsCursor = next.isFocused || next.isStandalone
    if next == .hidden {
      terminalView.isRenderingEnabled = false
      if windowActionsEnabled { panel.orderOut(nil) }
    }
    didChange?()
  }

  private func layout(region: StatusBarPopupRegion) {
    guard isVisible else { return }
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
    var clippedRows = 0
    var exitText = ""
    var footerHeight: CGFloat = 0
    var sourceKind = "terminal"
    if let definition = terminals.definitions[region.name] {
      guard let session = terminals.session(named: region.name) else {
        dismiss(reason: "terminal_missing")
        return
      }
      exitText = StatusPopupController.exitFooter(session.state, lifecycle: definition.lifecycle)
      footerHeight =
        exitText.isEmpty
        ? 0 : min(cell.height, max(0, visibleFrame.height - inset * 2 - cell.height))
      let grid = definition.size.grid(
        visible: visibleFrame.size, cell: cell, inset: inset, reservedHeight: footerHeight)
      columns = grid.columns
      rows = grid.rows
      // Bound first, so the rows judged are the screen the showing draws.
      terminalView.bind(session: session)
      var ended = terminals.hasEnded(region.name)
      if case .failed(let failure) = session.state, failure.isPermanent { ended = true }
      if ended { terminalView.drawsCursor = false }
      clippedRows = StatusPopupController.clippedTrailingRows(
        StatusPopupController.rowTexts(of: terminalView.terminalFrame), rows: rows,
        interactive: presentation.isFocused || presentation.isStandalone, ended: ended)
      session.setColors(foreground: foreground, background: background)
      session.resize(columns: columns, rows: rows)
    } else {
      sourceKind = "pager"
      let segments = region.document ?? FlashStatusBarRenderer.segments(from: region.content)
      let text = segments.filter { !$0.ignore }.map(\.text).joined()
      let available = min(
        maximumColumns,
        max(1, Int((CGFloat(style.maxWidth) - inset * 2) / max(1, cell.width))))
      // As wide as the widest line, from `min_width` (room for less's
      // prompt, and for wider data after Command-R) up to `max_width` and the
      // screen, where longer lines wrap.
      let grid = StatusPopupController.documentGrid(
        text: text, availableColumns: available, maximumRows: max(1, maximumRows - 1))
      columns = min(
        available,
        max(grid.columns, Int((CGFloat(style.minWidth) - inset * 2) / max(1, cell.width))))
      rows = min(maximumRows, grid.rows + 1)
      clippedRows =
        StatusPopupController.hidesPagerPromptRow(
          rows: rows, interactive: presentation.isFocused || presentation.isStandalone) ? 1 : 0
      let session: TerminalSession
      if let existing = terminals.session(named: region.name),
        presentation.isFocused || isContentSnapshot
      {
        session = existing
      } else {
        session = terminals.preparePager(
          name: region.name, data: StatusPopupController.documentVT(segments), columns: columns,
          rows: rows)
      }
      terminalView.bind(session: session)
      session.setColors(foreground: foreground, background: background)
      session.resize(columns: columns, rows: rows)
    }
    content = region.content
    // The session keeps every row; only the drawn height shrinks, so the
    // clipped prompt row never reaches the screen.
    let visibleRows = rows - clippedRows
    let layout = OverlayPanel.statusBarPopupLayout(
      textSize: CGSize(
        width: CGFloat(columns) * cell.width,
        height: CGFloat(visibleRows) * cell.height + footerHeight),
      padding: CGFloat(style.padding), borderWidth: CGFloat(style.borderWidth))
    let target: CGRect
    if presentation.isStandalone {
      target = CGRect(
        x: visibleFrame.midX - layout.popupSize.width / 2,
        y: visibleFrame.midY - layout.popupSize.height / 2,
        width: layout.popupSize.width, height: layout.popupSize.height)
    } else {
      target = hangingFrame(region: region, size: layout.popupSize)
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
        "[popup] layout_changed", fields: details,
        source: "core:StatusPopupController.layout")
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
