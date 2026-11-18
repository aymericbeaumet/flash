import AppKit
import FlashCore

/// The pointer, hints and scrolling: `mouse`, `hints`, `selection`, `scroll`, `move`,
/// `mark` and `movement`.
extension URLEventHandler {
  static let pointerCommands: [String: CommandDefinition] = [
    "mouse target": .init(
      "Label the focused window's targets and click the one you pick",
      mouseParameters + [.text("scope", "app|screen"), .flag("words")],
      parse: { a in
        if a.bool("words") {
          // Words are a text walk: the session shapes that walk the app's
          // controls again (`--multi`) or filter by control text do not apply.
          guard a.value("scope") == nil, let command = mouseCommand(a) else { return nil }
          switch command {
          case .click, .move, .gesture, .drag, .select: return .mouseTargetWords(command)
          default: return nil
          }
        }
        switch a.value("scope") {
        case nil, "app":
          return mouseCommand(a).map(URLCommand.mouseTarget)
        case "screen":
          // Screen scope is click-only: session flags (drag/select/multi/…)
          // assume a single-app session.
          guard let command = mouseCommand(a), case .click = command else { return nil }
          return .mouseTargetScreen(command)
        default:
          return nil
        }
      }),
    "mouse screens": .init(
      "Label each display by its number and move the pointer to the one you pick",
      [
        .integer("index"), .text("direction", "next|previous"), .text("to", "center|last"),
        .flag("focus"),
      ],
      parse: { a in screenSelectCommand(a) }),
    "mouse warp": .init(
      "Move the pointer to an edge or the centre of the window or screen",
      [.text("area", "window|screen"), .text("edge", "center|top|bottom|left|right")],
      parse: { a in
        var request = MouseWarpRequest()
        if let area = a.value("area") {
          guard let parsed = MouseWarpRequest.Area(rawValue: area) else { return nil }
          request.area = parsed
        }
        if let edge = a.value("edge") {
          guard let parsed = MouseWarpRequest.Edge(rawValue: edge) else { return nil }
          request.edge = parsed
        }
        return .mouseWarp(request)
      }),
    "mouse step": .init(
      "Move the pointer one text line or character, or jump a word or line",
      [
        .text("direction", "up|down|left|right"),
        .text("to", "next_word|previous_word|word_end|line_start|line_end"),
      ],
      parse: { a in
        // Exactly one of a one-step direction or a jump.
        switch (a.value("direction"), a.value("to")) {
        case (let direction?, nil):
          return TextStep.Direction(rawValue: direction).map { .mouseStep($0) }
        case (nil, let to?):
          return TextStep.Jump(rawValue: to).map { .mouseJump($0) }
        case (_?, _?), (nil, nil):
          return nil
        }
      }),
    "selection copy": selectionCommand(.copy, "Copy the selected text, ending HOLD or VISUAL"),
    "selection paste": selectionCommand(
      .paste, "Paste over the selected text, ending HOLD or VISUAL"),
    "selection swap_ends": selectionCommand(
      .swapEnds, "Move VISUAL's moving end to the other end of the selection (o)"),
    "mouse nudge": .init(
      "Move the pointer, and a held drag, a few points",
      [.text("direction", "up|down|left|right", required: true), .text("distance", "points")],
      parse: { a in
        guard let direction = a.value("direction").flatMap(TextStep.Direction.init(rawValue:))
        else { return nil }
        guard let raw = a.value("distance") else { return .mouseNudge(direction, distance: 16) }
        guard let distance = Int(raw), (1...2000).contains(distance) else { return nil }
        return .mouseNudge(direction, distance: distance)
      }),
    "mouse position": .init(
      "Save, label, cycle or forget saved pointer positions",
      [.text("action", "save|unsave|clear|hints|next|previous", required: true)]
        + clickParameters,
      parse: { a in
        let clickArgs = a.args.filter { $0.key != "action" }
        switch a.value("action") {
        case "save": return clickArgs.isEmpty ? .mousePosition(.save) : nil
        case "unsave": return clickArgs.isEmpty ? .mousePosition(.unsave) : nil
        case "clear": return clickArgs.isEmpty ? .mousePosition(.clear) : nil
        case "next": return clickArgs.isEmpty ? .mousePosition(.next) : nil
        case "previous": return clickArgs.isEmpty ? .mousePosition(.previous) : nil
        case "hints":
          guard let command = mouseCommand(a, allowAdjust: false) else { return nil }
          switch command {
          case .click, .move: return .mousePosition(.hints(command))
          default: return nil
          }
        default: return nil
        }
      }),
    // The grid IS the precision surface, so `--adjust` and `--search` are
    // config errors there.
    "mouse bigram": .init(
      "Type a visible character, then its hint, and click that glyph",
      [
        .flag("secondary"), .flag("double"), .flag("middle"), .flag("triple"),
        .flag("move"), .text("gesture", "look_up|smart_zoom"),
        .text("modifiers", "cmd+ctrl+alt+shift"),
      ],
      parse: { a in
        guard let command = mouseCommand(a, allowAdjust: false) else { return nil }
        switch command {
        case .click, .move, .gesture: return .mouseBigram(command)
        default: return nil
        }
      }),
    "mouse grid": .init(
      "Pick any screen position on a keyboard-shaped grid",
      mouseParameters.filter { !targetSessionFlags.contains($0.name) }
        + [.flag("bisect"), .integer("zoom_to_depth")],
      parse: { a in
        mouseCommand(a, allowAdjust: false).map {
          .mouseGrid(
            MouseGridRequest($0, zoomToDepth: a.int("zoom_to_depth"), bisect: a.bool("bisect")))
        }
      }),
    "mouse repeat": .init(
      "Click again where Flash last clicked", parse: { a in a.args.isEmpty ? .mouseRepeat : nil }),
    "mouse pointer": .init(
      "Move the pointer from the keyboard", parse: { a in a.args.isEmpty ? .mousePointer : nil }),
    "mouse button": .init(
      "Press, release or toggle a mouse button at the pointer",
      [
        .text("state", "down|up|toggle|release|cancel", required: true), .flag("secondary"),
        .flag("middle"), .text("mode", "hold"),
      ],
      parse: { a in
        guard let state = a.value("state").flatMap(MouseButtonState.init(rawValue:)) else {
          return nil
        }
        let hold: ButtonHold
        if let mode = a.value("mode") {
          guard let parsed = ButtonHold(rawValue: mode) else { return nil }
          hold = parsed
        } else {
          hold = .hold
        }
        switch (a.bool("secondary"), a.bool("middle")) {
        case (false, false): return .mouseButton(.init(state: state, button: .primary, hold: hold))
        case (true, false):
          return .mouseButton(.init(state: state, button: .secondary, hold: hold))
        case (false, true): return .mouseButton(.init(state: state, button: .middle, hold: hold))
        case (true, true): return nil
        }
      }),
    "move down": move(.down, "Move down: the caret in text, the selection in a list, else scroll"),
    "move up": move(.up, "Move up: the caret in text, the selection in a list, else scroll"),
    "move left": move(
      .left, "Move left: the caret within its line, the selection in a list, else scroll"),
    "move right": move(
      .right, "Move right: the caret within its line, the selection in a list, else scroll"),
    "move half_page_down": move(
      .halfPageDown, "Move down by [mode] move_page_lines arrows, or scroll half a page"),
    "move half_page_up": move(
      .halfPageUp, "Move up by [mode] move_page_lines arrows, or scroll half a page"),
    "move page_down": move(.pageDown, "Move down by twice move_page_lines arrows, or a page"),
    "move page_up": move(.pageUp, "Move up by twice move_page_lines arrows, or a page"),
    "move top": move(
      .top, "Move to the start of the text, the first item where the app says, or the top"),
    "move bottom": move(
      .bottom, "Move to the end of the text, the last item where the app says, or the bottom"),
    "scroll target": .init(
      "Pick the scroll area the scroll commands drive",
      parse: { a in a.args.isEmpty ? .scrollTarget : nil }),
    "mouse dock": .init(
      "Label the Dock's items", parse: { a in a.args.isEmpty ? .mouseDock : nil }),
    "mouse menubar": .init(
      "Label the focused app's menus and the menu-bar status items",
      parse: { a in a.args.isEmpty ? .mouseMenuBar : nil }),
    "mouse notifications": .init(
      "Label Notification Center's banners, alerts and buttons",
      parse: { a in a.args.isEmpty ? .mouseNotifications : nil }),
    "scroll left": .init(
      "Scroll left", parse: { _ in .scroll(.left) }),
    "scroll right": .init(
      "Scroll right", parse: { _ in .scroll(.right) }),
    "scroll up": .init(
      "Scroll up [mode] scroll_step_lines lines", parse: { _ in .scroll(.up) }),
    "scroll down": .init(
      "Scroll down [mode] scroll_step_lines lines", parse: { _ in .scroll(.down) }),
    "scroll line_up": .init(
      "Scroll up one line, the count that many (ctrl+y)", parse: { _ in .scroll(.lineUp) }),
    "scroll line_down": .init(
      "Scroll down one line, the count that many (ctrl+e)", parse: { _ in .scroll(.lineDown) }),
    "scroll half_page_up": .init(
      "Scroll up half a page", parse: { _ in .scroll(.halfPageUp) }),
    "scroll half_page_down": .init(
      "Scroll down half a page", parse: { _ in .scroll(.halfPageDown) }),
    "scroll page_up": .init(
      "Scroll up a page", parse: { _ in .scroll(.pageUp) }),
    "scroll page_down": .init(
      "Scroll down a page", parse: { _ in .scroll(.pageDown) }),
    "scroll top": .init(
      "Scroll to the top", parse: { _ in .scroll(.top) }),
    "scroll bottom": .init(
      "Scroll to the bottom", parse: { _ in .scroll(.bottom) }),
    "movement back": .init(
      "Jump back through Flash's movement history", parse: { _ in .movementBack }),
    "movement forward": .init(
      "Jump forward through Flash's movement history", parse: { _ in .movementForward }),
    "mouse gesture": .init(
      "Perform a trackpad gesture at the pointer",
      [
        .text("fingers", "2|3|4|5", required: true),
        .text(
          "motion",
          "tap|double_tap|pinch|spread|rotate_left|rotate_right|swipe_left|swipe_right|swipe_up|swipe_down",
          required: true),
      ],
      parse: { a in
        guard let fingers = a.value("fingers").flatMap(Int.init),
          let motion = a.value("motion").flatMap(TrackpadGesture.Motion.init(rawValue:)),
          TrackpadGesture.action(fingers: fingers, motion: motion) != nil
        else { return nil }
        return .trackpadGesture(fingers: fingers, motion: motion)
      }),
    "hints dismiss": .init(
      "Dismiss hint labels", parse: { _ in .dismissHints }),
    "mark set": .init(
      MarkCommand.setSummary, [.text("letter", "a-z|0-9", required: true)],
      parse: { a in markSlot(a).map { .marks(.set($0)) } }),
    "mark jump": .init(
      MarkCommand.jumpSummary, [.text("letter", "a-z|0-9", required: true)],
      parse: { a in markSlot(a).map { .marks(.jump($0)) } }),
  ]

  static let mouseParameters: [CommandParameter] = [
    .flag("secondary"), .flag("double"), .flag("middle"), .flag("triple"),
    .flag("move"), .flag("drag"), .flag("select"), .flag("multi"),
    .flag("adjust"), .flag("search"), .flag("path"), .flag("sticky"), .flag("copy_url"),
    .flag("copy_text"),
    .text("gesture", "look_up|smart_zoom"), .text("modifiers", "cmd+ctrl+alt+shift"),
  ]

  /// The click flags alone: no session shape.
  static let clickParameters: [CommandParameter] = [
    .flag("secondary"), .flag("double"), .flag("middle"), .flag("triple"),
    .flag("move"), .text("modifiers", "cmd+ctrl+alt+shift"),
  ]

  /// The session shapes only `mouse target` on the focused window offers.
  static let targetSessionFlags = [
    "adjust", "search", "path", "sticky", "copy_url", "copy_text",
  ]

  /// `move <direction>`, which takes no arguments.
  static func move(_ move: MoveCommand, _ summary: String) -> CommandDefinition {
    .init(summary, parse: { a in a.args.isEmpty ? .move(move) : nil })
  }

  static func selectionCommand(_ action: SelectionAction, _ summary: String)
    -> CommandDefinition
  {
    guard action.takesRegister else {
      return .init(summary, parse: { a in a.args.isEmpty ? .selection(action) : nil })
    }
    return .init(
      summary, [.text("register", "name")],
      parse: { a in
        guard validRegisterArg(a) else { return nil }
        return .selection(action, register: registerArg(a))
      })
  }

  static func mouseCommand(_ a: CommandArgs, allowAdjust: Bool = true) -> MouseCommand? {
    let modifiers: ClickModifiers
    if let raw = a.value("modifiers") {
      let names = raw.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
      let parsed = KeyModifier.parseList(names)
      guard !names.isEmpty, names.allSatisfy({ !$0.isEmpty }), parsed.unknown.isEmpty else {
        return nil
      }
      modifiers = ClickModifiers(names: names)
    } else {
      modifiers = []
    }
    let drag = a.bool("drag")
    let select = a.bool("select")
    let multi = a.bool("multi")
    let adjust = a.bool("adjust")
    let search = a.bool("search")
    let path = a.bool("path")
    let sticky = a.bool("sticky")
    if (adjust || search || path || sticky) && !allowAdjust { return nil }
    if [drag, select, multi, adjust, search, path, sticky].filter({ $0 }).count > 1 { return nil }
    let variants: [JumpAction] = [
      a.bool("secondary") ? .rightClick : nil,
      a.bool("double") ? .doubleClick : nil,
      a.bool("middle") ? .middleClick : nil,
      a.bool("triple") ? .tripleClick : nil,
    ].compactMap { $0 }
    let shaped = drag || select || multi || adjust || search || path || sticky
    if a.bool("copy_url") || a.bool("copy_text") {
      guard allowAdjust, a.value("gesture") == nil, !a.bool("move"), modifiers.isEmpty,
        variants.isEmpty, !shaped, !(a.bool("copy_url") && a.bool("copy_text"))
      else { return nil }
      return a.bool("copy_url") ? .copyURL : .copyText
    }
    if let raw = a.value("gesture") {
      guard let gesture = TargetGesture(rawValue: raw), !a.bool("move"), modifiers.isEmpty,
        variants.isEmpty, !shaped
      else { return nil }
      return .gesture(gesture)
    }
    if a.bool("move") {
      return (modifiers.isEmpty && variants.isEmpty && !shaped) ? .move : nil
    }
    if drag { return variants.isEmpty ? .drag(modifiers: modifiers) : nil }
    if select { return variants.isEmpty ? .select(modifiers: modifiers) : nil }
    if variants.count > 1 { return nil }
    // A secondary click (a Control-click is one) opens a menu that takes the
    // keyboard and ends a chain (`ClickChain.Step.nativeMenu`), so a session
    // that repeats its click never carries one.
    if multi || sticky, variants.first == .rightClick || modifiers.contains(.control) {
      return nil
    }
    if multi { return .multi(variants.first ?? .leftClick, modifiers: modifiers) }
    if adjust { return .adjust(variants.first ?? .leftClick, modifiers: modifiers) }
    if search { return .search(variants.first ?? .leftClick, modifiers: modifiers) }
    if path { return .path(variants.first ?? .leftClick, modifiers: modifiers) }
    if sticky { return .sticky(variants.first ?? .leftClick, modifiers: modifiers) }
    return .click(variants.first ?? .leftClick, modifiers: modifiers)
  }

  /// `mouse screens`: at most one of `--index` and `--direction`; neither
  /// labels every display.
  static func screenSelectCommand(_ a: CommandArgs) -> URLCommand? {
    var request = ScreenSelectRequest()
    switch (a.int("index"), a.value("direction")) {
    case (nil, nil): break
    case (let index?, nil): request.pick = .index(index)
    case (nil, "next"): request.pick = .next
    case (nil, "previous"): request.pick = .previous
    default: return nil
    }
    if let to = a.value("to") {
      guard let landing = ScreenSelectRequest.Landing(rawValue: to) else { return nil }
      request.landing = landing
    }
    request.focus = a.bool("focus")
    return .mouseScreens(request)
  }

  /// The required `--letter` of a mark: one ASCII letter or digit.
  static func markSlot(_ a: CommandArgs) -> MarkSlot? {
    a.value("letter").flatMap(MarkSlot.init(parsing:))
  }
}
