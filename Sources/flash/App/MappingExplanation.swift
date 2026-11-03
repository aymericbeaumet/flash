import FlashCore
import Foundation

/// One sentence for a mapping's `?` hover and for search. The sentence names
/// the verb's flags, so two bindings of the same verb do not share a line.
extension MappingCommand {
  var explanation: String {
    switch self {
    case .flashCommand(let command):
      return command.explanation
    case .shellCommand(let argv):
      return "Runs \(argv.joined(separator: " "))."
    }
  }
}

extension URLCommand {
  var explanation: String {
    switch self {
    case .mouseTarget(let command):
      return
        "Labels targets in the focused window and \(gesture(command, object: "the one you pick", plural: "the ones you pick"))."
    case .mouseTargetScreen(let command):
      return
        "Labels targets across the front of this screen and \(gesture(command, object: "the one you pick", plural: "the ones you pick"))."
    case .mouseTargetWords(let command):
      return
        "Labels the visible words in the focused window and \(gesture(command, object: "the start of the one you pick", plural: "the ones you pick"))."
    case .mouseScreens(let request):
      return screenSelectExplanation(request)
    case .mouseWarp(let request):
      let area = request.area == .window ? "the focused window" : "the screen"
      let edge = request.edge == .center ? "the centre" : "the \(request.edge.rawValue) edge"
      return "Moves the pointer to \(edge) of \(area)."
    case .mouseJump(let jump):
      switch jump {
      case .nextWord: return "Moves the cursor to the start of the next word."
      case .previousWord: return "Moves the cursor to the start of this or the previous word."
      case .wordEnd: return "Moves the cursor to the end of this or the next word."
      case .lineStart: return "Moves the cursor to the start of its line."
      case .lineEnd: return "Moves the cursor to the end of its line."
      }
    case .selection(let action, _):
      switch action {
      case .copy: return "Copies the selected text, ending a drag or VISUAL."
      case .paste: return "Pastes over the selected text, ending a drag or VISUAL."
      case .swapEnds: return "Moves VISUAL's moving end to the other end of the selection."
      }
    case .visualMode(let kind):
      return kind == .linewise
        ? "Selects whole lines from the cursor (VISUAL), or switches to them; again, leaves."
        : "Selects from the cursor (VISUAL), or switches to characters; again, leaves."
    case .visualReselect:
      return "Selects the last VISUAL range again, in the field it was made in."
    case .mouseNudge(let direction, let distance):
      return "Moves the pointer \(distance) points \(direction.rawValue)."
    case .mouseStep(let direction):
      switch direction {
      case .up, .down:
        return "Moves the pointer one text line \(direction.rawValue), in its column."
      case .left, .right:
        return "Moves the pointer one character \(direction.rawValue)."
      }
    case .mousePosition(let request):
      return positionExplanation(request)
    case .mouseBigram(let command):
      return
        "Asks for a letter, then a two-character hint, and \(gesture(command, object: "that glyph", plural: "each glyph"))."
    case .mouseGrid(let request):
      return gridExplanation(request)
    case .mouseRepeat:
      return "Clicks again where Flash last clicked."
    case .mousePointer:
      return "Moves the pointer from the keyboard."
    case .mouseButton(let request):
      return buttonExplanation(request)
    case .holdMode(let button):
      let name: String
      switch button {
      case .primary: name = "left"
      case .secondary: name = "right"
      case .middle: name = "middle"
      }
      return "Grabs what is under the pointer with the \(name) button (HOLD), or drops it."
    case .focusInput:
      return "Moves into an editable field in the focused window without changing mode."
    case .inputMotion(let motion):
      switch motion {
      case .lineStart: return "Moves the cursor to the start of its line in the focused text."
      case .lineEnd: return "Moves the cursor to the end of its line in the focused text."
      case .charRight: return "Moves the cursor one character right in the focused text."
      case .charLeft: return "Moves the cursor one character left in the focused text."
      case .lineUp: return "Moves the cursor up a line in the focused text."
      case .lineDown: return "Moves the cursor down a line in the focused text."
      case .documentStart: return "Moves the cursor to the start of the focused text."
      case .documentEnd: return "Moves the cursor to the end of the focused text."
      case .selectLeft, .selectRight, .selectUp, .selectDown, .selectWordLeft, .selectWordRight,
        .selectLineStart, .selectLineEnd, .selectDocumentStart, .selectDocumentEnd:
        return "Extends the selection with the app's selection key ("
          + motion.rawValue.replacingOccurrences(of: "_", with: " ") + ") in the focused text."
      }
    case .move(let move):
      return moveExplanation(move)
    case .scrollTarget:
      return
        "Labels scroll areas in the focused window and moves the pointer into the one you pick."
    case .mouseDock:
      return "Labels Dock items so you can click one."
    case .mouseMenuBar:
      return "Labels the focused app's menu titles and the menu-bar status items."
    case .mouseNotifications:
      return "Labels Notification Center banners, alerts, and their buttons."
    case .normalMode:
      return "Enters NORMAL mode."
    case .leaveMode:
      return "Leaves the current mode."
    case .popupRestart(let name):
      return name.map { "Restarts the \($0) popup." } ?? "Restarts the focused popup."
    case .popupQuit(let name):
      return name.map { "Quits the \($0) popup." } ?? "Quits the focused popup."
    case .insertMode:
      return "Enters INSERT mode."
    case .commandMode:
      return "Opens the command line."
    case .terminalMode(let name):
      return name.map { "Opens the \($0) popup and gives its terminal the keyboard." }
        ?? "Opens the terminal popup and gives it the keyboard."
    case .layerMode(let name):
      return "Enters the \(name) layer: its keys act until Escape."
    case .scroll(let kind):
      return scrollExplanation(kind)
    case .reload(let force):
      return force
        ? "Reloads the focused app, bypassing its cache."
        : "Reloads the focused app."
    case .undo:
      return "Undoes the last edit in the focused app."
    case .redo:
      return "Redoes the last edit in the focused app."
    case .archive:
      return "Archives the current item in the focused app."
    case .resourceNext:
      return "Goes to the next item in the focused app."
    case .resourcePrevious:
      return "Goes to the previous item in the focused app."
    case .tabClose:
      return "Closes the current tab."
    case .find:
      return "Opens Find in the focused app."
    case .findNext:
      return "Goes to the next Find match in the focused app."
    case .findPrevious:
      return "Goes to the previous Find match in the focused app."
    case .appSwitch:
      return "Opens Flashlight on what is running."
    case .flashlight(let query, let restoreMode):
      let base =
        query.map { "Opens Flashlight on `\($0)`." } ?? "Opens Flashlight across every source."
      return restoreMode ? base + " Closing it returns to the mode it opened from." : base
    case .enterCommand(let input, let restoreMode):
      return commandLineExplanation(input: input, restoreMode: restoreMode)
    case .copyURL:
      return "Copies the URL of the focused page."
    case .yankSelection(let register):
      return yankExplanation(register)
    case .paste(let register, let after):
      return after
        ? "Steps past the character under the cursor, then "
          + pasteExplanation(register).prefix(1).lowercased()
          + pasteExplanation(register).dropFirst()
        : pasteExplanation(register)
    case .cursor(let command):
      return cursorExplanation(command)
    case .scrollCursor(let position):
      switch position {
      case .top: return "Scrolls the focused text so the cursor's line is at the top."
      case .middle: return "Scrolls the focused text so the cursor's line is in the middle."
      case .bottom: return "Scrolls the focused text so the cursor's line is at the bottom."
      }
    case .tabNext:
      return "Selects the next tab."
    case .tabPrev:
      return "Selects the previous tab."
    case .tabFirst:
      return "Selects the first tab."
    case .tabLast:
      return "Selects the last tab."
    case .tabSelect(let index):
      return index.map { "Selects tab \($0)." } ?? "Selects a tab by the count you type."
    case .tabMovePrev:
      return "Moves the current tab one place backward."
    case .tabMoveNext:
      return "Moves the current tab one place forward."
    case .tabReopen:
      return "Reopens the last closed tab."
    case .paneNext:
      return "Focuses the next split pane."
    case .panePrev:
      return "Focuses the previous split pane."
    case .paneSplitVertical:
      return "Splits the focused pane vertically."
    case .paneSplitHorizontal:
      return "Splits the focused pane horizontally."
    case .paneClose:
      return "Closes the focused split pane."
    case .historyBack:
      return "Goes back in the focused app."
    case .historyForward:
      return "Goes forward in the focused app."
    case .movementBack:
      return "Jumps back through Flash's movement history."
    case .movementForward:
      return "Jumps forward through Flash's movement history."
    case .appPrev:
      return "Focuses the previous app."
    case .appNext:
      return "Focuses the next app."
    case .quitApp(let force):
      return force ? "Force-quits the focused app." : "Quits the focused app."
    case .saveAndQuit(let force):
      return force
        ? "Saves the focused document, then force-quits the app."
        : "Saves the focused document, then quits the app."
    case .appClose:
      return "Closes the current tab, else the focused window; the app's last window quits it."
    case .tabNew:
      return "Opens a new tab in the focused app."
    case .save:
      return "Saves the focused document."
    case .print:
      return "Prints the focused document."
    case .documentOpen:
      return "Opens a document in the focused app."
    case .windowNew(let isPrivate):
      return isPrivate ? "Opens a new private browsing window." : "Opens a new window."
    case .windowCloseAll:
      return "Asks before closing every window of the focused app."
    case .windowZoom:
      return "Zooms the focused window to fit its content, or back."
    case .documentSaveAs:
      return "Saves the focused document under another name."
    case .documentExportPDF:
      return "Exports the focused document as a PDF."
    case .documentRevert:
      return "Asks before reverting the focused document to its last saved version."
    case .documentDuplicate:
      return "Duplicates the focused document."
    case .documentRename:
      return "Renames the focused document."
    case .documentPageSetup:
      return "Opens the focused document's page setup."
    case .appSettings:
      return "Opens the focused app's settings."
    case .selectAll:
      return "Selects everything in the focused app."
    case .appHelp:
      return "Opens the focused app's Help menu."
    case .appCancel:
      return "Cancels in the focused app: closes its popover, dialog or search."
    case .appStop:
      return "Stops loading the focused browser page."
    case .appDownloads:
      return "Shows the focused browser's downloads."
    case .developerTools:
      return "Opens the focused browser's developer tools."
    case .appVisibility(let action):
      switch action {
      case .hide: return "Hides the focused app."
      case .hideOthers: return "Hides every app but the focused one."
      case .showAll: return "Shows every hidden app."
      case .raise: return "Brings every window of the focused app to the front."
      }
    case .urlBookmark:
      return "Bookmarks the focused page."
    case .urlEdit:
      return "Focuses the focused browser's address bar."
    case .historyShow:
      return "Shows the focused browser's history."
    case .tabDuplicate:
      return "Duplicates the current tab."
    case .tabPin:
      return "Pins or unpins the current tab."
    case .tabMute:
      return "Mutes or unmutes the current tab."
    case .tabDetach:
      return "Moves the current tab to a new window."
    case .menuPress(let path):
      return "Presses the focused app's \(path.joined(separator: " › ")) menu item."
    case .windowClose:
      return "Closes the focused window."
    case .clipboardCopy:
      return "Copies with the focused app's copy command."
    case .clipboardPaste:
      return "Pastes with the focused app's paste command."
    case .clipboardHistory(let action, _, _):
      switch action {
      case "show": return "Opens clipboard history."
      case "pin": return "Pins a clipboard history entry, so it lists first and is never trimmed."
      case "unpin": return "Unpins a clipboard history entry."
      default: return "Deletes a clipboard history entry."
      }
    case .clipboardRestore(_, let paste, let plain):
      let what = plain ? "a clipboard history entry's plain text" : "a clipboard history entry"
      return paste
        ? "Pastes \(what) into the focused app." : "Puts \(what) back on the clipboard."
    case .lookUp:
      return "Looks up the word under the pointer with the focused app's Look Up."
    case .zoomIn:
      return "Zooms in with the focused app's own zoom."
    case .zoomOut:
      return "Zooms out with the focused app's own zoom."
    case .zoomReset:
      return "Resets the focused app's zoom to actual size."
    case .viewSource:
      return "Shows the focused browser page's source."
    case .trackpadGesture(let fingers, let motion):
      return gestureExplanation(fingers: fingers, motion: motion)
    case .showAlert(let alert):
      return alertExplanation(alert)
    case .dismissAlert:
      return "Dismisses the alert."
    case .confirm(let request):
      return
        "Asks \"\(request.prompt)\" first; y then \(request.command.explanation.lowercasedFirst)"
    case .showUsage(let topic):
      if let topic, !topic.isEmpty { return "Opens the \(topic) documentation page." }
      return "Opens Flash's help home page."
    case .showMappings:
      return "Opens the mappings page."
    case .showPlugins:
      return "Opens the plugins page."
    case .reloadPlugins:
      return "Stops and restarts every loaded plugin."
    case .showLogs:
      return "Opens the logs page."
    case .showCommands:
      return "Opens the command catalog."
    case .showMonitors:
      return "Opens the monitors page."
    case .showTelemetry:
      return "Opens the telemetry page."
    case .showAbout:
      return "Opens the About window."
    case .dismissHints:
      return "Dismisses hint labels."
    case .quit:
      return "Quits Flash."
    case .openApp(let name):
      return "Activates \(name)."
    case .pluginCommand(let command, let subcommand, let args):
      if args.isEmpty { return "Runs the \(command) \(subcommand) command." }
      return "Runs the \(command) \(subcommand) command with \(args.joined(separator: " "))."
    case .moveWindow(let params):
      return windowMoveExplanation(params)
    case .focusWindow(let request):
      switch request {
      case .direction(let direction):
        return "Focuses the window to the \(direction.rawValue)."
      case .cycle(.next):
        return "Focuses the next window down the stacking order."
      case .cycle(.previous):
        return "Focuses the next window up the stacking order."
      case .cycle(.behind):
        return "Focuses the window just behind the focused one."
      case .app(.next):
        return "Focuses the app's next window."
      case .app(.previous):
        return "Focuses the app's previous window."
      }
    case .windowState(let action):
      return windowStateExplanation(action)
    case .windowSwitch:
      return "Lists every window, most recently used first, to pick one by its label."
    case .windowLast:
      return "Focuses the window you were in before this one."
    case .tile(let command):
      return command.explanation
    case .workspace(let command):
      return command.explanation
    case .media(let command):
      return mediaExplanation(command)
    case .caffeinate(let request):
      return caffeinateExplanation(request)
    case .statusPush(let push):
      return push.explanation
    case .statusRefresh(let source):
      return StatusRefresh.explanation(source)
    case .notify(let command):
      return command.explanation
    case .logWrite(let write):
      return write.explanation
    case .metricRecord(let record):
      return record.explanation
    case .menuChoose(let file, _):
      return MenuChoice.explanation(file: file)
    case .macro(let command):
      return command.explanation
    case .configReload:
      return "Re-reads the configuration file now."
    case .configEdit:
      return "Opens the configuration file in its default app."
    case .updates(let command):
      return command.explanation
    case .startup(let command):
      return command.explanation
    case .appleCatalog(let command):
      return command.explanation
    case .calendar(let command):
      return command.explanation
    case .marks(let command):
      return command.explanation
    case .systemKey(let key):
      return systemKeyExplanation(key)
    case .systemSurface(let command):
      return command.explanation
    case .systemAction(let action):
      return action.explanation
    case .processKill(let pid):
      return "Asks before terminating process \(pid)."
    case .functionKey(let index):
      return "Sends F\(index) to the focused app."
    case .arrow(let direction, let shift):
      let name = direction.rawValue.prefix(1).uppercased() + direction.rawValue.dropFirst()
      return shift ? "Posts Shift+\(name)." : "Posts the \(name) arrow."
    case .sendKey(let keys, _, _):
      return "Types \(keys) into the focused app."
    case .sendKeys(let keys, _, _):
      return "Types \(keys) into the focused app."
    }
  }
}

private func gesture(_ command: MouseCommand, object: String, plural: String) -> String {
  let held = command.modifiers.isEmpty ? "" : " while holding \(command.modifiers.argumentValue)"
  switch command {
  case .move:
    return "moves the pointer onto \(object)"
  case .copyURL:
    return "copies the URL of \(object)"
  case .copyText:
    return "copies the text of \(object)"
  case .gesture(.lookUp):
    return "looks up the word at \(object)"
  case .gesture(.smartZoom):
    return "smart-zooms at \(object)"
  case .drag:
    return "drags from \(object)\(held)"
  case .select:
    return "selects text from \(object)\(held)"
  case .click(let action, _):
    return "\(clicks(action)) \(object)\(held)"
  case .multi(let action, _):
    return "keeps \(clicking(action)) \(plural) until you cancel\(held)"
  case .adjust(let action, _):
    return "lets you place the point, then \(clicks(action)) it\(held)"
  case .search(let action, _):
    return "lets you type to filter the targets, then \(clicks(action)) \(object)\(held)"
  case .path(let action, _):
    return "\(clicks(action)) every target between the two you pick\(held)"
  case .sticky(let action, _):
    return "keeps \(clicking(action)) \(plural) with the same labels until you cancel\(held)"
  }
}

private func positionExplanation(_ request: MousePositionRequest) -> String {
  switch request {
  case .save: return "Saves the pointer's position."
  case .unsave: return "Forgets the saved position under the pointer."
  case .clear: return "Forgets every saved position."
  case .hints(let command):
    return
      "Labels the saved positions and \(gesture(command, object: "the one you pick", plural: "the ones you pick"))."
  case .next: return "Jumps to the next saved position."
  case .previous: return "Jumps to the previous saved position."
  }
}

private func clicks(_ action: JumpAction) -> String {
  switch action {
  case .leftClick: return "left-clicks"
  case .rightClick: return "right-clicks"
  case .middleClick: return "middle-clicks"
  case .doubleClick: return "double-clicks"
  case .tripleClick: return "triple-clicks"
  }
}

private func clicking(_ action: JumpAction) -> String {
  switch action {
  case .leftClick: return "left-clicking"
  case .rightClick: return "right-clicking"
  case .middleClick: return "middle-clicking"
  case .doubleClick: return "double-clicking"
  case .tripleClick: return "triple-clicking"
  }
}

private func gridExplanation(_ request: MouseGridRequest) -> String {
  var opener = request.bisect ? "Opens the half-and-quadrant grid" : "Opens the keyboard grid"
  if let depth = request.zoomToDepth {
    opener += " \(depth) \(depth == 1 ? "step" : "steps") deep under the pointer"
  }
  let object = "the cell you choose"
  return "\(opener) and \(gesture(request.mouse, object: object, plural: "the cells you choose"))."
}

private func buttonExplanation(_ request: MouseButtonRequest) -> String {
  let button: String
  switch request.button {
  case .primary: button = "left"
  case .secondary: button = "right"
  case .middle: button = "middle"
  }
  switch request.state {
  case .down:
    return "Grabs what is under the pointer with the \(button) mouse button."
  case .up:
    return "Drops what the \(button) mouse button is dragging, where the pointer is."
  case .toggle:
    return
      "Grabs what is under the pointer with the \(button) mouse button, or drops what it drags."
  case .release:
    return "Drops what is being dragged, where the pointer is."
  case .cancel:
    return "Puts a drag back where it started and lets go."
  }
}

private func scrollExplanation(_ kind: NormalModeDispatcher.ScrollKind) -> String {
  switch kind {
  case .left: return "Scrolls left at the pointer."
  case .right: return "Scrolls right at the pointer."
  case .up: return "Scrolls up one step at the pointer."
  case .down: return "Scrolls down one step at the pointer."
  case .lineUp: return "Scrolls up one line at the pointer, a count that many."
  case .lineDown: return "Scrolls down one line at the pointer, a count that many."
  case .halfPageUp: return "Scrolls up half a page at the pointer."
  case .halfPageDown: return "Scrolls down half a page at the pointer."
  case .pageUp: return "Scrolls up a full page at the pointer."
  case .pageDown: return "Scrolls down a full page at the pointer."
  case .top: return "Scrolls to the top."
  case .bottom: return "Scrolls to the bottom."
  }
}

private func commandLineExplanation(input: String, restoreMode: Bool) -> String {
  var sentence = "Opens the command line"
  if !input.isEmpty { sentence += " starting with \(input)" }
  sentence += "."
  if restoreMode { sentence += " Leaving it returns to the mode you were in." }
  return sentence
}

private func yankExplanation(_ register: String?) -> String {
  guard let register else { return "Copies the selection." }
  if register.count == 1, let character = register.first, character.isUppercase {
    return "Appends the selection to register \(character.lowercased())."
  }
  return "Copies the selection into register \(register)."
}

private func pasteExplanation(_ register: String?) -> String {
  guard let register else { return "Types the clipboard into the focused app." }
  return "Types register \(register) into the focused app."
}

private func alertExplanation(_ alert: AlertCommand) -> String {
  let kind = alert.style == .error ? "an error alert" : "an alert"
  var sentence = "Shows \(kind): \(alert.message)."
  if let duration = alert.duration {
    let shown = duration.rounded() == duration ? String(Int(duration)) : String(duration)
    sentence += " It stays for \(shown) seconds."
  }
  return sentence
}

private func windowMoveExplanation(_ params: MoveWindowParams) -> String {
  let display = displayName(params.screen)
  switch params.layout {
  case .position(let position):
    return "Moves the focused window to \(slotName(position)) of \(display)."
  case .proportional(let frame):
    return
      "Places the focused window \(percent(frame.widthPercent)) wide and \(percent(frame.heightPercent)) tall, \(percent(frame.xPercent)) from the left and \(percent(frame.yPercent)) from the top of \(display)."
  case nil:
    return params.screen == 0
      ? "Leaves the focused window where it is."
      : "Moves the focused window onto \(display), keeping its size."
  }
}

private func slotName(_ position: WindowPosition) -> String {
  switch position {
  case .topLeft: return "the top-left quarter"
  case .topRight: return "the top-right quarter"
  case .bottomLeft: return "the bottom-left quarter"
  case .bottomRight: return "the bottom-right quarter"
  case .leftHalf: return "the left half"
  case .rightHalf: return "the right half"
  case .topHalf: return "the top half"
  case .bottomHalf: return "the bottom half"
  case .maximized: return "the full usable frame"
  case .centered: return "the centre"
  }
}

private func screenSelectExplanation(_ request: ScreenSelectRequest) -> String {
  let display: String
  switch request.pick {
  case .labels:
    display = "Labels each display by its number and moves the pointer to the one you pick"
  case .index(let number): display = "Moves the pointer to display \(number)"
  case .next: display = "Moves the pointer to the next display"
  case .previous: display = "Moves the pointer to the previous display"
  }
  let landing =
    request.landing == .last ? ", where it last left that display" : ", to its centre"
  let focus = request.focus ? ", and focuses the frontmost window there" : ""
  return display + landing + focus + "."
}

private func displayName(_ screen: Int) -> String {
  switch screen {
  case 0: return "the screen"
  case 1: return "the next display"
  case -1: return "the previous display"
  default:
    let count = abs(screen)
    return screen > 0 ? "the display \(count) ahead" : "the display \(count) back"
  }
}

private func percent(_ value: Double) -> String {
  value.rounded() == value ? "\(Int(value))%" : "\(value)%"
}

private func windowStateExplanation(_ action: WindowStateAction) -> String {
  switch action {
  case .minimize:
    return "Minimizes the focused window."
  case .restore:
    return "Restores the most recently minimized window."
  case .fullscreen(let state):
    switch state {
    case .toggle: return "Toggles full screen for the focused window."
    case .on: return "Enters full screen for the focused window."
    case .off: return "Leaves full screen for the focused window."
    }
  }
}

private func mediaExplanation(_ command: MediaCommand) -> String {
  switch command {
  case .volumeUp: return "Raises the output volume one step and shows the percent."
  case .volumeDown: return "Lowers the output volume one step and shows the percent."
  case .volumeMute: return "Mutes or unmutes the output."
  case .device(let direction, nil): return "Lists the audio \(direction.rawValue) devices."
  case .device(let direction, let query?):
    return "Makes \(query) the default audio \(direction.rawValue)."
  case .status: return "Shows what the media apps are playing and the volume."
  }
}

private func caffeinateExplanation(_ request: CaffeinateRequest) -> String {
  func bound(_ minutes: Int?) -> String {
    minutes.map { " for \($0) minute\($0 == 1 ? "" : "s")" } ?? ""
  }
  switch request {
  case .on(let minutes): return "Keeps the Mac awake\(bound(minutes))."
  case .off: return "Lets the Mac sleep again."
  case .toggle(let minutes): return "Keeps the Mac awake\(bound(minutes)), or lets it sleep again."
  case .status: return "Shows whether the Mac is kept awake."
  }
}

private func systemKeyExplanation(_ key: SystemKeyboard.RowKey) -> String {
  switch key {
  case .brightnessDown: return "Lowers the display brightness."
  case .brightnessUp: return "Raises the display brightness."
  case .spotlight: return "Opens Spotlight."
  case .dictation: return "Starts dictation."
  case .focus: return "Toggles Focus."
  case .mediaPrevious: return "Skips to the previous track."
  case .mediaPlay: return "Plays or pauses media."
  case .mediaNext: return "Skips to the next track."
  case .mute: return "Mutes or unmutes the volume."
  case .volumeDown: return "Lowers the volume."
  case .volumeUp: return "Raises the volume."
  }
}

extension String {
  /// The sentence with its first letter lowercased, so one explanation can
  /// continue another ("y then closes the current tab.").
  fileprivate var lowercasedFirst: String {
    guard let first = first else { return self }
    return first.lowercased() + dropFirst()
  }
}

private func gestureExplanation(fingers: Int, motion: TrackpadGesture.Motion) -> String {
  let what: String
  switch TrackpadGesture.action(fingers: fingers, motion: motion) {
  case .secondaryClick: what = "right-clicks at the pointer"
  case .smartZoom: what = "smart-zooms at the pointer"
  case .zoom(let zoomIn): what = zoomIn ? "zooms in at the pointer" : "zooms out at the pointer"
  case .rotate(let left):
    what = left ? "rotates left at the pointer" : "rotates right at the pointer"
  case .historyBack: what = "goes back a page"
  case .historyForward: what = "goes forward a page"
  case .lookUp: what = "looks up the word under the pointer"
  case .surface(let surface):
    what = SystemSurfaceCommand(surface, .toggle).action.lowercasedFirst
  case .spaceLeft: what = "moves to the Space on the left"
  case .spaceRight: what = "moves to the Space on the right"
  case nil: what = "does nothing"
  }
  return "A \(fingers)-finger \(motion.rawValue.replacingOccurrences(of: "_", with: " ")): \(what)."
}

extension URLCommand {
  /// `move`: what each region makes of it, in one sentence.
  fileprivate func moveExplanation(_ move: MoveCommand) -> String {
    switch move {
    case .down, .up:
      let way = move.rawValue
      return
        "Moves \(way): the caret in text, the selection in a list, else scrolls \(way)."
    case .left, .right:
      let way = move.rawValue
      return
        "Moves \(way): the caret within its line, the selection in a list, else scrolls \(way)."
    case .halfPageDown, .halfPageUp:
      let way = move == .halfPageDown ? "down" : "up"
      return
        "Moves \(way) by [mode] move_page_lines arrows in text and lists, else scrolls "
        + "half a page."
    case .pageDown, .pageUp:
      let way = move == .pageDown ? "down" : "up"
      return
        "Moves \(way) by twice [mode] move_page_lines arrows in text and lists, else scrolls "
        + "a page."
    case .top:
      return "Moves to the start of the text, the first item where the app binds one, else the top."
    case .bottom:
      return "Moves to the end of the text, the last item where the app binds one, else the bottom."
    }
  }
}

extension URLCommand {
  /// `cursor`: the motion's summary as a sentence.
  fileprivate func cursorExplanation(_ command: CursorCommand) -> String {
    let summary: String
    switch command {
    case .motion(let motion):
      summary =
        CursorCommand.action(of: motion).flatMap { CursorCommand.motionSummaries[$0] }
        ?? "Moves the cursor"
    case .line(let index): summary = "Move to line \(index)"
    case .percent(let percent): summary = "Move to the line \(percent)% of the way through"
    case .findCharacter(let kind, let character):
      summary =
        kind.summary + (character.map { ": \($0)" } ?? ", reading the character next")
    case .repeatCharacterSearch(let reversed):
      summary =
        reversed
        ? "Repeat the last character search the other way" : "Repeat the last character search"
    }
    let verb = summary.hasPrefix("Move") ? "Moves" + summary.dropFirst(4) : summary
    return verb + " in the focused text."
  }
}
