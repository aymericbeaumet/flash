import AppKit
import FlashCore
import QuartzCore

/// Command-line (`:cmd`) entry. Hosts the NSTextField for native
/// keyboard editing + the `:`-prefixed prompt label that the overlay
/// draws above it. The text field is shown only while the overlay is
/// actively in `.commandLine` input mode.
extension OverlayPanel {
  func displayCommandLine(
    _ text: String,
    suggestions: [CandidateDisplayItem]? = nil,
    emptyText: String = "no matching app",
    cursorIndex: Int? = nil
  ) {
    FlashLog.trace(
      "[overlay] display_command_line text=\(text) cursor=\(cursorIndex ?? text.count) "
        + "suggestions=\(suggestions?.count ?? 0)")
    inputMode = .commandLine
    setCommandTextFieldText(text, cursorIndex: cursorIndex ?? text.count)
    commandPromptVisible = true
    commandPromptPrefix = ""
    if let suggestions {
      setCandidateFinderResults(items: suggestions, emptyText: emptyText)
    } else {
      clearCandidateFinderResults()
    }
    updateModeBadge(text: modeLabels.command, visible: true, captureInput: true, style: .command)
  }

  func configureCommandPrompt(panelFrame: CGRect) {
    guard commandPromptVisible else { return }
    let fontSize = max(CGFloat(overlayConfig.fontSize), 11)
    let labelFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let prompt: String
    if inputMode == .commandLine {
      prompt = commandLineText
    } else {
      let cursor = min(max(commandLineCursorIndex, 0), commandLineText.count)
      let cursorStringIndex = commandLineText.index(commandLineText.startIndex, offsetBy: cursor)
      let commandWithCursor =
        String(commandLineText[..<cursorStringIndex]) + "|"
        + String(commandLineText[cursorStringIndex...])
      prompt = "\(commandPromptPrefix)\(commandWithCursor)"
    }
    let snapshot = OverlayPanel.currentScreenSnapshot()
    let visible = snapshot.mainVisibleFrame
    let scale = snapshot.mainScale
    let gap: CGFloat = 6
    let height = modeBadgeLayer.frame.height
    let localX = modeBadgeLayer.frame.maxX + gap
    let localY = modeBadgeLayer.frame.minY
    let maxWidth = max(120, visible.maxX - panelFrame.minX - localX - 10)
    let measuredCount = max(prompt.count, 14)
    let width = min(max(96, CGFloat(measuredCount) * fontSize * 0.62 + 18), maxWidth)
    commandPromptLayer.frame = Self.snap(
      CGRect(x: localX, y: localY, width: width, height: height),
      scale: scale)
    commandPromptLayer.contentsScale = scale
    let palette = commandPalette()
    commandPromptLayer.colors = [palette.bottomCG, palette.topCG]
    commandPromptLayer.borderColor = palette.borderCG

    let horizontalPadding: CGFloat = 4
    let availableTextWidth = max(10, width - horizontalPadding * 2)
    let textWidth = ceil((prompt as NSString).size(withAttributes: [.font: labelFont]).width)
    let labelWidth = max(availableTextWidth, textWidth + 2)
    let cursor = min(max(commandLineCursorIndex, 0), commandLineText.count)
    let scrollOffset: CGFloat
    if inputMode == .commandLine {
      let cursorStringIndex = commandLineText.index(commandLineText.startIndex, offsetBy: cursor)
      let beforeCursor = String(commandLineText[..<cursorStringIndex])
      let cursorX = ceil(
        (beforeCursor as NSString).size(withAttributes: [.font: labelFont]).width)
      let maxScroll = max(0, textWidth - availableTextWidth)
      scrollOffset = min(max(0, cursorX - availableTextWidth + 8), maxScroll)
      commandCaretLayer.isHidden = true
      configureCommandTextField(
        promptFrame: commandPromptLayer.frame,
        font: labelFont,
        fontSize: fontSize)
    } else {
      scrollOffset = 0
      commandCaretLayer.isHidden = true
      hideCommandTextField()
    }
    commandPromptLabel.frame = CGRect(
      x: horizontalPadding - scrollOffset,
      y: 4,
      width: labelWidth,
      height: fontSize + 2)
    commandPromptLabel.font = labelFont
    commandPromptLabel.fontSize = fontSize
    commandPromptLabel.foregroundColor = Self.nordSnowStorm2CG
    commandPromptLabel.contentsScale = scale
    commandPromptLabel.alignmentMode = .left
    commandPromptLabel.string = prompt
    if inputMode == .commandLine {
      commandPromptLabel.string = ""
    }
  }

  func configureCommandTextField() {
    commandTextField.delegate = self
    commandTextField.isHidden = true
    commandTextField.isBordered = false
    commandTextField.drawsBackground = false
    commandTextField.focusRingType = .none
    commandTextField.isEditable = true
    commandTextField.isSelectable = true
    commandTextField.maximumNumberOfLines = 1
    commandTextField.lineBreakMode = .byClipping
    commandTextField.cell?.usesSingleLineMode = true
    commandTextField.cell?.wraps = false
    commandTextField.cell?.isScrollable = true
    commandTextField.textColor = Self.nordSnowStorm2
    commandTextField.backgroundColor = .clear
  }


  func configureCommandTextField(
    promptFrame: CGRect,
    font: NSFont,
    fontSize: CGFloat
  ) {
    commandTextField.font = font
    commandTextField.textColor = Self.nordSnowStorm2
    commandTextField.frame = CGRect(
      x: promptFrame.minX + 4,
      y: promptFrame.minY + max(0, (promptFrame.height - fontSize - 4) / 2),
      width: max(10, promptFrame.width - 8),
      height: fontSize + 5)
    commandTextField.isHidden = false
  }

  func hideCommandTextField() {
    commandTextField.isHidden = true
    if firstResponder === commandTextField || commandTextField.currentEditor() != nil {
      makeFirstResponder(self)
    }
  }


  func setCommandTextFieldText(_ text: String, cursorIndex: Int) {
    suppressCommandTextFieldChange = true
    commandLineText = text
    commandLineCursorIndex = cursorIndex
    if commandTextField.stringValue != text {
      commandTextField.stringValue = text
    }
    syncCommandTextFieldSelection()
    suppressCommandTextFieldChange = false
  }

  func syncCommandTextFieldSelection() {
    guard let editor = commandTextField.currentEditor() as? NSTextView else { return }
    editor.insertionPointColor = Self.nordSnowStorm2
    editor.selectedRange = NSRange(
      location: utf16Offset(forCharacterOffset: commandLineCursorIndex, in: commandLineText),
      length: 0)
  }

  func commandTextFieldCursorIndex() -> Int {
    guard let editor = commandTextField.currentEditor() as? NSTextView else {
      return commandTextField.stringValue.count
    }
    return characterOffset(forUTF16Offset: editor.selectedRange.location, in: commandTextField.stringValue)
  }

  func utf16Offset(forCharacterOffset offset: Int, in text: String) -> Int {
    let clamped = min(max(offset, 0), text.count)
    let index = text.index(text.startIndex, offsetBy: clamped)
    return index.samePosition(in: text.utf16)?.utf16Offset(in: text) ?? text.utf16.count
  }

  func characterOffset(forUTF16Offset offset: Int, in text: String) -> Int {
    let clamped = min(max(offset, 0), text.utf16.count)
    guard let utf16Index = text.utf16.index(
      text.utf16.startIndex,
      offsetBy: clamped,
      limitedBy: text.utf16.endIndex),
      let index = String.Index(utf16Index, within: text)
    else { return text.count }
    return text.distance(from: text.startIndex, to: index)
  }
}

extension OverlayPanel: NSTextFieldDelegate {
  func controlTextDidBeginEditing(_ obj: Notification) {
    (commandTextField.currentEditor() as? NSTextView)?.insertionPointColor = Self.nordSnowStorm2
  }

  func controlTextDidChange(_ obj: Notification) {
    guard !suppressCommandTextFieldChange else { return }
    commandLineText = commandTextField.stringValue
    commandLineCursorIndex = commandTextFieldCursorIndex()
    FlashLog.trace(
      "[input] command_line edit text=\(commandLineText) cursor=\(commandLineCursorIndex)")
    coordinator?.overlayDidUpdateCommandLine(
      commandLineText,
      cursorIndex: commandLineCursorIndex,
      resetSelection: true)
  }

  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool {
    guard control === commandTextField else { return false }
    switch commandSelector {
    case #selector(NSResponder.insertNewline(_:)):
      let command = commandTextField.stringValue
      commandLineText = ""
      commandLineCursorIndex = 0
      FlashLog.trace("[input] command_line submit command=\(command)")
      coordinator?.overlayDidSubmitCommandLine(command)
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      commandLineText = ""
      commandLineCursorIndex = 0
      FlashLog.trace("[input] command_line cancel reason=cancel_operation")
      coordinator?.overlayDidCancelCommandLine()
      return true
    case #selector(NSResponder.insertTab(_:)):
      _ = coordinator?.overlayDidMoveCommandLineSelection(1)
      return true
    case #selector(NSResponder.insertBacktab(_:)):
      _ = coordinator?.overlayDidMoveCommandLineSelection(-1)
      return true
    case #selector(NSResponder.moveUp(_:)):
      _ = coordinator?.overlayDidMoveCommandLineSelection(1)
      return true
    case #selector(NSResponder.moveDown(_:)):
      _ = coordinator?.overlayDidMoveCommandLineSelection(-1)
      return true
    default:
      return false
    }
  }
}
