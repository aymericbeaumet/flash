import AppKit
import QuartzCore

/// What the window switcher draws: one row per window, resolved from its
/// state on main. No thumbnails: Flash reads no pixels (hard constraint 5),
/// so a row is the app's icon, its name, the window's title and a badge.
struct WindowSwitcherDisplay {
  struct Row {
    /// Uppercase, as hint chips draw labels.
    let label: String
    let app: String
    let title: String
    let badge: String?
    let icon: CGImage?
  }

  let rows: [Row]
  let selection: Int
  /// The label prefix typed so far, uppercase.
  let typed: String
  /// A point on the display to draw on: the focused window's centre, else
  /// the pointer.
  let anchor: CGPoint?
  /// The which-key palette lists keys to type, with no row to choose.
  var highlightsSelection = true
}

/// Where the switcher's box and rows go: pure geometry, so the layout is
/// tested without drawing.
struct WindowSwitcherLayout: Equatable {
  static let padding: CGFloat = 10
  static let gap: CGFloat = 8
  static let iconSize: CGFloat = 20
  static let minimumWidth: CGFloat = 320
  /// Share of the display the box may cover.
  static let maximumWidthFraction: CGFloat = 0.6
  static let maximumHeightFraction: CGFloat = 0.7
  /// The app column never takes more than this, so long names truncate
  /// before titles do.
  static let maximumAppColumn: CGFloat = 200

  let box: CGRect
  let rowHeight: CGFloat
  /// The rows shown, following the selection when they do not all fit.
  let visible: Range<Int>
  let chipWidth: CGFloat
  let appColumn: CGFloat
  let titleColumn: CGFloat
  let badgeColumn: CGFloat
  let rowsPerColumn: Int
  let columnWidth: CGFloat
  let hiddenRowCount: Int

  /// `screen` is the display's visible frame; widths are the widest label
  /// chip, app name, title and badge of the rows.
  static func make(
    screen: CGRect, rowCount: Int, selection: Int, rowHeight: CGFloat, chipWidth: CGFloat,
    appWidth: CGFloat, titleWidth: CGFloat, badgeWidth: CGFloat, showsAllRows: Bool = false,
    minimumChipWidth: CGFloat = 0
  ) -> WindowSwitcherLayout {
    if showsAllRows {
      return palette(
        screen: screen, rowCount: rowCount, rowHeight: rowHeight,
        chipWidth: chipWidth, titleWidth: titleWidth, minimumChipWidth: minimumChipWidth)
    }
    let visible = visibleRows(
      screenHeight: screen.height, rowCount: rowCount, selection: selection,
      rowHeight: rowHeight)
    let appColumn = min(ceil(appWidth), maximumAppColumn)
    let badgeColumn = ceil(badgeWidth)
    let fixed =
      padding * 2 + chipWidth + gap + iconSize + gap + appColumn + gap
      + (badgeColumn > 0 ? gap + badgeColumn : 0)
    let width = min(
      max(fixed + ceil(titleWidth), minimumWidth),
      max(minimumWidth, screen.width * maximumWidthFraction))
    let height = padding * 2 + CGFloat(visible.count) * rowHeight
    let box = CGRect(
      x: (screen.midX - width / 2).rounded(), y: (screen.midY - height / 2).rounded(),
      width: width, height: height)
    return WindowSwitcherLayout(
      box: box, rowHeight: rowHeight, visible: visible, chipWidth: chipWidth,
      appColumn: appColumn, titleColumn: max(0, width - fixed), badgeColumn: badgeColumn,
      rowsPerColumn: max(1, visible.count), columnWidth: width, hiddenRowCount: 0)
  }

  /// A key palette has no selection to scroll with. Fit columns on screen;
  /// an unusually large configured table gets an explicit overflow footer.
  private static func palette(
    screen: CGRect, rowCount: Int, rowHeight: CGFloat, chipWidth: CGFloat, titleWidth: CGFloat,
    minimumChipWidth: CGFloat
  ) -> WindowSwitcherLayout {
    let maximumWidth = max(1, screen.width * 0.9)
    let maximumRows = max(1, Int((screen.height * maximumHeightFraction - padding * 2) / rowHeight))
    let minimumColumnWidth = max(100, padding * 2 + minimumChipWidth + gap + 32)
    let maximumColumns = max(1, Int(maximumWidth / minimumColumnWidth))
    let overflows = rowCount > maximumRows * maximumColumns
    let rowsPerColumn = max(1, maximumRows - (overflows ? 1 : 0))
    let visibleCount = min(rowCount, rowsPerColumn * maximumColumns)
    let columns = max(1, (visibleCount + rowsPerColumn - 1) / rowsPerColumn)
    let columnWidth = min(
      max(padding * 2 + chipWidth + gap + ceil(titleWidth), minimumWidth),
      maximumWidth / CGFloat(columns))
    let chip = max(
      minimumChipWidth, min(chipWidth, max(1, columnWidth - padding * 2 - gap) * 0.45))
    let width = columnWidth * CGFloat(columns)
    let height =
      padding * 2 + CGFloat(min(visibleCount, rowsPerColumn) + (overflows ? 1 : 0)) * rowHeight
    return WindowSwitcherLayout(
      box: CGRect(
        x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height),
      rowHeight: rowHeight, visible: 0..<visibleCount, chipWidth: chip, appColumn: 0,
      titleColumn: max(0, columnWidth - padding * 2 - chip - gap), badgeColumn: 0,
      rowsPerColumn: rowsPerColumn, columnWidth: columnWidth,
      hiddenRowCount: rowCount - visibleCount)
  }

  /// The rows that fit in the box's share of the display, following the
  /// selection. Only these are measured and drawn.
  static func visibleRows(
    screenHeight: CGFloat, rowCount: Int, selection: Int, rowHeight: CGFloat
  ) -> Range<Int> {
    let maximumRows = max(
      1, Int(((screenHeight * maximumHeightFraction) - padding * 2) / rowHeight))
    return CandidateFinder.displayWindow(
      count: rowCount, selectedIndex: selection, windowSize: maximumRows)
  }

  /// Row `index` of the visible slice, in the box's own coordinates (Y up,
  /// the first row on top).
  func rowFrame(_ index: Int) -> CGRect {
    let offset = index - visible.lowerBound
    let column = offset / rowsPerColumn
    let position = CGFloat(offset % rowsPerColumn)
    return CGRect(
      x: CGFloat(column) * columnWidth + Self.padding / 2,
      y: box.height - Self.padding - (position + 1) * rowHeight,
      width: columnWidth - Self.padding,
      height: rowHeight)
  }
}

extension OverlayPanel {
  /// Draw the switcher, centred on the display holding `display.anchor`,
  /// in the overlay panel like hint chips: the tap keeps routing keys and
  /// the focused app stays active until a window is chosen.
  func displayWindowSwitcher(_ display: WindowSwitcherDisplay) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer {
      CATransaction.commit()
      captureKeyboardInput()
    }
    let snapshot = OverlayPanel.currentScreenSnapshot()
    let panelFrame = snapshot.unionFrame
    applyPanelFrame(panelFrame)
    recycleAll()
    hideSelectionMarker()
    transientContentVisible = true
    commandPromptVisible = false

    var sublayers: [CALayer] = []
    syncStatusBarForTransientRender(appendingPromptLayersTo: &sublayers, panelFrame: panelFrame)
    let screen =
      display.anchor.flatMap { point in snapshot.screens.first { $0.frame.contains(point) } }
      ?? snapshot.screens.first { $0.frame == snapshot.mainFrame } ?? snapshot.screens.first
    if let screen, !display.rows.isEmpty {
      sublayers.append(
        windowSwitcherBox(
          display, screen: screen.visibleFrame, scale: screen.scale, panelFrame: panelFrame))
    }
    appendToastLayerIfNeeded(to: &sublayers)
    contentLayer.sublayers = sublayers
  }

  private func windowSwitcherBox(
    _ display: WindowSwitcherDisplay, screen: CGRect, scale: CGFloat, panelFrame: CGRect
  ) -> CALayer {
    let colors = hintColors
    let chipTop = nsColor(fromHex: colors.bgTop) ?? .systemYellow
    let chipBottom = nsColor(fromHex: colors.bgBottom) ?? chipTop
    let chipText = nsColor(fromHex: colors.fg) ?? .black
    let chipBorder = nsColor(fromHex: colors.border)?.cgColor ?? Self.fallbackBorderCGColor
    let chipFontSize = CGFloat(overlayConfig.fontSize)
    let chipFont = NSFont.monospacedSystemFont(ofSize: chipFontSize, weight: .bold)
    let textSize = max(13, chipFontSize + 2)
    let appFont = NSFont.systemFont(ofSize: textSize, weight: .semibold)
    let titleFont = NSFont.systemFont(ofSize: textSize)
    let badgeFont = NSFont.systemFont(ofSize: textSize - 2)
    let chipHeight = Self.chipHeight(forFontSize: chipFontSize)
    let lineHeight = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
    let rowHeight = max(chipHeight, WindowSwitcherLayout.iconSize, lineHeight) + 8

    func width(_ text: String, _ font: NSFont) -> CGFloat {
      text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    // Measured over the rows that fit, not every window: a redraw per key
    // stays a frame however many windows are open.
    let shown = display.rows[
      display.highlightsSelection
        ? WindowSwitcherLayout.visibleRows(
          screenHeight: screen.height, rowCount: display.rows.count,
          selection: display.selection, rowHeight: rowHeight)
        : 0..<display.rows.count]
    let longestLabel = display.rows.map(\.label.count).max() ?? 1
    let minimumChipWidth =
      shown.map {
        let next = String($0.label.dropFirst(display.typed.count))
        return width(next + (display.typed.isEmpty ? "" : "…"), chipFont) + 6
      }.max() ?? 0
    let layout = WindowSwitcherLayout.make(
      screen: CGRect(
        x: screen.minX - panelFrame.minX, y: screen.minY - panelFrame.minY,
        width: screen.width, height: screen.height),
      rowCount: display.rows.count, selection: display.selection, rowHeight: rowHeight,
      chipWidth: Self.chipWidth(forLabelLength: longestLabel, fontSize: chipFontSize),
      appWidth: shown.map { width($0.app, appFont) }.max() ?? 0,
      titleWidth: shown.map { width($0.title, titleFont) }.max() ?? 0,
      badgeWidth: shown.compactMap { $0.badge.map { width($0, badgeFont) } }.max() ?? 0,
      showsAllRows: !display.highlightsSelection, minimumChipWidth: minimumChipWidth)

    let box = CALayer()
    box.actions = Self.noActions
    box.frame = layout.box
    box.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
    box.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
    box.borderWidth = 1
    box.cornerRadius = 10
    box.masksToBounds = true

    var layers: [CALayer] = []
    for index in layout.visible {
      let row = display.rows[index]
      let frame = layout.rowFrame(index)
      let matches = row.label.hasPrefix(display.typed)
      if display.highlightsSelection, index == display.selection {
        let highlight = CALayer()
        highlight.actions = Self.noActions
        highlight.frame = frame
        highlight.backgroundColor = chipTop.withAlphaComponent(0.28).cgColor
        highlight.borderColor = chipTop.withAlphaComponent(0.7).cgColor
        highlight.borderWidth = 1
        highlight.cornerRadius = 5
        layers.append(highlight)
      }
      var x = frame.minX + WindowSwitcherLayout.padding / 2
      let chip = makeChipLayer()
      chip.frame = Self.snap(
        CGRect(
          x: x, y: frame.midY - chipHeight / 2, width: layout.chipWidth, height: chipHeight),
        scale: scale)
      chip.colors = [chipBottom.cgColor, chipTop.cgColor]
      chip.borderColor = chipBorder
      chip.contentsScale = scale
      chip.opacity = matches ? 1 : 0.35
      let label = makeLabelLayer()
      label.font = chipFont
      label.truncationMode = .start
      label.fontSize = chipFontSize
      label.string = Self.windowSwitcherLabel(
        row.label, typed: matches ? (display.typed as NSString).length : 0, font: chipFont,
        color: chipText)
      label.contentsScale = scale
      label.frame = CGRect(
        x: 0, y: (chipHeight - chipFontSize - 2) / 2, width: layout.chipWidth,
        height: chipFontSize + 2)
      chip.addSublayer(label)
      layers.append(chip)
      x += layout.chipWidth + WindowSwitcherLayout.gap

      if let icon = row.icon {
        let image = CALayer()
        image.actions = Self.noActions
        image.contents = icon
        image.contentsGravity = .resizeAspect
        image.frame = CGRect(
          x: x, y: frame.midY - WindowSwitcherLayout.iconSize / 2,
          width: WindowSwitcherLayout.iconSize, height: WindowSwitcherLayout.iconSize)
        image.opacity = matches ? 1 : 0.35
        layers.append(image)
      }
      if display.highlightsSelection {
        x += WindowSwitcherLayout.iconSize + WindowSwitcherLayout.gap
      }

      let text = { (string: String, font: NSFont, color: NSColor, x: CGFloat, width: CGFloat) in
        let layer = CATextLayer()
        layer.actions = Self.noActions
        layer.string = string
        layer.font = font
        layer.fontSize = font.pointSize
        layer.foregroundColor = color.cgColor
        layer.alignmentMode = .left
        layer.truncationMode = .end
        layer.contentsScale = scale
        layer.opacity = matches ? 1 : 0.35
        layer.frame = CGRect(
          x: x, y: (frame.midY - lineHeight / 2).rounded(), width: width, height: lineHeight)
        layers.append(layer)
      }
      if display.highlightsSelection {
        text(row.app, appFont, .white, x, layout.appColumn)
        x += layout.appColumn + WindowSwitcherLayout.gap
      }
      text(row.title, titleFont, NSColor.white.withAlphaComponent(0.85), x, layout.titleColumn)
      if let badge = row.badge {
        x += layout.titleColumn + WindowSwitcherLayout.gap
        text(badge, badgeFont, NSColor.white.withAlphaComponent(0.55), x, layout.badgeColumn)
      }
    }
    if layout.hiddenRowCount > 0 {
      let overflow = CATextLayer()
      overflow.actions = Self.noActions
      overflow.string = "\(layout.hiddenRowCount) more — see :mappings"
      overflow.font = titleFont
      overflow.fontSize = textSize
      overflow.foregroundColor = NSColor.white.cgColor
      overflow.alignmentMode = .center
      overflow.truncationMode = .end
      overflow.contentsScale = scale
      overflow.frame = CGRect(
        x: WindowSwitcherLayout.padding, y: WindowSwitcherLayout.padding,
        width: layout.box.width - WindowSwitcherLayout.padding * 2, height: rowHeight)
      layers.append(overflow)
    }
    box.sublayers = layers
    return box
  }

  /// A chip label with its typed prefix faded, as hint chips draw it.
  private static func windowSwitcherLabel(
    _ label: String, typed: Int, font: NSFont, color: NSColor
  ) -> NSAttributedString {
    let string = NSMutableAttributedString(
      string: label,
      attributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: centeredParagraphStyle,
      ])
    let faded = min(typed, (label as NSString).length)
    if faded > 0 {
      string.addAttribute(
        .foregroundColor, value: color.withAlphaComponent(0.3),
        range: NSRange(location: 0, length: faded))
    }
    return string
  }
}
