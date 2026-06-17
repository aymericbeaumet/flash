import AppKit
import Carbon.HIToolbox
import FlashCore

// Resident-side AppleEvent handler for commands sent in by the `flash` CLI
// (see `Sources/flash/FlashCLI.swift`). Replaces the old `flash://` URL
// scheme entirely: any sender that wants to drive Flash from outside the
// process now constructs a custom AppleEvent (class `Flsh`, ID `Cmd `)
// with a verb string and a JSON-encoded args dictionary. The URL surface
// no longer exists, so drive-by browser navigations can't reach this
// path — sending the event requires either the matching code identity
// (the CLI sibling of the resident) or explicit `osascript` on the user's
// own machine.
//
// The same verb table is consulted by mapping config: a TOML entry like
// `"f" = ["flash", "mouse_target"]` is parsed at load time by feeding the
// remainder of the array through `CommandEventHandler.parse(verb:args:)`,
// so the in-process path and the AppleEvent path share one source of
// truth.

enum URLCommand: Hashable {
  case mouseTarget(MouseCommand)
  case mouseGrid(MouseCommand)
  case normalMode
  case insertMode
  case commandMode
  case scroll(NormalModeDispatcher.ScrollKind)
  case reload(force: Bool)
  case undo
  case redo
  case archive
  case resourceNext
  case resourcePrevious
  case close
  case tabClose
  case find
  case candidateFinder(all: Bool)
  /// Open command-line mode pre-seeded with `input`. `restoreMode` is set
  /// when the mapping carries `--restore-mode`; on exit (submit or cancel)
  /// the command-line dismiss restores whichever mode was active when the
  /// verb fired instead of bouncing the user to normal. Use case:
  /// `["flash", "enter_command_mode", "--input=:flashlight @source:emojis.glyphs",
  /// "--restore-mode"]` fired from insert mode opens the flashlight scoped
  /// to the emoji source and returns the user to insert after the chosen
  /// glyph lands.
  case enterCommand(input: String, restoreMode: Bool)
  case copyURL
  case tabNext
  case tabPrev
  case tabFirst
  case tabLast
  case tabSelect(index: Int?)
  case tabMovePrev
  case tabMoveNext
  case tabReopen
  case historyBack
  case historyForward
  case movementBack
  case movementForward
  case appPrev
  case appNext
  case quitApp(force: Bool)
  case saveAndQuit(force: Bool)
  case tabNew
  case showAlert(AlertCommand)
  case dismissAlert
  case showUsage(topic: String?)
  case showPlugins
  case dismissHints
  case quit
  case openApp(name: String)
  case pluginCommand(command: String, subcommand: String, args: [String])
  case moveWindow(MoveWindowParams)
  case sendKey(keys: String, keyCode: CGKeyCode, flagsRawValue: UInt64)
  /// A verb registered by a plugin via the manifest's `verbs.items` section.
  /// The host doesn't know the verb's semantics — it just forwards the call
  /// to ``PluginManager/invokeVerb(name:args:in:onResult:)`` (which
  /// may shortcut directly for inline-keystrokes verbs, or fan
  /// out to the owning plugin's `command.invoke`).
  case pluginVerb(name: String, args: [String: String])
}

struct AlertCommand: Hashable {
  enum Style: String, Hashable {
    case standard
    case error
  }

  let message: String
  let duration: TimeInterval?
  let style: Style

  var argTokens: [String] {
    var tokens = ["--message=\(message)"]
    if let duration {
      tokens.append("--duration=\(duration)")
    }
    if style != .standard {
      tokens.append("--style=\(style.rawValue)")
    }
    return tokens
  }
}

enum MouseCommand: Hashable {
  case click(JumpAction)
  case move

  var action: JumpAction {
    switch self {
    case .click(let action): return action
    case .move: return .leftClick
    }
  }

  var isMove: Bool {
    if case .move = self { return true }
    return false
  }
}

/// Named positions for `flash window_move position=…`. Each value maps the
/// focused window to a fixed slot of the target screen's Flash-usable
/// frame: `visibleFrame` plus Flash's own top status-bar reservation
/// folded in so a slot's height is the height the user actually sees.
///
/// Two sub-namespaces of moves are encoded as one enum:
///
/// - `position` (optional): named slot of the target screen's
///   Flash-usable frame. When omitted, the window keeps its shape and
///   is only translated (proportionally remapped) onto the target
///   screen.
/// - `screen` (optional): relative monitor offset. `0` (or omitted)
///   stays on the window's current screen. `+N` / `-N` cycle forward
///   / backward through `NSScreen.screens` with modulo wrap.
///
/// The parser rejects the empty form (`flash window_move`) so a mapping
/// that forgot both keys fails at config load instead of firing a silent
/// no-op on every press.
struct MoveWindowParams: Hashable {
  let position: WindowPosition?
  let screen: Int
}

final class URLEventHandler: NSObject {
  private let handler: (URLCommand) -> Void

  init(handler: @escaping (URLCommand) -> Void) {
    self.handler = handler
    super.init()
    NSAppleEventManager.shared().setEventHandler(
      self,
      andSelector: #selector(handleFlashEvent(_:withReplyEvent:)),
      forEventClass: FlashCLI.appleEventClass,
      andEventID: FlashCLI.appleEventID
    )
  }

  @objc func handleFlashEvent(
    _ event: NSAppleEventDescriptor,
    withReplyEvent reply: NSAppleEventDescriptor
  ) {
    guard
      let verb = event.paramDescriptor(forKeyword: FlashCLI.verbKey)?.stringValue,
      !verb.isEmpty
    else { return }
    let argsJSON = event.paramDescriptor(forKeyword: FlashCLI.argsKey)?.stringValue ?? "{}"
    // CLI / AppleEvent path uses `parseOrPluginVerb` so a `flash <verb>`
    // call can reach plugin-registered verbs. Config-load goes through
    // strict `parse` instead, so a stale verb in `[mode.*.mappings]`
    // still surfaces as a config error rather than a silent runtime miss.
    guard let cmd = Self.parseOrPluginVerb(verb: verb, args: Self.decodeArgs(json: argsJSON)) else {
      return
    }
    handler(cmd)
  }

  /// Look up a verb in the dispatch table and turn its args dict into a
  /// resolved ``URLCommand``. Returns nil for unknown verbs or for verbs
  /// whose required parameters are missing/invalid — callers (the AE
  /// handler, the mapping config loader) treat nil as "ignore" and emit a
  /// diagnostic where appropriate.
  ///
  /// Strict by design: plugin-registered verbs are NOT resolved here so the
  /// mapping/CLI parsers reject stale verbs at config-load time. Runtime
  /// dispatch entry points use ``parseOrPluginVerb(verb:args:)`` to fall
  /// back to a ``URLCommand/pluginVerb(name:args:)`` when the built-in table
  /// misses but the name looks like a plugin verb.
  static func parse(verb: String, args: [String: String]) -> URLCommand? {
    guard let parser = Self.commands[verb] else { return nil }
    return parser(VerbArgs(args: args))
  }

  /// Same as ``parse(verb:args:)`` but, on a built-in miss for an
  /// identifier-shape verb, returns a ``URLCommand/pluginVerb(name:args:)``
  /// so the dispatch path can hand the call to ``PluginManager``. Used by
  /// the AppleEvent handler — config validation stays on `parse(verb:args:)`
  /// so stale verbs surface a clear failure instead of silently turning
  /// into no-op plugin calls.
  static func parseOrPluginVerb(verb: String, args: [String: String]) -> URLCommand? {
    if let cmd = Self.parse(verb: verb, args: args) {
      return cmd
    }
    if Self.looksLikePluginVerb(verb) {
      return .pluginVerb(name: verb, args: args)
    }
    return nil
  }

  /// Identifier-shape predicate for unknown verbs that should be routed to
  /// plugins rather than rejected outright. Mirrors the lexical rule the
  /// rest of the configuration uses (plugin ids, command names): one
  /// lowercase letter or underscore followed by lowercase letters, digits,
  /// and underscores. Anything else (uppercase, dashes, punctuation,
  /// whitespace) is rejected so a config typo doesn't quietly become a
  /// plugin call.
  private static func looksLikePluginVerb(_ verb: String) -> Bool {
    guard let first = verb.unicodeScalars.first else { return false }
    let head = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz_")
    let tail = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
    guard head.contains(first) else { return false }
    return verb.unicodeScalars.dropFirst().allSatisfy { tail.contains($0) }
  }

  /// JSON object → `[String: String]`. Non-string values are stringified so
  /// numeric `index=1` round trips cleanly without a typed schema.
  private static func decodeArgs(json: String) -> [String: String] {
    guard
      let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    var out: [String: String] = [:]
    for (key, value) in object {
      if let string = value as? String {
        out[key] = string
      } else if let bool = value as? Bool {
        out[key] = bool ? "true" : "false"
      } else {
        out[key] = String(describing: value)
      }
    }
    return out
  }

  /// Dispatch table keyed by verb name. Adding a new verb is a two-step
  /// change: add a case to `URLCommand`, then add the parser closure here.
  /// `AppDelegate` switches exhaustively over `URLCommand` so the compiler
  /// flags any missed wiring.
  private static let commands: [String: (VerbArgs) -> URLCommand?] = [
    "mouse_target": { a in mouseCommand(a).map(URLCommand.mouseTarget) },
    "mouse_grid": { a in mouseCommand(a).map(URLCommand.mouseGrid) },
    "mouse_snipe": { a in mouseCommand(a).map(URLCommand.mouseGrid) },
    "mouse_click": { a in mouseCommand(a).map(URLCommand.mouseTarget) },
    "enter_normal_mode": { _ in .normalMode },
    "enter_insert_mode": { _ in .insertMode },
    "enter_command_mode": { a in
      guard let raw = a.value("input") else {
        return a.args.isEmpty ? .commandMode : nil
      }
      guard !raw.isEmpty else { return nil }
      // Strip every leading `:` and feed the rest through verbatim. A single
      // `:` is later prepended by `commandLineBuffer(from:)`. Trailing spaces
      // are meaningful and must NOT be trimmed: `--input=:flashlight ` opens
      // the flashlight verb with an empty query (all candidates) while
      // `--input=:flashlight` instead surfaces completions for commands that
      // start with `flashlight`. The user gets full control over which
      // behaviour they want.
      let normalized = String(raw.drop(while: { $0 == ":" }))
      return .enterCommand(input: normalized, restoreMode: a.bool("restore_mode"))
    },
    "scroll_left": { _ in .scroll(.left) },
    "scroll_right": { _ in .scroll(.right) },
    "scroll_up": { _ in .scroll(.up) },
    "scroll_down": { _ in .scroll(.down) },
    "scroll_half_page_up": { _ in .scroll(.halfPageUp) },
    "scroll_half_page_down": { _ in .scroll(.halfPageDown) },
    "scroll_top": { _ in .scroll(.top) },
    "scroll_bottom": { _ in .scroll(.bottom) },
    "app_reload": { a in .reload(force: a.bool("force")) },
    "app_undo": { _ in .undo },
    "app_redo": { _ in .redo },
    "resource_archive": { _ in .archive },
    "resource_next": { _ in .resourceNext },
    "resource_previous": { _ in .resourcePrevious },
    "window_close": { _ in .close },
    "tab_close": { _ in .tabClose },
    "app_find": { _ in .find },
    "app_open_finder": { a in .candidateFinder(all: a.bool("all")) },
    "url_copy": { _ in .copyURL },
    "tab_next": { _ in .tabNext },
    "tab_previous": { _ in .tabPrev },
    "tab_first": { _ in .tabFirst },
    "tab_last": { _ in .tabLast },
    "tab_select": { a in .tabSelect(index: a.int("index")) },
    "tab_move_previous": { _ in .tabMovePrev },
    "tab_move_next": { _ in .tabMoveNext },
    "tab_reopen": { _ in .tabReopen },
    "history_back": { _ in .historyBack },
    "history_forward": { _ in .historyForward },
    "movement_back": { _ in .movementBack },
    "movement_forward": { _ in .movementForward },
    "app_previous": { _ in .appPrev },
    "app_next": { _ in .appNext },
    "app_quit": { a in .quitApp(force: a.bool("force")) },
    "app_save_and_quit": { a in .saveAndQuit(force: a.bool("force")) },
    "tab_new": { _ in .tabNew },
    "alert_show": { alertCommand($0) },
    "alert_dismiss": { _ in .dismissAlert },
    "help_show": { a in .showUsage(topic: a.value("topic")) },
    "plugins": { _ in .showPlugins },
    "hints_dismiss": { _ in .dismissHints },
    "quit": { _ in .quit },
    "app_open": { a in
      guard let name = a.value("name"), !name.isEmpty else { return nil }
      return .openApp(name: name)
    },
    "plugin_command": { a in
      guard let command = a.value("command"), !command.isEmpty,
        let subcommand = a.value("subcommand"), !subcommand.isEmpty
      else { return nil }
      let args =
        a.value("args")?
        .split(separator: " ", omittingEmptySubsequences: true)
        .map(String.init) ?? []
      return .pluginCommand(command: command, subcommand: subcommand, args: args)
    },
    "window_move": windowMoveCommand,
    "send_key": sendKeyCommand,
  ]

  static let usageText = """
    flash mouse_target [--secondary|--double|--move]
    flash mouse_grid [--secondary|--double|--move]
    flash enter_normal_mode
    flash enter_insert_mode
    flash enter_command_mode
    flash scroll_left
    flash scroll_right
    flash scroll_up
    flash scroll_down
    flash scroll_half_page_up
    flash scroll_half_page_down
    flash scroll_top
    flash scroll_bottom
    flash app_reload [--force]
    flash app_undo
    flash app_redo
    flash resource_archive
    flash resource_next
    flash resource_previous
    flash window_close
    flash tab_close
    flash app_find
    flash app_open_finder [--all]
    flash enter_command_mode --input='<text>' [--restore-mode]
    flash url_copy
    flash tab_next
    flash tab_previous
    flash tab_first
    flash tab_last
    flash tab_select --index=<n>
    flash tab_move_previous
    flash tab_move_next
    flash tab_reopen
    flash history_back
    flash history_forward
    flash movement_back
    flash movement_forward
    flash app_previous
    flash app_next
    flash app_quit [--force]
    flash app_save_and_quit [--force]
    flash tab_new
    flash alert_show --message=<text> [--duration=<seconds>] [--style=standard|error]
    flash alert_dismiss
    flash hints_dismiss
    flash app_open --name=<app>
    flash window_move --position=<slot> --screen=<n>
    flash quit
    flash help_show [--topic=<topic>]
    flash plugins
    flash plugin_command --command=<command> --subcommand=<subcommand> [--args=<space-separated>]
    """
}

extension URLEventHandler {
  static let helpTopic = HelpTopic(
    name: "verbs",
    title: "Flash verbs",
    summary: "Verbs accepted by the `flash` CLI and by mapping config.",
    body: """
      # Flash verbs

      Every resident action has a verb name. The same verb table is used by
      the `flash` CLI (which AppleEvents the verb to the resident) and by
      mapping config (which writes `["flash", "<verb>", "key=value", ...]`
      arrays and resolves them in-process).

      `mouse_target` selects an app-discovered target. `mouse_grid` selects
      a precise screen position by repeatedly narrowing a deterministic
      grid.

      ```text
      \(URLEventHandler.usageText)
      ```
      """)
}

/// Args bag for a verb dispatch. Constructed from the JSON dictionary on
/// the AppleEvent payload (CLI path) or from a mapping array's `k=v`
/// tail (config path). The few `bool` / `int` accessors keep the
/// dispatch table tight.
struct VerbArgs {
  let args: [String: String]
  func value(_ name: String) -> String? {
    args[name]
  }
  func bool(_ name: String) -> Bool {
    let v = args[name]
    return v == "1" || v == "true"
  }
  func int(_ name: String) -> Int? {
    args[name].flatMap(Int.init)
  }
}

private func alertCommand(_ a: VerbArgs) -> URLCommand? {
  guard let message = a.value("message"), !message.isEmpty else { return nil }

  let duration: TimeInterval?
  if let rawDuration = a.value("duration") {
    guard
      let parsed = TimeInterval(rawDuration),
      parsed.isFinite,
      parsed > 0
    else {
      return nil
    }
    duration = parsed
  } else {
    duration = nil
  }

  let styleRaw = a.value("style") ?? AlertCommand.Style.standard.rawValue
  guard let style = AlertCommand.Style(rawValue: styleRaw) else { return nil }
  return .showAlert(AlertCommand(message: message, duration: duration, style: style))
}

private func mouseCommand(_ a: VerbArgs) -> MouseCommand? {
  if a.bool("move") { return .move }
  let secondary = a.bool("secondary")
  let double = a.bool("double")
  if secondary && double { return nil }
  if secondary { return .click(.rightClick) }
  if double { return .click(.doubleClick) }
  return .click(.leftClick)
}

/// `flash send_key keys=<hotkey>` synthesizes one modified keystroke to
/// the focused app. `keys` uses the exact same syntax as a config hotkey
/// (`cmd+option+r`, `shift+tab`, `0x24`), so a plugin can override a
/// built-in keystroke (e.g. Safari's hard refresh is `cmd+option+r`, not
/// the default `cmd+shift+r`) just by registering an app-scoped mapping
/// that points here. Rejected at parse time when `keys` is missing or
/// unparseable.
private func sendKeyCommand(_ a: VerbArgs) -> URLCommand? {
  guard let keys = a.value("keys"), let parsed = HotkeySyntax.parse(hotkey: keys) else {
    return nil
  }
  return .sendKey(
    keys: keys,
    keyCode: CGKeyCode(parsed.virtualKey),
    flagsRawValue: cgEventFlags(carbon: parsed.modifiers).rawValue)
}

/// Translate Carbon modifier flags (as `HotkeySyntax` emits) into the
/// `CGEventFlags` the synthesizer consumes.
private func cgEventFlags(carbon: UInt32) -> CGEventFlags {
  var flags: CGEventFlags = []
  if carbon & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
  if carbon & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
  if carbon & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
  if carbon & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
  return flags
}

private func windowMoveCommand(_ a: VerbArgs) -> URLCommand? {
  let rawPosition = a.value("position")
  let rawScreen = a.value("screen")
  // Empty form `flash window_move` is a no-op mapping — flag it at
  // config load so the user can't mis-write a hotkey.
  if rawPosition == nil && rawScreen == nil { return nil }
  // A *typo'd* position (e.g. `position=foo`) is rejected too; we
  // don't want to silently degrade to "just move screen".
  var position: WindowPosition? = nil
  if let raw = rawPosition {
    guard let p = WindowPosition(rawValue: raw.lowercased()) else {
      return nil
    }
    position = p
  }
  // Swift's Int(_:) already accepts a leading "+" or "-", so
  // `screen=+1` and `screen=-1` round-trip without a custom sign
  // parser. A non-numeric `screen=` value is rejected.
  let screen: Int
  if let raw = rawScreen {
    guard let n = Int(raw) else { return nil }
    screen = n
  } else {
    screen = 0
  }
  return .moveWindow(MoveWindowParams(position: position, screen: screen))
}

/// `WindowPosition` is also referenced by `WindowMover`. Keep its
/// declaration near `URLCommand`/`MoveWindowParams` so they live in one
/// file.
enum WindowPosition: String, Hashable {
  case topLeft = "topleft"
  case topRight = "topright"
  case bottomLeft = "bottomleft"
  case bottomRight = "bottomright"
  case leftHalf = "lefthalf"
  case rightHalf = "righthalf"
  case topHalf = "tophalf"
  case bottomHalf = "bottomhalf"
  case maximized = "maximized"
  case centered = "centered"
}
