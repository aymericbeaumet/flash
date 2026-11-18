import AppKit
import FlashCore

/// Windows and their layout: `window`, `tile` and `workspace`.
extension URLEventHandler {
  static let windowsCommands: [String: CommandDefinition] = [
    "window new": .init(
      "Open a new window; --private, a private browsing one", [.flag("private")],
      parse: { a in .windowNew(private: a.bool("private")) }),
    "window close_all": .init(
      "Close every window of the focused app, after asking",
      parse: { a in a.args.isEmpty ? .windowCloseAll : nil }),
    "window zoom": .init(
      "Zoom the focused window to fit its content, or back",
      parse: { a in a.args.isEmpty ? .windowZoom : nil }),
    "window close": .init(
      "Close the focused window", parse: { _ in .windowClose }),
    "window move": .init(
      "Tile, resize or move the focused window",
      [
        .text("position", "slot"), .text("x", "percent"), .text("y", "percent"),
        .text("width", "percent"), .text("height", "percent"), .text("screen", "n"),
      ], parse: windowMoveCommand),
    "window focus": .init(
      "Focus the nearest window in a direction, or cycle the stack",
      [.text("direction", "left|right|up|down|next|previous|behind", required: true)],
      parse: { a in
        guard let value = a.value("direction"),
          let request = WindowFocusRequest(direction: value)
        else { return nil }
        return .focusWindow(request)
      }),
    "window next": .init(
      "Focus the focused app's next window",
      parse: { a in a.args.isEmpty ? .focusWindow(.app(.next)) : nil }),
    "window previous": .init(
      "Focus the focused app's previous window",
      parse: { a in a.args.isEmpty ? .focusWindow(.app(.previous)) : nil }),
    "window switch": .init(
      "Pick any window, most recently used first; again to move down the list",
      parse: { a in a.args.isEmpty ? .windowSwitch : nil }),
    "window last": .init(
      "Focus the window you were in before this one",
      parse: { a in a.args.isEmpty ? .windowLast : nil }),
    "tile move": .init(
      "Move the focused tiled window in a direction in its workspace's tree",
      [.text("direction", "left|right|up|down", required: true)],
      parse: { a in tileDirection(a).map { .tile(.move($0)) } }),
    "tile swap": .init(
      "Swap the focused tiled window with its neighbor in a direction",
      [.text("direction", "left|right|up|down", required: true)],
      parse: { a in tileDirection(a).map { .tile(.swap($0)) } }),
    "tile join": .init(
      "Put the focused tiled window and its neighbor in a new container",
      [.text("direction", "left|right|up|down", required: true)],
      parse: { a in tileDirection(a).map { .tile(.join($0)) } }),
    "tile layout": .init(
      "Set the focused window's container to tiles or accordion, horizontal or vertical",
      [.text("type", "tiles|accordion|horizontal|vertical|toggle", required: true)],
      parse: { a in
        a.value("type").flatMap(TilingLayoutRequest.init(rawValue:)).map { .tile(.layout($0)) }
      }),
    "tile resize": .init(
      "Grow or shrink the focused tiled window by points",
      [
        .text("dimension", "width|height|smart", required: true),
        .text("amount", "points", required: true),
      ],
      parse: { a in
        guard let dimension = a.value("dimension").flatMap(TilingResizeDimension.init(rawValue:)),
          let raw = a.value("amount"),
          let amount = Int(raw.hasPrefix("+") ? String(raw.dropFirst()) : raw), amount != 0,
          abs(amount) <= 10_000
        else { return nil }
        return .tile(.resize(dimension, amount: amount))
      }),
    "tile balance": .init(
      "Give every tiled window of the focused workspace an equal share",
      parse: { a in a.args.isEmpty ? .tile(.balance) : nil }),
    "tile flatten": .init(
      "Put every tiled window of the focused workspace in one container",
      parse: { a in a.args.isEmpty ? .tile(.flatten) : nil }),
    "tile float": .init(
      "Float the focused window, or tile it again",
      parse: { a in a.args.isEmpty ? .tile(.float) : nil }),
    "tile fullscreen": .init(
      "Make the focused tiled window fill its workspace, or end it",
      parse: { a in a.args.isEmpty ? .tile(.fullscreen) : nil }),
    "workspace switch": .init(
      "Show a workspace and focus it; created on demand",
      [.text("name", "workspace", required: true)],
      parse: { a in a.value("name").map { .workspace(.switchTo($0)) } }),
    "workspace next": .init(
      "Show the next workspace on the focused display",
      parse: { a in a.args.isEmpty ? .workspace(.next) : nil }),
    "workspace previous": .init(
      "Show the previous workspace on the focused display",
      parse: { a in a.args.isEmpty ? .workspace(.previous) : nil }),
    "workspace back_and_forth": .init(
      "Show the workspace focused before this one",
      parse: { a in a.args.isEmpty ? .workspace(.backAndForth) : nil }),
    "workspace move_window": .init(
      "Move the focused window to a workspace",
      [.text("name", "workspace", required: true)],
      parse: { a in a.value("name").map { .workspace(.moveWindow($0)) } }),
    "workspace move_to_monitor": .init(
      "Show the focused workspace on the next or previous display",
      [.text("direction", "next|previous", required: true)],
      parse: { a in
        switch a.value("direction") {
        case "next": return .workspace(.moveToMonitor(1))
        case "previous": return .workspace(.moveToMonitor(-1))
        default: return nil
        }
      }),
    "workspace list": .init(
      "List the workspaces, their windows and displays, the focused one marked",
      parse: { a in a.args.isEmpty ? .workspace(.list) : nil }),
    "window minimize": .init(
      "Minimize the focused window", parse: { a in a.args.isEmpty ? .windowState(.minimize) : nil }),
    "window restore": .init(
      "Restore the most recently minimized window",
      parse: { a in a.args.isEmpty ? .windowState(.restore) : nil }),
    "window fullscreen": .init(
      "Toggle, enter or leave native full screen", [.text("state", "on|off|toggle")],
      parse: { a in
        guard let state = WindowStateAction.FullscreenState(rawValue: a.value("state") ?? "toggle")
        else { return nil }
        return .windowState(.fullscreen(state))
      }),
  ]

  static func windowMoveCommand(_ a: CommandArgs) -> URLCommand? {
    let rawPosition = a.value("position")
    let rawScreen = a.value("screen")
    let rawX = a.value("x")
    let rawY = a.value("y")
    let rawWidth = a.value("width")
    let rawHeight = a.value("height")
    let rawFrame = [rawX, rawY, rawWidth, rawHeight]
    let hasProportionalFrame = rawFrame.contains(where: { $0 != nil })
    // Empty form `flash window move` is a no-op mapping — flag it at
    // config load so the user can't mis-write a hotkey.
    if rawPosition == nil && rawScreen == nil && !hasProportionalFrame { return nil }
    // Named slots and explicit percentage frames are two complete layout forms;
    // mixing them would make the source of each dimension ambiguous.
    if rawPosition != nil && hasProportionalFrame { return nil }
    // A *typo'd* position (e.g. `position=foo`) is rejected too; we
    // don't want to silently degrade to "just move screen".
    var layout: WindowLayout? = nil
    if let raw = rawPosition {
      guard let p = WindowPosition(rawValue: raw.lowercased()) else {
        return nil
      }
      layout = .position(p)
    } else if hasProportionalFrame {
      guard
        let x = parseWindowPercentage(rawX),
        let y = parseWindowPercentage(rawY),
        let width = parseWindowPercentage(rawWidth),
        let height = parseWindowPercentage(rawHeight),
        width > 0,
        height > 0,
        x + width <= 100,
        y + height <= 100
      else { return nil }
      layout = .proportional(
        ProportionalWindowFrame(
          xPercent: x,
          yPercent: y,
          widthPercent: width,
          heightPercent: height))
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
    return .moveWindow(MoveWindowParams(layout: layout, screen: screen))
  }

  static func parseWindowPercentage(_ raw: String?) -> Double? {
    guard let raw, raw.hasSuffix("%"), raw.count > 1 else { return nil }
    let number = String(raw.dropLast())
    guard let percentage = Double(number), percentage.isFinite,
      percentage >= 0, percentage <= 100
    else { return nil }
    return percentage
  }

  /// `--direction=left|right|up|down` for the `tile` commands.
  static func tileDirection(_ arguments: CommandArgs) -> WindowFocusDirection? {
    arguments.value("direction").flatMap(WindowFocusDirection.init(rawValue:))
  }
}
