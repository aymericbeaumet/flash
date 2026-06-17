import AppKit
import FlashCore
import QuartzCore

/// Centered text modal surface (`:help`, `:plugins`, `:mappings`,
/// `:clipboard`, plugin-reload toast). The same chrome — backdrop
/// gradient, border, click-outside dismiss monitor, mouse-wheel scroll
/// — applies to every variant. The only thing that differs between
/// variants is whether the content is a static blob (`text`) or a
/// navigable list (`selectableList`); both flow through `renderModal`
/// so visual consistency is enforced structurally.
extension OverlayPanel {
  /// Discriminator passed to `present(_:)` — keeps the two display
  /// entry points (`displayModal`, `displaySelectableModal`) honest:
  /// the caller picks the variant once and the modal infrastructure
  /// handles every other concern identically.
  enum ModalKind {
    case text(String)
    case selectableList(lines: [String])
  }

  /// Modal backdrop gradient: dark Polar-Night-ish stops baked once so
  /// `renderModal` doesn't allocate new CGColors per render. All modal
  /// surfaces share these so a `:plugins` table reads visually
  /// identical to a `:help` topic or the `:clipboard` history.
  static let modalBackgroundColors: [CGColor] = [
    NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.18, alpha: 1).cgColor,
  ]
  static let modalBorderCGColor: CGColor =
    NSColor(calibratedRed: 0.30, green: 0.34, blue: 0.40, alpha: 1).cgColor

  /// Unified entry point. Variant-specific state is set up here so the
  /// pre-existing `displayModal` / `displaySelectableModal` aliases stay
  /// as thin call-site sugar (kept for diff readability).
  ///
  /// Text modals (`:help`, `:mappings`, `:plugins`, plugin toasts) are
  /// always interpreted as **markdown**: `FlashMarkdownRenderer` walks
  /// the cmark-gfm AST and produces a styled `NSAttributedString`.
  /// Source strings that don't use any markdown syntax (e.g. a one-line
  /// toast) still render correctly — the renderer treats them as a
  /// single paragraph. `renderModal` consumes the plain-text projection
  /// only to size the modal chrome; the rendered attributed string is
  /// what the user actually sees.
  func present(_ kind: ModalKind) {
    switch kind {
    case .text(let body):
      modalSelectable = false
      let attributed = FlashMarkdownRenderer.render(body)
      let plain = FlashMarkdownRenderer.plainText(body)
      renderModal(text: plain.isEmpty ? body : plain, attributed: attributed)
    case .selectableList(let lines):
      modalSelectable = true
      selectableModalLines = lines
      selectableModalSelectedIndex = 0
      let rendered = renderSelectableModalText(selectedIndex: 0)
      renderModal(text: rendered.plain, attributed: rendered.attributed)
      scrollSelectableModal(to: rendered.selectedRange)
    }
  }

  func displayModal(_ text: String) {
    present(.text(text))
  }

  /// The dedicated `:clipboard` history list: a navigable modal (marker `>`
  /// on the selection, `j`/`k`/arrows to move) that pastes the chosen entry
  /// on Return. Fed by the clipboard plugin, never the flashlight candidate
  /// pool — `modalSelectable` flips `.modal` key handling into list mode.
  func displaySelectableModal(lines: [String]) {
    present(.selectableList(lines: lines))
  }

  private func renderModal(text: String, attributed: NSAttributedString?) {
    FlashLog.trace("[overlay] display_modal chars=\(text.count) selectable=\(modalSelectable)")
    transientDisplayToken &+= 1

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer {
      CATransaction.commit()
      captureKeyboardInput()
    }

    let frame = ensurePanelFrame()
    recycleAll()
    commandPromptVisible = false
    inputMode = .modal

    let snapshot = OverlayPanel.currentScreenSnapshot()
    let visible = snapshot.mainVisibleFrame
    let scale = snapshot.mainScale
    let fontSize = max(CGFloat(overlayConfig.fontSize), 13)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let longestLine = lines.map(\.count).max() ?? text.count
    let lineHeight = fontSize + 5
    let width = min(
      max(920, CGFloat(longestLine) * fontSize * 0.60 + 56),
      max(360, visible.width - 32))
    let height = min(
      lineHeight * CGFloat(lines.count) + 34,
      max(260, visible.height - 80))
    let localX = visible.midX - frame.minX - width / 2
    let localY = visible.midY - frame.minY - height / 2

    let chip = dequeueHintLayer()
    chip.frame = Self.snap(
      CGRect(x: localX, y: localY, width: width, height: height),
      scale: scale)
    chip.contentsScale = scale
    chip.colors = Self.modalBackgroundColors
    // Reset chip state — the pool can hand back a chip that was
    // hidden / dimmed by `filter(prefix:)` on a previous activation,
    // and we'd inherit `isHidden = true` here, which is why the help
    // modal was rendering with no visible background.
    chip.isHidden = false
    chip.opacity = 1
    chip.cornerRadius = 8
    chip.borderColor = Self.modalBorderCGColor

    chip.sublayers = nil
    hintLayers.append(chip)
    var sublayers: [CALayer] = [chip]
    appendModeBadgeLayerIfNeeded(to: &sublayers, panelFrame: frame)
    contentLayer.sublayers = sublayers
    configureModalTextView(
      text: text,
      attributed: attributed,
      panelLocalFrame: chip.frame.insetBy(dx: 1, dy: 1),
      fontSize: fontSize,
      lineHeight: lineHeight,
      longestLine: longestLine,
      lineCount: lines.count)
    modalScrollView.isHidden = false
    ignoresMouseEvents = false
    installModalDismissMonitors()
    transientContentVisible = true
  }

  func configureModalTextView() {
    modalScrollView.isHidden = true
    modalScrollView.drawsBackground = false
    modalScrollView.borderType = .noBorder
    modalScrollView.hasVerticalScroller = true
    modalScrollView.hasHorizontalScroller = true
    modalScrollView.autohidesScrollers = true
    modalScrollView.scrollerStyle = .overlay
    modalTextView.isEditable = false
    modalTextView.isSelectable = true
    modalTextView.isRichText = false
    modalTextView.importsGraphics = false
    modalTextView.drawsBackground = false
    modalTextView.textColor = Self.nordSnowStorm2
    modalTextView.insertionPointColor = Self.nordSnowStorm2
    modalTextView.allowsUndo = false
    modalTextView.isHorizontallyResizable = true
    modalTextView.isVerticallyResizable = true
    modalTextView.minSize = NSSize(width: 0, height: 0)
    modalTextView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude)
    modalTextView.textContainerInset = NSSize(width: 18, height: 14)
    modalTextView.textContainer?.widthTracksTextView = false
    modalTextView.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude)
    modalScrollView.documentView = modalTextView
  }

  func configureModalTextView(
    text: String,
    attributed: NSAttributedString? = nil,
    panelLocalFrame: CGRect,
    fontSize: CGFloat,
    lineHeight: CGFloat,
    longestLine: Int,
    lineCount: Int
  ) {
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    modalTextView.overlayCoordinator = coordinator
    modalTextView.font = font
    modalTextView.textColor = Self.nordSnowStorm2
    if let attributed {
      modalTextView.textStorage?.setAttributedString(attributed)
    } else {
      modalTextView.string = text
    }
    modalScrollView.frame = panelLocalFrame
    let contentWidth = max(
      panelLocalFrame.width,
      CGFloat(longestLine) * fontSize * 0.62 + modalTextView.textContainerInset.width * 2 + 24)
    let contentHeight = max(
      panelLocalFrame.height,
      lineHeight * CGFloat(lineCount) + modalTextView.textContainerInset.height * 2 + 8)
    modalTextView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
    modalTextView.textContainer?.containerSize = NSSize(
      width: contentWidth,
      height: CGFloat.greatestFiniteMagnitude)
    modalTextView.needsDisplay = true
  }

  /// Move the `:clipboard` selection and re-render in place (no full modal
  /// rebuild, so the dismiss monitors and keyboard capture stay put).
  func moveSelectableModalSelection(_ delta: Int) {
    guard modalSelectable, !selectableModalLines.isEmpty else { return }
    let last = selectableModalLines.count - 1
    let next = max(0, min(last, selectableModalSelectedIndex + delta))
    guard next != selectableModalSelectedIndex else { return }
    selectableModalSelectedIndex = next
    let rendered = renderSelectableModalText(selectedIndex: next)
    modalTextView.textStorage?.setAttributedString(rendered.attributed)
    scrollSelectableModal(to: rendered.selectedRange)
  }

  /// Build the list text for `selectableModalLines`: each row gets a `> ` /
  /// `  ` marker, the selected row is bold with a purple marker. Returns the
  /// plain string (for sizing), the attributed string (for rendering), and
  /// the selected row's range (for scroll-into-view).
  private func renderSelectableModalText(selectedIndex: Int)
    -> (plain: String, attributed: NSAttributedString, selectedRange: NSRange)
  {
    let fontSize = max(CGFloat(overlayConfig.fontSize), 13)
    let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let selectedFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let attributed = NSMutableAttributedString()
    var plainLines: [String] = []
    var selectedRange = NSRange(location: 0, length: 0)
    for (index, line) in selectableModalLines.enumerated() {
      if attributed.length > 0 {
        attributed.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
      }
      let isSelected = index == selectedIndex
      let rowText = (isSelected ? "> " : "  ") + line
      plainLines.append(rowText)
      let rowStart = attributed.length
      let row = NSMutableAttributedString(
        string: rowText,
        attributes: [
          .font: isSelected ? selectedFont : baseFont,
          .foregroundColor: isSelected ? Self.nordSnowStorm2 : Self.nordSnowStorm1,
        ])
      if isSelected {
        row.addAttribute(
          .foregroundColor, value: Self.nordAuroraPurple,
          range: NSRange(location: 0, length: min(1, row.length)))
        selectedRange = NSRange(location: rowStart, length: row.length)
      }
      attributed.append(row)
    }
    return (plainLines.joined(separator: "\n"), attributed, selectedRange)
  }

  private func scrollSelectableModal(to range: NSRange) {
    guard range.length > 0 else { return }
    modalTextView.scrollRangeToVisible(range)
  }

  /// Vim-style scroll inside a (text) modal. The modal is hermetic — keys
  /// never reach the focused app — so `j`/`k`/`ctrl-e`/`ctrl-y` and the
  /// page motions navigate the modal's own content instead of the
  /// underlying terminal. Selectable modals route through
  /// `moveSelectableModalSelection` instead; non-text modals (no scroll
  /// view) are a no-op.
  enum ModalScrollKind {
    case lineUp
    case lineDown
    case halfPageUp
    case halfPageDown
    case top
    case bottom
  }

  func scrollModal(_ kind: ModalScrollKind) {
    guard !modalScrollView.isHidden else { return }
    // Force a layout pass before reading the textView's bounds. Without
    // this, the *first* scroll on a freshly-displayed modal saw a stale
    // `modalTextView.bounds.height` (the explicit frame we set in
    // `configureModalTextView` hadn't yet been replaced by NSTextView's
    // intrinsic content size for the long string), `maxY` came out as
    // 0, and j/k/Ctrl-D silently no-op'd until something else triggered
    // a re-layout. Calling `layoutSubtreeIfNeeded` here is cheap and
    // guarantees that `bounds.height` reflects the actual rendered
    // content.
    modalScrollView.layoutSubtreeIfNeeded()
    modalTextView.layoutManager?.ensureLayout(for: modalTextView.textContainer!)

    let lineHeight = max(modalTextView.font?.boundingRectForFont.height ?? 16, 12)
    let viewportHeight = modalScrollView.contentView.bounds.height
    // Prefer the document-visible bounds when available — that's the
    // size the scroll view actually uses for hit-testing — and only
    // fall back to the explicit frame for the rare path where the
    // layout pass above wasn't enough.
    let docHeight = max(
      modalTextView.bounds.height,
      modalTextView.layoutManager?.usedRect(for: modalTextView.textContainer!).height ?? 0)
    let maxY = max(0, docHeight - viewportHeight)

    var origin = modalScrollView.contentView.bounds.origin
    switch kind {
    case .top:
      origin.y = 0
    case .bottom:
      origin.y = maxY
    case .lineUp, .lineDown, .halfPageUp, .halfPageDown:
      let amount: CGFloat
      switch kind {
      case .lineUp, .lineDown:
        amount = lineHeight
      case .halfPageUp, .halfPageDown:
        amount = max(viewportHeight / 2, lineHeight * 3)
      default:
        amount = 0
      }
      let signed: CGFloat
      switch kind {
      case .lineUp, .halfPageUp:
        signed = -amount
      case .lineDown, .halfPageDown:
        signed = amount
      default:
        signed = 0
      }
      origin.y = min(maxY, max(0, origin.y + signed))
    }
    modalScrollView.contentView.scroll(to: origin)
    modalScrollView.reflectScrolledClipView(modalScrollView.contentView)
  }

  func hideModalTextView() {
    removeModalDismissMonitors()
    modalScrollView.isHidden = true
    modalTextView.string = ""
    modalTextView.overlayCoordinator = nil
    modalSelectable = false
    selectableModalLines = []
    selectableModalSelectedIndex = 0
    ignoresMouseEvents = true
    if firstResponder === modalTextView {
      makeFirstResponder(self)
    }
  }
}
