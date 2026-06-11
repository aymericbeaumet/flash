import AppKit
import FlashCore
import QuartzCore

/// Candidate finder results panel: the list of `:open` /
/// `:flashlight` matches that appears above the command-line prompt.
/// Renders as a single multi-line `CATextLayer` so highlighting comes
/// for free via `NSAttributedString`.
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
    candidateFinderResultsAttributedText = nil
  }

  func setCandidateFinderResults(items: [CandidateDisplayItem], emptyText: String) {
    let shownItems = Array(items.prefix(Self.candidateFinderMaxRows))
    if shownItems.isEmpty {
      candidateFinderResultsMeasurementText = emptyText
      candidateFinderResultsAttributedText = NSAttributedString(
        string: emptyText,
        attributes: [
          .font: NSFont.monospacedSystemFont(
            ofSize: max(CGFloat(overlayConfig.fontSize), 11),
            weight: .medium),
          .foregroundColor: Self.nordSnowStorm0,
        ])
      candidateFinderResultsVisible = true
      return
    }

    // Text draws top-to-bottom, so reverse the visible window: rank 1
    // appears on the bottom row, closest to the command line.
    let visualItems = Array(shownItems.reversed())
    let fontSize = max(CGFloat(overlayConfig.fontSize), 11)
    let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let selectedFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let highlightFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let baseColor = Self.nordSnowStorm1
    let selectedColor = Self.nordSnowStorm2
    let highlightColor = Self.nordAuroraYellow
    let markerColor = Self.nordAuroraPurple
    let attributed = NSMutableAttributedString()
    var plainLines: [String] = []

    for item in visualItems {
      if attributed.length > 0 {
        attributed.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
      }
      let marker = item.isSelected ? "> " : "  "
      let line = marker + item.title
      plainLines.append(line)
      let lineAttributed = NSMutableAttributedString(
        string: line,
        attributes: [
          .font: item.isSelected ? selectedFont : baseFont,
          .foregroundColor: item.isSelected ? selectedColor : baseColor,
        ])
      if item.isSelected {
        lineAttributed.addAttribute(
          .foregroundColor,
          value: markerColor,
          range: NSRange(location: 0, length: min(1, lineAttributed.length)))
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
        lineAttributed.addAttributes(
          [.foregroundColor: highlightColor, .font: highlightFont],
          range: nsRange)
      }
      attributed.append(lineAttributed)
    }

    candidateFinderResultsMeasurementText = plainLines.joined(separator: "\n")
    candidateFinderResultsAttributedText = attributed
    candidateFinderResultsVisible = true
  }

  func configureCandidateFinderResults(panelFrame: CGRect) {
    guard candidateFinderResultsVisible else { return }
    let fontSize = max(CGFloat(overlayConfig.fontSize), 11)
    let labelFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let snapshot = OverlayPanel.currentScreenSnapshot()
    let visible = snapshot.mainVisibleFrame
    let scale = snapshot.mainScale
    let lines = candidateFinderResultsMeasurementText.split(
      separator: "\n",
      omittingEmptySubsequences: false)
    let longest = lines.map(\.count).max() ?? candidateFinderResultsMeasurementText.count
    let x = commandPromptLayer.frame.minX
    let maxWidth = max(180, visible.maxX - panelFrame.minX - x - 10)
    let width = min(
      max(
        220,
        CGFloat(longest) * fontSize * 0.62 + Self.candidateFinderHorizontalPadding * 2 + 4),
      maxWidth)
    let attributedText =
      candidateFinderResultsAttributedText
      ?? NSAttributedString(
        string: candidateFinderResultsMeasurementText,
        attributes: [.font: labelFont])
    let labelWidth = max(1, width - Self.candidateFinderHorizontalPadding * 2)
    let labelHeight = Self.candidateFinderTextHeight(attributedText, fallbackFont: labelFont)
    let height = labelHeight + Self.candidateFinderVerticalPadding * 2
    let y = commandPromptLayer.frame.maxY + 6

    candidateFinderResultsLayer.frame = Self.snap(
      CGRect(x: x, y: y, width: width, height: height),
      scale: scale)
    candidateFinderResultsLayer.contentsScale = scale
    let palette = commandPalette()
    candidateFinderResultsLayer.colors = [palette.bottomCG, palette.topCG]
    candidateFinderResultsLayer.borderColor = palette.borderCG

    candidateFinderResultsLabel.frame = CGRect(
      x: Self.candidateFinderHorizontalPadding,
      y: Self.candidateFinderVerticalPadding,
      width: labelWidth,
      height: labelHeight)
    candidateFinderResultsLabel.font = labelFont
    candidateFinderResultsLabel.fontSize = fontSize
    candidateFinderResultsLabel.foregroundColor = Self.nordSnowStorm1CG
    candidateFinderResultsLabel.contentsScale = scale
    candidateFinderResultsLabel.alignmentMode = .left
    candidateFinderResultsLabel.isWrapped = false
    candidateFinderResultsLabel.string = attributedText
  }

  static func candidateFinderTextHeight(
    _ text: NSAttributedString,
    fallbackFont: NSFont
  ) -> CGFloat {
    let fontLineHeight = ceil(fallbackFont.ascender - fallbackFont.descender + fallbackFont.leading)
    guard text.length > 0 else { return fontLineHeight }
    let measured = text.boundingRect(
      with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading])
    return ceil(max(fontLineHeight, measured.height))
  }
}
