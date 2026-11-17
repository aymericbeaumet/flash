import AppKit
import FlashCore

// `move <direction>`: NORMAL's `h` `j` `k` `l`, `ctrl+d` `ctrl+u`, `ctrl+f`
// `ctrl+b`, `gg` and `G`. Each resolves by where the focus sits, read from the
// cached `FocusRegion` (never Accessibility on the keypress): the caret in
// the engaged field (`TextScope`) through the `input` moves, the selection in a list through
// the `move` command's own binding, and the view in a page or a terminal
// through the `scroll` commands. What each app does for a move stays plugin
// data (`bindings`).

extension AppDelegate {
  /// Re-reads the focused element's region after a focus change, off the
  /// main loop (`FocusRegionTracker`).
  func makeFocusRegionTracker() -> FocusRegionTracker {
    let tracker = FocusRegionTracker { pid, deliver in
      Self.normalModeAXActionQueue.async {
        let reading = NormalModeDispatcher.focusRegion(pid: pid)
        DispatchQueue.main.async { deliver(reading) }
      }
    }
    tracker.onSettled = { [weak self] in self?.focusRegionSettled() }
    return tracker
  }

  func performMove(
    _ move: MoveCommand, repeatCount: Int,
    completion: @escaping (NormalModeCommandOutcome) -> Void
  ) {
    if modeStore.mode.isVisual {
      return performVisualMove(move, repeatCount: repeatCount, completion: completion)
    }
    guard let context = normalModeDispatchContext() else {
      FlashLog.debug("[move] no target app", fields: ["move": move.rawValue])
      applyModeOverlay()
      return completion(.noTarget)
    }
    // A declared terminal emulator needs no read: its region is its bundle.
    if TerminalEmulators.contains(context.bundleIdentifier) {
      return performMove(
        move, resolution: .scroll(move.scroll), context: context, repeatCount: repeatCount,
        completion: completion)
    }
    let mode = modeStore.mode
    focusRegionTracker.withReading(for: context.processID) { [weak self] reading in
      guard let self else { return completion(.noTarget) }
      // A move that waited on the read lands only in the mode it was typed
      // in; moves typed meanwhile wait behind it, in order.
      guard self.modeStore.mode == mode else { return completion(.noTarget) }
      // A field the user has not engaged is a page: the keys scroll.
      let region = self.textScope.region(of: reading, pid: context.processID)
      let resolution = MoveResolution.resolve(
        move, in: region, pageLines: FlashTunables.movePageLines)
      FlashLog.debug(
        "[move] resolved",
        fields: ["move": move.rawValue, "region": "\(region)", "to": "\(resolution)"])
      self.performMove(
        move, resolution: resolution, context: context, repeatCount: repeatCount,
        completion: completion)
    }
  }

  private func performMove(
    _ move: MoveCommand, resolution: MoveResolution, context: AppContext, repeatCount: Int,
    completion: @escaping (NormalModeCommandOutcome) -> Void
  ) {
    let count = normalizedRepeatCount(repeatCount)
    switch resolution {
    case .scroll(let kind):
      scrollNormalMode(kind, repeatCount: count)
      completion(.performed)
    case .text(let motion, _):
      performSourceCommand(
        URLCommand.inputMotion(motion).requiredSourceCommand,
        repeatCount: resolution.strokes(count: count), context: context,
        strokeIntervalMs: Self.moveStrokeIntervalMs, completion: completion)
    case .textInLine(let motion):
      performInLineMove(motion, count: count, context: context, completion: completion)
    case .arrows(let step, _):
      performSourceCommand(
        URLCommand.move(step).requiredSourceCommand,
        repeatCount: resolution.strokes(count: count), context: context,
        strokeIntervalMs: Self.moveStrokeIntervalMs, completion: completion)
    }
  }

  /// `h` and `l` in text: as many of the count as fit before the line's edge
  /// (`LineStep`), read off the main loop. A secure field, text the app does
  /// not give, or no selection at all: the arrows as typed, which a single
  /// line's edge stops anyway.
  private func performInLineMove(
    _ motion: InputMotion, count: Int, context: AppContext,
    completion: @escaping (NormalModeCommandOutcome) -> Void
  ) {
    let pid = context.processID
    Self.normalModeAXActionQueue.async { [weak self] in
      let text = NormalModeDispatcher.focusedText(pid: pid, detail: .contents)
      let repeats = Self.inLineRepeats(motion, count: count, in: text)
      DispatchQueue.main.async {
        guard let self else { return completion(.noTarget) }
        guard repeats > 0 else {
          FlashLog.debug(
            "[move] line_edge", fields: ["motion": motion.rawValue, "count": "\(count)"])
          return completion(.performed)
        }
        self.performSourceCommand(
          URLCommand.inputMotion(motion).requiredSourceCommand, repeatCount: repeats,
          context: context, strokeIntervalMs: Self.moveStrokeIntervalMs, completion: completion)
      }
    }
  }

  /// How many Left or Right arrows `h` or `l` sends: within the line when the
  /// text is known, else the count; none outside editable text.
  static func inLineRepeats(_ motion: InputMotion, count: Int, in text: FocusedText) -> Int {
    guard motion.isPermitted(in: text) else { return 0 }
    guard let contents = text.contents, let string = contents.text else { return count }
    let caret =
      motion == .charLeft ? contents.selection.lowerBound : contents.selection.upperBound
    return LineStep.count(motion, requested: count, caret: caret, in: TextBuffer(string))
  }

  /// An `input` command run alone acts only in editable text
  /// (`InputMotion.isPermitted`): its binding is never sent into Finder's
  /// file list, a canvas or a terminal. The `validate` of
  /// `performSourceCommand`, read off the main thread.
  func focusedTextPermits(_ motion: InputMotion) -> (@escaping (Bool) -> Void) -> Void {
    { [weak self] done in
      guard let pid = self?.normalModeDispatchContext()?.processID else { return done(false) }
      Self.normalModeAXActionQueue.async {
        let text = NormalModeDispatcher.focusedText(pid: pid, detail: .kind)
        DispatchQueue.main.async {
          let permitted = motion.isPermitted(in: text)
          if !permitted {
            FlashLog.debug(
              "[input] refused", fields: ["reason": "not_editable", "motion": motion.rawValue])
          }
          done(permitted)
        }
      }
    }
  }

  /// The spacing of the arrows one `move` sends (`5j`, a half page). Arrows
  /// go to text and lists, never to a terminal or a remote desktop, which
  /// are what `[mode] send_key_interval_ms` paces chords for; a half page at
  /// that pace would take half a second.
  static let moveStrokeIntervalMs = 4
}
