import AppKit
import FlashCore

extension URLCommand {
  /// Argv of an in-process command:
  /// `["flash", "<topic>", "<action>", "--k=v", ...]`. Bool flags render only
  /// when on. Value flags use hyphenated `--name=value`. A value that contains
  /// a space stays one element.
  var argv: [String] {
    /// `name` is `"<topic> <action>"`.
    func named(_ name: String, _ args: [String] = []) -> [String] {
      ["flash"] + name.split(separator: " ").map(String.init) + args
    }
    /// Bool-flag arg: `--name` (when on). Off bool flags don't render.
    func flag(_ name: String) -> String { "--\(name)" }
    /// Value arg: `--name=value`. The internal key is snake_case; surface
    /// the hyphenated form so the rendered string can be pasted back into
    /// a shell or config without translation.
    func kv(_ name: String, _ value: Any) -> String {
      let key = name.replacingOccurrences(of: "_", with: "-")
      return "--\(key)=\(value)"
    }
    func percentage(_ value: Double) -> String {
      value.rounded() == value ? "\(Int(value))%" : "\(value)%"
    }
    switch self {
    case .mouseTarget(let command):
      return named("mouse target", command.argTokens)
    case .mouseBigram(let command):
      return named("mouse bigram", command.argTokens)
    case .mouseTargetScreen(let command):
      return named("mouse target", ["--scope=screen"] + command.argTokens)
    case .mouseTargetWords(let command):
      return named("mouse target", ["--words"] + command.argTokens)
    case .mouseScreens(let request): return named("mouse screens", request.argTokens)
    case .mouseWarp(let request): return named("mouse warp", request.argTokens)
    case .mouseStep(let direction):
      return named("mouse step", ["--direction=\(direction.rawValue)"])
    case .mouseJump(let jump): return named("mouse step", ["--to=\(jump.rawValue)"])
    case .selection(let action, let register):
      return named("selection \(action.rawValue)", register.map { [kv("register", $0)] } ?? [])
    case .mouseNudge(let direction, let distance):
      return named("mouse nudge", ["--direction=\(direction.rawValue)", "--distance=\(distance)"])
    case .mousePosition(let request): return named("mouse position", request.argTokens)
    case .mouseGrid(let command):
      return named("mouse grid", command.argTokens)
    case .mouseRepeat: return named("mouse repeat")
    case .mousePointer: return named("mouse pointer")
    case .mouseButton(let request): return named("mouse button", request.argTokens)
    case .holdMode(let button):
      switch button {
      case .primary: return named("mode hold")
      case .secondary: return named("mode hold", [flag("secondary")])
      case .middle: return named("mode hold", [flag("middle")])
      }
    case .focusInput: return named("input focus")
    case .inputMotion(let motion): return named("input \(motion.rawValue)")
    case .move(let move): return named("move \(move.rawValue)")
    case .cursor(let command):
      return named("cursor \(command.argvTail[0])", Array(command.argvTail.dropFirst()))
    case .scrollCursor(let position): return named("scroll \(position.rawValue)")
    case .visualMode(let kind):
      return kind == .linewise ? named("mode visual", [flag("line")]) : named("mode visual")
    case .visualReselect: return named("mode visual", [flag("reselect")])
    case .scrollTarget: return named("scroll target")
    case .mouseDock: return named("mouse dock")
    case .mouseMenuBar: return named("mouse menubar")
    case .mouseNotifications: return named("mouse notifications")
    case .normalMode: return named("mode normal")
    case .leaveMode: return named("mode leave")
    case .popupRestart(let name):
      return named("popup restart", name.map { ["--name=\($0)"] } ?? [])
    case .popupQuit(let name):
      return named("popup quit", name.map { ["--name=\($0)"] } ?? [])
    case .insertMode: return named("mode insert")
    case .commandMode: return named("mode command")
    case .terminalMode(let name):
      return named("mode terminal", name.map { ["--name=\($0)"] } ?? [])
    case .layerMode(let name): return named("mode layer", ["--name=\(name)"])
    case .scroll(let kind):
      switch kind {
      case .left: return named("scroll left")
      case .right: return named("scroll right")
      case .up: return named("scroll up")
      case .down: return named("scroll down")
      case .lineUp: return named("scroll line_up")
      case .lineDown: return named("scroll line_down")
      case .halfPageUp: return named("scroll half_page_up")
      case .halfPageDown: return named("scroll half_page_down")
      case .pageUp: return named("scroll page_up")
      case .pageDown: return named("scroll page_down")
      case .top: return named("scroll top")
      case .bottom: return named("scroll bottom")
      }
    case .reload(let force):
      return force ? named("app reload", [flag("force")]) : named("app reload")
    case .undo: return named("app undo")
    case .redo: return named("app redo")
    case .archive: return named("resource archive")
    case .resourceNext: return named("resource next")
    case .resourcePrevious: return named("resource previous")
    case .tabClose: return named("tab close")
    case .find: return named("app find")
    case .findNext: return named("app find_next")
    case .findPrevious: return named("app find_previous")
    case .appSwitch: return named("app switch")
    case .flashlight(let query, let restoreMode):
      var args: [String] = []
      if let query { args.append(kv("query", query)) }
      if restoreMode { args.append(flag("restore-mode")) }
      return named("mode flashlight", args)
    case .enterCommand(let input, let restoreMode):
      var args = [kv("input", input)]
      if restoreMode { args.append(flag("restore-mode")) }
      return named("mode command", args)
    case .copyURL: return named("url copy")
    case .yankSelection(let register):
      if let register { return named("register yank", [kv("register", register)]) }
      return named("register yank")
    case .paste(let register, let after):
      let flags = after ? [flag("after")] : []
      if let register { return named("register paste", [kv("register", register)] + flags) }
      return named("register paste", flags)
    case .tabNext: return named("tab next")
    case .tabPrev: return named("tab previous")
    case .tabFirst: return named("tab first")
    case .tabLast: return named("tab last")
    case .tabSelect(let index):
      if let index { return named("tab select", [kv("index", index)]) }
      return named("tab select")
    case .tabMovePrev: return named("tab move_previous")
    case .tabMoveNext: return named("tab move_next")
    case .tabReopen: return named("tab reopen")
    case .paneNext: return named("pane next")
    case .panePrev: return named("pane previous")
    case .paneSplitVertical: return named("pane split_vertical")
    case .paneSplitHorizontal: return named("pane split_horizontal")
    case .paneClose: return named("pane close")
    case .historyBack: return named("history back")
    case .historyForward: return named("history forward")
    case .movementBack: return named("movement back")
    case .movementForward: return named("movement forward")
    case .appPrev: return named("app previous")
    case .appNext: return named("app next")
    case .quitApp(let force):
      return force ? named("app quit", [flag("force")]) : named("app quit")
    case .saveAndQuit(let force):
      return force ? named("app save_and_quit", [flag("force")]) : named("app save_and_quit")
    case .appClose: return named("app close")
    case .tabNew: return named("tab new")
    case .save: return named("app save")
    case .print: return named("app print")
    case .documentOpen: return named("document open")
    case .windowNew(let isPrivate):
      return isPrivate ? named("window new", [flag("private")]) : named("window new")
    case .windowCloseAll: return named("window close_all")
    case .windowZoom: return named("window zoom")
    case .documentSaveAs: return named("document save_as")
    case .documentExportPDF: return named("document export_pdf")
    case .documentRevert: return named("document revert")
    case .documentDuplicate: return named("document duplicate")
    case .documentRename: return named("document rename")
    case .documentPageSetup: return named("document page_setup")
    case .appSettings: return named("app settings")
    case .selectAll: return named("app select_all")
    case .appHelp: return named("app help")
    case .appCancel: return named("app cancel")
    case .appStop: return named("app stop")
    case .appDownloads: return named("app downloads")
    case .developerTools: return named("app developer_tools")
    case .appVisibility(let action): return named("app \(action.rawValue)")
    case .urlBookmark: return named("url bookmark")
    case .urlEdit: return named("url edit")
    case .historyShow: return named("history show")
    case .tabDuplicate: return named("tab duplicate")
    case .tabPin: return named("tab pin")
    case .tabMute: return named("tab mute")
    case .tabDetach: return named("tab detach")
    case .menuPress(let path): return named("menu press", [kv("path", path.joined(separator: ","))])
    case .windowClose: return named("window close")
    case .windowSwitch: return named("window switch")
    case .windowLast: return named("window last")
    case .tile(let command):
      switch command {
      case .move(let direction): return named("tile move", [kv("direction", direction.rawValue)])
      case .swap(let direction): return named("tile swap", [kv("direction", direction.rawValue)])
      case .join(let direction): return named("tile join", [kv("direction", direction.rawValue)])
      case .layout(let request): return named("tile layout", [kv("type", request.rawValue)])
      case .resize(let dimension, let amount):
        return named("tile resize", [kv("dimension", dimension.rawValue), kv("amount", amount)])
      case .balance: return named("tile balance")
      case .flatten: return named("tile flatten")
      case .float: return named("tile float")
      case .fullscreen: return named("tile fullscreen")
      }
    case .workspace(let command):
      switch command {
      case .switchTo(let name): return named("workspace switch", [kv("name", name)])
      case .next: return named("workspace next")
      case .previous: return named("workspace previous")
      case .backAndForth: return named("workspace back_and_forth")
      case .moveWindow(let name): return named("workspace move_window", [kv("name", name)])
      case .moveToMonitor(let step):
        return named(
          "workspace move_to_monitor", [kv("direction", step > 0 ? "next" : "previous")])
      case .list: return named("workspace list")
      }
    case .clipboardCopy: return named("clipboard copy")
    case .clipboardPaste: return named("clipboard paste")
    case .clipboardHistory(let action, let id, let offset):
      var parts: [String] = []
      if let id { parts.append(kv("id", id)) }
      if let offset { parts.append(kv("offset", offset)) }
      return named("clipboard \(action)", parts)
    case .clipboardRestore(let id, let paste, let plain):
      var parts = [kv("id", id)]
      if paste { parts.append(flag("paste")) }
      if plain { parts.append(flag("plain")) }
      return named("clipboard restore", parts)
    case .lookUp: return named("app look_up")
    case .zoomIn: return named("app zoom_in")
    case .zoomOut: return named("app zoom_out")
    case .zoomReset: return named("app zoom_reset")
    case .viewSource: return named("app view_source")
    case .trackpadGesture(let fingers, let motion):
      return named("mouse gesture", ["--fingers=\(fingers)", "--motion=\(motion.rawValue)"])
    case .showAlert(let alert): return named("alert show", alert.argTokens)
    case .dismissAlert: return named("alert dismiss")
    case .confirm(let request):
      return named(
        "alert confirm", [kv("prompt", request.prompt), kv("command", request.commandText)])
    case .showUsage(let topic):
      if let topic, !topic.isEmpty { return named("help show", [kv("topic", topic)]) }
      return named("help show")
    case .showMappings:
      return named("mappings show")
    case .showPlugins: return named("plugins show")
    case .reloadPlugins: return named("plugins reload")
    case .showLogs: return named("logs show")
    case .showCommands: return named("commands show")
    case .showMonitors: return named("monitors show")
    case .showTelemetry: return named("telemetry show")
    case .showAbout: return named("about show")
    case .dismissHints: return named("hints dismiss")
    case .quit: return named("resident quit")
    case .openApp(let name): return named("app open", [kv("name", name)])
    case .pluginCommand(let command, let subcommand, let args):
      return ["flash", command, subcommand] + args
    case .moveWindow(let params):
      var parts: [String] = []
      switch params.layout {
      case .position(let position):
        parts.append(kv("position", position.rawValue))
      case .proportional(let frame):
        parts.append(kv("x", percentage(frame.xPercent)))
        parts.append(kv("y", percentage(frame.yPercent)))
        parts.append(kv("width", percentage(frame.widthPercent)))
        parts.append(kv("height", percentage(frame.heightPercent)))
      case nil:
        break
      }
      parts.append(kv("screen", params.screen))
      return named("window move", parts)
    case .windowState(let action):
      switch action {
      case .minimize: return named("window minimize")
      case .restore: return named("window restore")
      case .fullscreen(let state):
        return state == .toggle
          ? named("window fullscreen")
          : named("window fullscreen", [kv("state", state.rawValue)])
      }
    case .focusWindow(.direction(let direction)):
      return named("window focus", [kv("direction", direction.rawValue)])
    case .focusWindow(.cycle(let cycle)):
      return named("window focus", [kv("direction", cycle.rawValue)])
    case .focusWindow(.app(let cycle)):
      return named("window \(cycle.rawValue)")
    case .caffeinate(let request):
      return named(request.name.description, request.argTokens)
    case .statusPush(let push):
      return named(push.name.description, push.argTokens)
    case .statusRefresh(let source):
      return named(StatusRefresh.name.description, ["--name=\(source)"])
    case .notify(let command):
      return named(command.name.description, command.argTokens)
    case .logWrite(let write):
      return named("logs write", write.argTokens)
    case .metricRecord(let record):
      return named("metrics record", record.argTokens)
    case .menuChoose(let file, let prompt):
      return named(
        MenuChoice.name.description, ["--file=\(file)"] + (prompt.map { ["--prompt=\($0)"] } ?? []))
    case .macro(let command):
      return named(command.name.description, command.argTokens)
    case .configReload:
      return named("config reload")
    case .configEdit:
      return named("config edit")
    case .startup(let command):
      return named(command.name.description)
    case .updates(let command):
      return named(command.name.description)
    case .appleCatalog(let command):
      return named(command.name.description)
    case .calendar(let command):
      return named(command.name.description)
    case .marks(let command):
      return named(command.name.description, command.argTokens)
    case .systemKey(let key):
      return named("key system", [kv("key", key.rawValue)])
    case .systemSurface(let command):
      return named(command.name.description)
    case .systemAction(let action):
      return named(action.name.description)
    case .processKill(let pid):
      return named("process kill", [kv("pid", Int(pid))])
    case .functionKey(let index):
      return named("key function", [kv("key", "f\(index)")])
    case .arrow(let direction, let shift):
      let args = [kv("direction", direction.rawValue)]
      return shift ? named("key arrow", args + [flag("shift")]) : named("key arrow", args)
    case .sendKey(let keys, _, _):
      return named("key send", [kv("keys", keys)])
    case .sendKeys(let keys, _, _):
      return named("key sequence", [kv("keys", keys)])
    }
  }

  /// Space-joined `argv` for help text, logs, and the mappings list.
  /// Never re-parsed: splitting it breaks a value that contains a space.
  var diagnosticDescription: String {
    argv.joined(separator: " ")
  }
}

extension MouseCommand {
  /// Arg tokens for `mouse target` / `mouse grid` in diagnostic form.
  /// Empty for a plain left-click, `["--secondary"]` for right-click,
  /// `["--middle"]` for middle-click, `["--double"]` / `["--triple"]` for
  /// multi-clicks, `["--move"]` for cursor-only move, with an optional
  /// `--modifiers=…` suffix for a preset modified click.
  var argTokens: [String] {
    switch self {
    case .move:
      return ["--move"]
    case .copyURL:
      return ["--copy-url"]
    case .copyText:
      return ["--copy-text"]
    case .gesture(let gesture):
      return ["--gesture=\(gesture.rawValue)"]
    case .drag(let modifiers):
      var tokens = ["--drag"]
      if !modifiers.isEmpty {
        tokens.append("--modifiers=\(modifiers.argumentValue)")
      }
      return tokens
    case .select(let modifiers):
      var tokens = ["--select"]
      if !modifiers.isEmpty {
        tokens.append("--modifiers=\(modifiers.argumentValue)")
      }
      return tokens
    case .multi(let action, let modifiers), .adjust(let action, let modifiers),
      .search(let action, let modifiers), .path(let action, let modifiers),
      .sticky(let action, let modifiers):
      let session: String
      switch self {
      case .multi: session = "--multi"
      case .adjust: session = "--adjust"
      case .path: session = "--path"
      case .sticky: session = "--sticky"
      default: session = "--search"
      }
      var tokens = [session]
      switch action {
      case .leftClick: break
      case .rightClick: tokens.append("--secondary")
      case .middleClick: tokens.append("--middle")
      case .doubleClick: tokens.append("--double")
      case .tripleClick: tokens.append("--triple")
      }
      if !modifiers.isEmpty {
        tokens.append("--modifiers=\(modifiers.argumentValue)")
      }
      return tokens
    case .click(let action, let modifiers):
      var tokens: [String]
      switch action {
      case .leftClick: tokens = []
      case .rightClick: tokens = ["--secondary"]
      case .middleClick: tokens = ["--middle"]
      case .doubleClick: tokens = ["--double"]
      case .tripleClick: tokens = ["--triple"]
      }
      if !modifiers.isEmpty {
        tokens.append("--modifiers=\(modifiers.argumentValue)")
      }
      return tokens
    }
  }
}
