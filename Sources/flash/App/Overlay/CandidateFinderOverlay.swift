import AppKit
import FlashCore
import QuartzCore

/// Candidate finder results panel: the list of `:open` /
/// `:flashlight` matches that appears below the centered command-line prompt.
/// Renders one `CATextLayer` per visible row. A single multi-line layer was
/// cheaper for plain text but expensive for emoji searches because CoreText
/// had to resolve fallback fonts across the whole list on every keystroke.
extension OverlayPanel {
  func displayCandidateFinder(query: String, items: [CandidateDisplayItem]) {
    FlashLog.trace("[overlay] display_candidate_finder query=\(query) items=\(items.count)")
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer {
      CATransaction.commit()
      captureKeyboardInput()
    }

    candidateFinderQuery = query
    inputMode = .candidateFinder
    hideCommandTextField()
    commandLineText = query
    commandLineCursorIndex = query.count
    // No source-locked prefix: flashlight searches every candidate
    // source uniformly, so labelling the prompt with one ("Applications>")
    // misrepresents what's actually being filtered.
    commandPromptPrefix = ""
    commandPromptVisible = true
    setCandidateFinderResults(items: items, emptyText: "no matching app")
    updateModeBadge(text: modeLabels.command, visible: true, captureInput: true, style: .command)
  }

  func clearCandidateFinderResults() {
    candidateFinderResultsVisible = false
    candidateFinderResultsMeasurementText = ""
    candidateFinderResultsItems = []
    candidateFinderResultsShowsEmptyMessage = false
    for layer in candidateFinderResultRowLayers {
      layer.isHidden = true
      layer.string = nil
    }
  }

  func setCandidateFinderResults(items: [CandidateDisplayItem], emptyText: String) {
    let shownItems = items
    if shownItems.isEmpty {
      candidateFinderResultsItems = [
        CandidateDisplayItem(title: emptyText, highlightedRanges: [], isSelected: false)
      ]
      candidateFinderResultsShowsEmptyMessage = true
      candidateFinderResultsMeasurementText = emptyText
      candidateFinderResultsVisible = true
      return
    }

    // Text draws top-to-bottom; the highest-ranked row should appear
    // first, closest to the prompt.
    let visualItems = shownItems
    var plainLines: [String] = []

    for item in visualItems {
      let marker = item.isSelected ? "> " : "  "
      let line = marker + item.title
      plainLines.append(line)
    }

    candidateFinderResultsItems = visualItems
    candidateFinderResultsShowsEmptyMessage = false
    candidateFinderResultsMeasurementText = plainLines.joined(separator: "\n")
    candidateFinderResultsVisible = true
  }

  func configureCandidateFinderResults(panelFrame: CGRect) {
    guard candidateFinderResultsVisible else { return }
    let fontSize = Self.candidateFinderFontSize(overlayFontSize: CGFloat(overlayConfig.fontSize))
    let labelFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let snapshot = OverlayPanel.currentScreenSnapshot()
    let visible = snapshot.mainVisibleFrame
    let scale = snapshot.mainScale
    let rowItems = candidateFinderResultsItems
    let rowCount = max(1, rowItems.count)
    let measurementLines = candidateFinderResultsMeasurementText.split(
      separator: "\n",
      omittingEmptySubsequences: false)
    let longest = measurementLines.map(\.count).max() ?? candidateFinderResultsMeasurementText.count
    let x = commandPromptLayer.frame.minX
    let maxWidth = max(180, visible.maxX - panelFrame.minX - x - 10)
    let width = Self.candidateFinderResultsWidth(
      commandPromptWidth: commandPromptLayer.frame.width,
      longestLineCharacterCount: longest,
      fontSize: fontSize,
      maximumWidth: maxWidth)
    let labelWidth = max(1, width - Self.candidateFinderHorizontalPadding * 2)
    // Compute height from the exact visible row count. The row layers below
    // fill this height directly, so there is no trailing multi-line text
    // fragment slack after the final candidate.
    let rowHeight = Self.candidateFinderResultRowHeight(font: labelFont)
    let labelHeight = Self.candidateFinderResultsHeight(
      lineCount: rowCount,
      font: labelFont,
      lineSpacing: Self.candidateFinderLineSpacing)
    let height = labelHeight + Self.candidateFinderVerticalPadding * 2
    let minimumY = visible.minY - panelFrame.minY + 10
    let y = Self.candidateFinderResultsY(
      commandPromptFrame: commandPromptLayer.frame,
      height: height,
      minimumY: minimumY)

    candidateFinderResultsLayer.frame = Self.snap(
      CGRect(x: x, y: y, width: width, height: height),
      scale: scale)
    candidateFinderResultsLayer.contentsScale = scale
    let palette = commandInputPalette()
    candidateFinderResultsLayer.colors = [palette.bottomCG, palette.topCG]
    candidateFinderResultsLayer.borderColor = palette.borderCG

    ensureCandidateFinderResultRowLayerCount(rowCount)
    candidateFinderResultsLayer.sublayers = Array(candidateFinderResultRowLayers.prefix(rowCount))
    for (index, layer) in candidateFinderResultRowLayers.enumerated() {
      guard index < rowCount else {
        layer.isHidden = true
        layer.string = nil
        continue
      }
      let item = rowItems[index]
      let marker: String
      if candidateFinderResultsShowsEmptyMessage {
        marker = ""
      } else {
        marker = item.isSelected ? "> " : "  "
      }
      let topIndex = rowCount - 1 - index
      layer.frame = CGRect(
        x: Self.candidateFinderHorizontalPadding,
        y: Self.candidateFinderVerticalPadding
          + CGFloat(topIndex) * (rowHeight + Self.candidateFinderLineSpacing),
        width: labelWidth,
        height: rowHeight)
      layer.font = labelFont
      layer.fontSize = fontSize
      layer.foregroundColor = Self.nordSnowStorm1CG
      layer.contentsScale = scale
      layer.alignmentMode = .left
      layer.isWrapped = false
      layer.isHidden = false
      layer.string = Self.candidateFinderResultAttributedLine(
        item: item,
        marker: marker,
        fontSize: fontSize,
        emptyMessage: candidateFinderResultsShowsEmptyMessage)
    }
  }

  private func ensureCandidateFinderResultRowLayerCount(_ count: Int) {
    while candidateFinderResultRowLayers.count < count {
      let layer = CATextLayer()
      layer.alignmentMode = .left
      layer.isWrapped = false
      layer.truncationMode = .end
      layer.actions = OverlayPanel.noActions
      candidateFinderResultRowLayers.append(layer)
    }
  }

  /// Exact-fit height for `lineCount` rows of `font`, with `lineSpacing`
  /// gaps between them (no trailing gap). Replaces the previous
  /// `boundingRect`-based measurement which left an empty band below the
  /// last candidate row.
  static func candidateFinderResultsHeight(
    lineCount: Int,
    font: NSFont,
    lineSpacing: CGFloat
  ) -> CGFloat {
    let fontLineHeight = candidateFinderResultRowHeight(font: font)
    guard lineCount > 0 else { return fontLineHeight }
    let gaps = CGFloat(max(0, lineCount - 1)) * lineSpacing
    return CGFloat(lineCount) * fontLineHeight + gaps
  }

  static func candidateFinderResultRowHeight(font: NSFont) -> CGFloat {
    var height = ceil(font.ascender - font.descender + font.leading)
    if let emojiFont = CandidateEmojiSupport.emojiFont(forCandidateFontSize: font.pointSize) {
      height = max(height, ceil(emojiFont.ascender - emojiFont.descender + emojiFont.leading))
    }
    return height
  }

  static func candidateFinderFontSize(overlayFontSize: CGFloat) -> CGFloat {
    max(overlayFontSize + 1, 12)
  }

  static func candidateFinderResultAttributedLine(
    item: CandidateDisplayItem,
    marker: String,
    fontSize: CGFloat,
    emptyMessage: Bool = false
  ) -> NSAttributedString {
    let line = marker + item.title
    let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let selectedFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let highlightFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let baseColor = emptyMessage ? Self.nordSnowStorm0 : Self.nordSnowStorm1
    let selectedColor = Self.nordSnowStorm2
    let highlightColor = Self.nordAuroraYellow
    let markerColor = Self.nordAuroraPurple
    let attributed = NSMutableAttributedString(
      string: line,
      attributes: [
        .font: item.isSelected ? selectedFont : baseFont,
        .foregroundColor: item.isSelected ? selectedColor : baseColor,
      ])
    if item.isSelected, !marker.isEmpty {
      attributed.addAttribute(
        .foregroundColor,
        value: markerColor,
        range: NSRange(location: 0, length: min(1, attributed.length)))
    }
    for range in item.highlightedRanges {
      guard range.lowerBound >= 0, range.upperBound <= item.title.count else { continue }
      let titleStart = line.index(line.startIndex, offsetBy: marker.count)
      guard
        let lower = line.index(
          titleStart,
          offsetBy: range.lowerBound,
          limitedBy: line.endIndex),
        let upper = line.index(
          titleStart,
          offsetBy: range.upperBound,
          limitedBy: line.endIndex)
      else { continue }
      let nsRange = NSRange(lower..<upper, in: line)
      attributed.addAttributes(
        [.foregroundColor: highlightColor, .font: highlightFont],
        range: nsRange)
    }
    CandidateEmojiSupport.applyEmojiFont(to: attributed, line: line, fontSize: fontSize)
    return attributed
  }

  static func candidateFinderResultsWidth(
    commandPromptWidth: CGFloat,
    longestLineCharacterCount _: Int,
    fontSize _: CGFloat,
    maximumWidth _: CGFloat
  ) -> CGFloat {
    // Exactly the prompt's width: the two boxes share a left edge, so
    // matching the width makes their borders line up as one stacked
    // surface. The prompt is already clamped to the visible region, so its
    // width never bleeds off-screen. A single long candidate title still
    // doesn't widen the panel — the result rows truncate at their own edge.
    commandPromptWidth
  }

  static func candidateFinderResultsY(
    commandPromptFrame: CGRect,
    height: CGFloat,
    minimumY: CGFloat
  ) -> CGFloat {
    max(minimumY, commandPromptFrame.minY - 6 - height)
  }
}
