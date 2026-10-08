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
    case .focusInput:
      return "Moves into an editable field in the focused window without changing mode."
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
      return "Opens Find, then enters INSERT."
    case .candidateFinder(let all):
      return all ? "Opens Flashlight across every source." : "Opens Flashlight."
    case .enterCommand(let input, let restoreMode):
      return commandLineExplanation(input: input, restoreMode: restoreMode)
    case .copyURL:
      return "Copies the URL of the focused page."
    case .yankSelection(let register):
      return yankExplanation(register)
    case .paste(let register):
      return pasteExplanation(register)
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
    case .tabNew:
      return "Opens a new tab, then enters INSERT."
    case .save:
      return "Saves the focused document."
    case .print:
      return "Prints the focused document."
    case .documentOpen:
      return "Opens a document in the focused app."
    case .windowNew:
      return "Opens a new window."
    case .windowClose:
      return "Closes the focused window."
    case .clipboardCopy:
      return "Copies with the focused app's copy command."
    case .clipboardCut:
      return "Cuts with the focused app's cut command."
    case .clipboardPaste:
      return "Pastes with the focused app's paste command."
    case .showAlert(let alert):
      return alertExplanation(alert)
    case .dismissAlert:
      return "Dismisses the alert."
    case .showUsage(let topic):
      if let topic, !topic.isEmpty { return "Opens the \(topic) help topic." }
      return "Opens the help homepage."
    case .showMappings:
      return "Opens the mappings page."
    case .showPlugins:
      return "Opens the plugins page."
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
    case .focusWindow(let direction):
      return "Focuses the window to the \(direction.rawValue)."
    case .windowState(let action):
      return windowStateExplanation(action)
    case .systemKey(let key):
      return systemKeyExplanation(key)
    case .functionKey(let index):
      return "Sends F\(index) to the focused app."
    case .arrow(let direction, let shift):
      let name = direction.rawValue.prefix(1).uppercased() + direction.rawValue.dropFirst()
      return shift ? "Posts Shift+\(name)." : "Posts the \(name) arrow."
    case .sendKey(let keys, _, _):
      return "Types \(keys) into the focused app."
    case .sendKeys(let keys, _, _):
      return "Types \(keys) into the focused app."
    case .pluginVerb(let name, let args):
      if args.isEmpty { return "Runs the \(name) verb." }
      let detail = args.keys.sorted().map { "\($0) \(args[$0] ?? "")" }.joined(separator: ", ")
      return "Runs the \(name) verb with \(detail)."
    }
  }
}

private func gesture(_ command: MouseCommand, object: String, plural: String) -> String {
  let held = command.modifiers.isEmpty ? "" : " while holding \(command.modifiers.argumentValue)"
  switch command {
  case .move:
    return "moves the pointer onto \(object)"
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
    return "Holds the \(button) mouse button at the pointer."
  case .up:
    return "Releases the \(button) mouse button."
  case .toggle:
    return "Toggles the \(button) mouse button at the pointer."
  }
}

private func scrollExplanation(_ kind: NormalModeDispatcher.ScrollKind) -> String {
  switch kind {
  case .left: return "Scrolls left at the pointer."
  case .right: return "Scrolls right at the pointer."
  case .up: return "Scrolls up one step at the pointer."
  case .down: return "Scrolls down one step at the pointer."
  case .halfPageUp: return "Scrolls up one page step at the pointer."
  case .halfPageDown: return "Scrolls down one page step at the pointer."
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

private func systemKeyExplanation(_ key: SystemKeyboard.RowKey) -> String {
  switch key {
  case .brightnessDown: return "Lowers the display brightness."
  case .brightnessUp: return "Raises the display brightness."
  case .missionControl: return "Opens Mission Control."
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
