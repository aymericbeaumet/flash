import AppKit
import FlashCore
import QuartzCore

/// Command-line (`:cmd`) entry. Hosts the NSTextField for native
/// keyboard editing + the `:`-prefixed prompt label that the overlay
/// draws above it. The text field is shown only while the overlay is
/// actively in `.commandLine` input mode.
extension OverlayPanel {
  static let goldenRatioFraction: CGFloat = 0.618_033_988_749_894_8
  static let commandPromptWidthFraction: CGFloat = 1 - goldenRatioFraction
  static let commandPromptTopOffsetFraction: CGFloat = 1 - goldenRatioFraction

  func displayCommandLine(
    _ text: String,
    suggestions: [CandidateDisplayItem]? = nil,
    emptyText: String = "no matching app",
    cursorIndex: Int? = nil,
    underlineRange: NSRange? = nil
  ) {
    FlashLog.trace(
      "[overlay] display_command_line text=\(text) cursor=\(cursorIndex ?? text.count) "
        + "suggestions=\(suggestions?.count ?? 0) "
        + "underline=\(underlineRange.map(NSStringFromRange) ?? "nil")")
    inputMode = .commandLine
    setCommandTextFieldText(
      text, cursorIndex: cursorIndex ?? text.count, underlineRange: underlineRange)
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
    let fontSize = Self.commandPromptFontSize(
      statusBarFontSize: Self.statusBarFontSize(
        overlayFontSize: CGFloat(overlayConfig.fontSize)))
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
    let screenFrame = snapshot.mainFrame ?? visible
    let statusFrame = Self.statusBarFrame(
      screenFrame: screenFrame,
      visibleFrame: visible,
      panelFrame: panelFrame,
      fontSize: Self.statusBarFontSize(overlayFontSize: CGFloat(overlayConfig.fontSize)))
    let scale = snapshot.mainScale
    let frame = Self.commandPromptFrame(
      visibleFrame: visible,
      screenFrame: screenFrame,
      statusBarFrame: statusFrame,
      panelFrame: panelFrame,
      prompt: prompt,
      fontSize: fontSize)
    commandPromptLayer.frame = Self.snap(
      frame,
      scale: scale)
    commandPromptLayer.contentsScale = scale
    let palette = commandInputPalette()
    commandPromptLayer.colors = [palette.bottomCG, palette.topCG]
    commandPromptLayer.borderColor = palette.borderCG
    commandPromptLayer.shadowPath = CGPath(
      roundedRect: commandPromptLayer.bounds,
      cornerWidth: commandPromptLayer.cornerRadius,
      cornerHeight: commandPromptLayer.cornerRadius,
      transform: nil)

    let horizontalPadding: CGFloat = 4
    let availableTextWidth = max(10, commandPromptLayer.frame.width - horizontalPadding * 2)
    let textWidth = ceil((prompt as NSString).size(withAttributes: [.font: labelFont]).width)
    let labelWidth = max(availableTextWidth, textWidth + 2)
    let scrollOffset: CGFloat = 0
    if inputMode == .commandLine {
      // The `:` now lives at the head of the editable buffer, so the
      // field owns the whole string (colon included) and no longer
      // needs a leading inset to clear a pinned prompt glyph.
      commandCaretLayer.isHidden = true
      configureCommandTextField(
        promptFrame: commandPromptLayer.frame,
        font: labelFont,
        fontSize: fontSize)
    } else {
      commandCaretLayer.isHidden = true
      hideCommandTextField()
    }
    let labelY = max(0, (commandPromptLayer.frame.height - fontSize - 2) / 2)
    commandPromptLabel.frame = CGRect(
      x: horizontalPadding - scrollOffset,
      y: labelY,
      width: labelWidth,
      height: fontSize + 2)
    commandPromptLabel.font = labelFont
    commandPromptLabel.fontSize = fontSize
    commandPromptLabel.foregroundColor = Self.nordSnowStorm2CG
    commandPromptLabel.contentsScale = scale
    commandPromptLabel.alignmentMode = .left
    if inputMode == .commandLine {
      // The editable field renders the colon + body; keep the backing
      // label empty so the `:` isn't painted twice.
      commandPromptLabel.string = ""
    } else {
      commandPromptLabel.string = prompt
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
    fontSize: CGFloat,
    leadingInset: CGFloat = 0
  ) {
    commandTextField.font = font
    commandTextField.textColor = Self.nordSnowStorm2
    commandTextField.frame = CGRect(
      x: promptFrame.minX + 4 + leadingInset,
      y: promptFrame.minY + max(0, (promptFrame.height - fontSize - 4) / 2),
      width: max(10, promptFrame.width - 8 - leadingInset),
      height: fontSize + 5)
    commandTextField.isHidden = false
  }

  static func commandPromptFrame(
    visibleFrame: CGRect,
    screenFrame: CGRect,
    statusBarFrame: CGRect,
    panelFrame: CGRect,
    prompt _: String,
    fontSize: CGFloat
  ) -> CGRect {
    // Width is fixed at the screen's golden fraction — clamped to a
    // sensible minimum so a tiny external display still gets a usable
    // input, and to the screen's interior so the panel never bleeds past
    // the visible region. The prompt text length intentionally does NOT
    // factor in: a long candidate title used to grow the input under the
    // user's cursor mid-typing, which read as a perceptual stutter even
    // when the work was cheap. Long inputs scroll inside the editor
    // instead.
    let availableWidth = max(180, visibleFrame.width - statusBarEdgePadding * 2)
    let maxWidth = max(220, availableWidth)
    let width = min(maxWidth, max(220, screenFrame.width * commandPromptWidthFraction))
    let height = ceil(max(fontSize + 20, 38))
    let minY = visibleFrame.minY - panelFrame.minY + 24
    let topBoundary = min(statusBarFrame.minY, visibleFrame.maxY) - panelFrame.minY
    let usableHeight = max(0, topBoundary - (visibleFrame.minY - panelFrame.minY))
    let goldenTopY = topBoundary - usableHeight * commandPromptTopOffsetFraction
    let maxY = topBoundary - height - 24
    return CGRect(
      x: visibleFrame.midX - panelFrame.minX - width / 2,
      y: max(minY, min(goldenTopY - height, maxY)),
      width: width,
      height: height)
  }

  static func commandPromptFontSize(statusBarFontSize: CGFloat) -> CGFloat {
    max(14, statusBarFontSize)
  }

  func hideCommandTextField() {
    commandTextField.isHidden = true
    if firstResponder === commandTextField || commandTextField.currentEditor() != nil {
      makeFirstResponder(self)
    }
  }

  func setCommandTextFieldText(
    _ text: String, cursorIndex: Int, underlineRange: NSRange? = nil
  ) {
    suppressCommandTextFieldChange = true
    commandLineText = text
    commandLineCursorIndex = cursorIndex
    let font = commandTextField.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    if let underline = underlineRange,
      underline.length > 0,
      underline.location >= 0,
      underline.location + underline.length <= (text as NSString).length
    {
      // Render `!<token>` underlined in the COMMAND accent (the same
      // purple as the COMMAND mode badge) so the lock-in reads as part
      // of the command surface rather than a generic green highlight.
      // NSTextField flows `attributedStringValue` into the live field
      // editor (NSTextView); the editor preserves attributes during
      // typing because we re-apply on every refresh.
      let attributed = NSMutableAttributedString(string: text)
      attributed.addAttribute(
        .font, value: font,
        range: NSRange(location: 0, length: (text as NSString).length))
      attributed.addAttribute(
        .foregroundColor, value: Self.nordSnowStorm2,
        range: NSRange(location: 0, length: (text as NSString).length))
      attributed.addAttributes(
        [
          .underlineStyle: NSUnderlineStyle.single.rawValue,
          .underlineColor: Self.nordAuroraPurple,
          .foregroundColor: Self.nordAuroraPurple,
        ],
        range: underline)
      if commandTextField.attributedStringValue != attributed {
        commandTextField.allowsEditingTextAttributes = true
        commandTextField.attributedStringValue = attributed
      }
    } else {
      if commandTextField.attributedStringValue.length > 0,
        commandTextField.attributedStringValue.string == text,
        !attributedStringHasAttributes(commandTextField.attributedStringValue)
      {
        // Already plain; leave alone.
      } else if commandTextField.stringValue != text
        || attributedStringHasAttributes(commandTextField.attributedStringValue)
      {
        commandTextField.allowsEditingTextAttributes = false
        commandTextField.stringValue = text
      }
    }
    syncCommandTextFieldSelection()
    suppressCommandTextFieldChange = false
  }

  private func attributedStringHasAttributes(_ string: NSAttributedString) -> Bool {
    guard string.length > 0 else { return false }
    var has = false
    string.enumerateAttributes(
      in: NSRange(location: 0, length: string.length),
      options: []
    ) { attrs, _, stop in
      if attrs[.underlineStyle] != nil {
        has = true
        stop.pointee = true
      }
    }
    return has
  }

  func syncCommandTextFieldSelection() {
    guard let editor = commandTextField.currentEditor() as? NSTextView else { return }
    editor.insertionPointColor = Self.nordSnowStorm2
    let value = commandTextField.stringValue
    let cursor = max(0, commandLineCursorIndex)
    editor.selectedRange = NSRange(
      location: utf16Offset(forCharacterOffset: cursor, in: value),
      length: 0)
  }

  func commandTextFieldCursorIndex() -> Int {
    guard let editor = commandTextField.currentEditor() as? NSTextView else {
      return commandTextField.stringValue.count
    }
    return characterOffset(
      forUTF16Offset: editor.selectedRange.location, in: commandTextField.stringValue)
  }

  func utf16Offset(forCharacterOffset offset: Int, in text: String) -> Int {
    let clamped = min(max(offset, 0), text.count)
    let index = text.index(text.startIndex, offsetBy: clamped)
    return index.samePosition(in: text.utf16)?.utf16Offset(in: text) ?? text.utf16.count
  }

  func characterOffset(forUTF16Offset offset: Int, in text: String) -> Int {
    let clamped = min(max(offset, 0), text.utf16.count)
    guard
      let utf16Index = text.utf16.index(
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
    var raw = commandTextField.stringValue
    // The `:` is the leading character of the buffer now; erasing it
    // (an empty field, or text that no longer starts with `:`) is the
    // gesture that drops back to NORMAL.
    guard raw.hasPrefix(":") else {
      commandLineText = ""
      commandLineCursorIndex = 0
      FlashLog.trace("[input] command_line cancel reason=prompt_erased")
      coordinator?.overlayDidCancelCommandLine()
      return
    }
    var cursor = commandTextFieldCursorIndex()
    // `[flashlight.aliases]` expansion: when the user just typed a
    // whitespace after `!<key>` and `<key>` is registered, rewrite
    // the buffer in place before the downstream parsing layer sees
    // it. The text field's contents + cursor are synced back so the
    // user sees the canonical bang appear under their cursor.
    if let expanded = coordinator?.overlayExpandFlashlightAlias(raw, cursorIndex: cursor) {
      raw = expanded.text
      cursor = expanded.cursorIndex
      suppressCommandTextFieldChange = true
      commandTextField.stringValue = raw
      suppressCommandTextFieldChange = false
    }
    commandLineText = raw
    commandLineCursorIndex = cursor
    syncCommandTextFieldSelection()
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
      let command = syncCommandLineStateFromFieldForCommand()
      FlashLog.trace("[input] command_line submit command=\(command)")
      coordinator?.overlayDidSubmitCommandLine(command)
      return true
    case #selector(NSResponder.deleteBackward(_:)):
      // Backspacing the lone `:` (or an already-empty field) erases the
      // prompt and drops back to NORMAL. With a body present, let the
      // field delete normally; controlTextDidChange catches the case
      // where that delete removes the leading colon.
      let value = commandTextField.stringValue
      guard value.isEmpty || value == ":" else { return false }
      commandLineText = ""
      commandLineCursorIndex = 0
      FlashLog.trace("[input] command_line cancel reason=prompt_erased")
      coordinator?.overlayDidCancelCommandLine()
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      commandLineText = ""
      commandLineCursorIndex = 0
      FlashLog.trace("[input] command_line cancel reason=cancel_operation")
      coordinator?.overlayDidCancelCommandLine()
      return true
    case #selector(NSResponder.insertTab(_:)):
      _ = syncCommandLineStateFromFieldForCommand()
      _ = coordinator?.overlayDidInsertCommandLineSelection()
      return true
    case #selector(NSResponder.insertBacktab(_:)):
      _ = coordinator?.overlayDidMoveCommandLineSelection(-1)
      return true
    case #selector(NSResponder.moveUp(_:)):
      _ = coordinator?.overlayDidMoveCommandLineSelection(-1)
      return true
    case #selector(NSResponder.moveDown(_:)):
      _ = coordinator?.overlayDidMoveCommandLineSelection(1)
      return true
    default:
      return false
    }
  }

  @discardableResult
  private func syncCommandLineStateFromFieldForCommand() -> String {
    let raw = commandTextField.stringValue
    let command = raw.hasPrefix(":") ? raw : ":" + raw
    let cursor = commandTextFieldCursorIndex() + (raw.hasPrefix(":") ? 0 : 1)
    commandLineText = command
    commandLineCursorIndex = min(max(0, cursor), command.count)
    return command
  }
}
