import AppKit
import ApplicationServices
import FlashCore

// VISUAL (`mode visual [--line]`, `v` and `V` in text): a selection in the
// focused text the motions grow from an anchor, set through
// `AXSelectedTextRange` from the text Accessibility gives, and operators that
// copy it or paste over it with the app's own keys; none deletes or changes
// it, since Flash never edits text. Where the app gives no text, VISUAL
// extends the app's own selection with its selection keys. VISUAL ends in
// NORMAL, and whenever the focus moves
// (`AppMonitor.focusedElementMayHaveChanged`). Steps run one after another
// (`runVisualStep`), so a held `j` never reads a stale cursor.

extension AppDelegate {
  // MARK: Entering and leaving

  /// `mode visual [--line]`: start a selection from the cursor, switch its
  /// kind, or, for the kind already showing, leave it. From NORMAL it
  /// engages the focused field (`TextScope`) when it is editable text, and
  /// does nothing, silently, when it is not, or in an app NORMAL never
  /// engages (`TextScope.engages`: the switch off, or an editor with its
  /// own text editing).
  func performVisualMode(_ kind: VisualKind) {
    if let current = modeStore.mode.visualKind {
      return current == kind ? leaveVisual(collapse: true) : switchVisual(to: kind)
    }
    guard modeStore.mode == .normal, let context = normalModeDispatchContext(),
      !TerminalEmulators.contains(context.bundleIdentifier),
      textScope.engages(context.bundleIdentifier)
    else { return }
    let pid = context.processID
    let bundle = context.bundleIdentifier
    runVisualStep { [weak self] done in
      Self.normalModeAXActionQueue.async {
        let read = NormalModeDispatcher.focusedTextElement(pid: pid, detail: .contents)
        let element = read.element?.elementID
        var session: VisualSession?
        switch VisualPlan.entry(kind, in: read.text) {
        case .none:
          break
        case .measured(let anchor, let range) where read.element?.select(range, pid: pid) == true:
          session = VisualSession(
            pid: pid, kind: kind, anchor: anchor, cursor: anchor, desiredColumn: nil,
            selected: range, measured: true, element: element)
        case .measured, .appKeys:
          // No text, or an app that does not take the selection Flash sets:
          // VISUAL extends the app's own selection with its keys.
          session = VisualSession(
            pid: pid, kind: kind, anchor: 0, cursor: 0, desiredColumn: nil, selected: nil,
            measured: false, element: element)
        }
        DispatchQueue.main.async {
          guard let self, let session, self.modeStore.mode == .normal,
            self.textScope.engages(bundle),
            self.normalModeDispatchContext()?.processID == pid
          else { return done() }
          if let element {
            self.updateTextScope {
              $0.engage(TextScope.Element(pid: pid, identity: element), in: bundle, reason: .visual)
            }
          }
          self.visualSession = session
          self.dispatchMode(.enterVisual(kind))
          FlashLog.debug(
            "[visual] enter", fields: ["kind": kind.rawValue, "measured": "\(session.measured)"])
          guard !session.measured else { return done() }
          let keys = VisualPlan.entryKeys(kind).map { ($0, times: 1) }
          self.sendVisualKeys(keys, context: context) { done() }
        }
      }
    }
  }

  /// `mode visual --reselect`, vim's `gv`: the selection VISUAL last ended
  /// with, selected again in the engaged field it was made in, as the
  /// motions left it; nothing in another field or app, or with none yet.
  func performVisualReselect() {
    guard modeStore.mode == .normal, let last = lastVisualSession,
      let engaged = textScope.engaged, engaged.pid == last.pid,
      last.element == nil || engaged.identity == last.element,
      normalModeDispatchContext()?.processID == last.pid
    else {
      FlashLog.debug("[visual] reselect_skipped", fields: ["last": "\(lastVisualSession != nil)"])
      return
    }
    let pid = last.pid
    runVisualStep { [weak self] done in
      Self.normalModeAXActionQueue.async {
        let read = NormalModeDispatcher.focusedTextElement(pid: pid, detail: .contents)
        var session: VisualSession?
        if let element = read.element, let string = read.text.contents?.text,
          let reselected = VisualPlan.reselect(
            last, element: element.elementID, in: TextBuffer(string)),
          let range = reselected.selected, element.select(range, pid: pid)
        {
          session = reselected
        }
        DispatchQueue.main.async {
          guard let self, let session, self.modeStore.mode == .normal,
            self.textScope.engaged?.pid == pid,
            self.normalModeDispatchContext()?.processID == pid
          else { return done() }
          self.visualSession = session
          self.dispatchMode(.enterVisual(session.kind))
          FlashLog.debug("[visual] reselect", fields: ["kind": session.kind.rawValue])
          done()
        }
      }
    }
  }

  /// `v` in a linewise selection, `V` in a charwise one: the same ends, the
  /// other kind.
  private func switchVisual(to kind: VisualKind) {
    runVisualStep { [weak self] done in
      guard let self, var session = self.visualSession else { return done() }
      session.kind = kind
      self.dispatchMode(.enterVisual(kind))
      guard session.measured else {
        self.visualSession = session
        return done()
      }
      self.applyVisualSelection(session, done: done)
    }
  }

  /// End VISUAL for NORMAL. `collapse` leaves the caret at the moving end,
  /// deselecting (Escape, `v` / `V` again); an operator or a focus change
  /// leaves the app's selection as it is.
  func leaveVisual(collapse: Bool) {
    guard modeStore.mode.isVisual else { return }
    let session = visualSession
    dispatchMode(.leaveVisual)
    guard collapse, let session else { return }
    guard session.measured else {
      // The app collapses its own selection to where it extended.
      return performVisualInput(.charRight, times: 1) {}
    }
    let pid = session.pid
    Self.normalModeAXActionQueue.async {
      _ = NormalModeDispatcher.focusedElement(pid: pid)?.select(
        session.cursor..<session.cursor, pid: pid)
    }
  }

  /// A focus reading landed: when it names another element or app than
  /// the selection's, the focus moved and VISUAL ends without touching it.
  func visualFocusSettled(pid: pid_t?, reading: FocusRegionTracker.Reading?) {
    guard modeStore.mode.isVisual, let session = visualSession,
      !session.survives(focusIn: pid, element: reading?.element)
    else { return }
    FlashLog.debug("[visual] leave", fields: ["reason": "focus_changed"])
    leaveVisual(collapse: false)
  }

  // MARK: Motions

  /// A motion in VISUAL moves the selection's moving end: computed from
  /// the text and set as the whole selection, or, without the text, the
  /// app's selection key.
  func performVisualMotion(
    _ motion: TextMotion, count: Int?, isRepeat: Bool = false, readsVisible: Bool = false,
    completion: @escaping (NormalModeCommandOutcome) -> Void
  ) {
    runVisualStep { [weak self] done in
      guard let self, let session = self.visualSession, self.modeStore.mode.isVisual else {
        completion(.unavailable)
        return done()
      }
      guard session.measured else {
        guard let key = VisualPlan.fallback(for: motion, count: count),
          let context = self.normalModeDispatchContext()
        else {
          completion(.unavailable)
          return done()
        }
        return self.sendVisualKeys([key], context: context) {
          completion(.chordSent)
          done()
        }
      }
      let pid = session.pid
      Self.normalModeAXActionQueue.async {
        let read = NormalModeDispatcher.focusedTextElement(pid: pid, detail: .contents)
        var next: VisualSession?
        var stale = true
        if let contents = read.text.contents, let string = contents.text,
          let element = read.element, contents.selection == session.selected
        {
          stale = false
          let buffer = TextBuffer(string)
          let visible = readsVisible ? element.visibleRange() : nil
          if var moved = VisualPlan.step(
            session, motion: motion, count: count, isRepeat: isRepeat, in: buffer,
            visible: visible)
          {
            let range = VisualPlan.range(
              moved.kind, anchor: moved.anchor, cursor: moved.cursor, in: buffer)
            if element.select(range, pid: pid) {
              moved.selected = range
              next = moved
            }
          }
        }
        DispatchQueue.main.async {
          defer { done() }
          guard self.modeStore.mode.isVisual, self.visualSession == session else {
            return completion(.noTarget)
          }
          if stale {
            // The selection changed by other means (a click, the app):
            // VISUAL no longer knows its ends.
            FlashLog.debug("[visual] leave", fields: ["reason": "selection_changed"])
            self.leaveVisual(collapse: false)
            return completion(.failed)
          }
          if let next { self.visualSession = next }
          completion(.performed)
        }
      }
    }
  }

  /// `move` in VISUAL: logical lines and characters through the engine.
  func performVisualMove(
    _ move: MoveCommand, repeatCount: Int,
    completion: @escaping (NormalModeCommandOutcome) -> Void
  ) {
    let resolved = VisualPlan.motion(
      for: move, count: normalizedRepeatCount(repeatCount),
      pageLines: FlashTunables.movePageLines)
    performVisualMotion(resolved.motion, count: resolved.count, completion: completion)
  }

  // MARK: Operators

  /// VISUAL's operators: `y` copies, `p` and `P` paste over and `o` swaps
  /// the ends. Each runs `VisualPlan.operatorSteps` through the app's own
  /// keys (`clipboard copy`, the register paste); a named register is
  /// written by Flash from the text it read. Then NORMAL.
  func performVisualOperator(_ action: SelectionAction, register: String?) {
    runVisualStep { [weak self] done in
      guard let self, let session = self.visualSession, self.modeStore.mode.isVisual,
        let context = self.normalModeDispatchContext()
      else { return done() }
      let named = register.map { !RegisterStore.isSystemClipboard($0) } ?? false
      let steps = VisualPlan.operatorSteps(action, named: named, session: session)
      FlashLog.debug(
        "[visual] operator",
        fields: ["action": action.rawValue, "named": "\(named)", "steps": "\(steps.count)"])
      self.runVisualOperator(
        steps[...], session: session, register: register, context: context, done: done)
    }
  }

  /// Runs an operator's steps in order. A step that finds the selection
  /// changed by other means ends VISUAL in NORMAL and skips the rest.
  private func runVisualOperator(
    _ steps: ArraySlice<VisualOperatorStep>, session: VisualSession, register: String?,
    context: AppContext, done: @escaping () -> Void
  ) {
    guard let step = steps.first else { return done() }
    let rest = steps.dropFirst()
    let next: (VisualSession) -> Void = { [weak self] session in
      self?.runVisualOperator(
        rest, session: session, register: register, context: context, done: done)
    }
    let abandon = { [weak self] in
      FlashLog.debug("[visual] leave", fields: ["reason": "selection_changed"])
      self?.leaveVisual(collapse: false)
      done()
    }
    switch step {
    case .swapEnds:
      var swapped = session
      (swapped.anchor, swapped.cursor) = (session.cursor, session.anchor)
      swapped.desiredColumn = nil
      visualSession = swapped
      next(swapped)
    case .writeRegister:
      withVisualText(session) { [weak self] text in
        guard let self, let text else { return abandon() }
        self.registers.write(text, register: register)
        next(session)
      }
    case .writeYankRegister:
      withVisualText(session) { [weak self] text in
        guard let self, let text else { return abandon() }
        self.registers.write(text, register: "0")
        next(session)
      }
    case .appCopy:
      performSourceCommand(
        URLCommand.clipboardCopy.requiredSourceCommand, context: context,
        completion: { _ in next(session) })
    case .collapseToStart:
      performVisualInput(.charLeft, times: 1) { next(session) }
    case .leave:
      leaveVisual(collapse: false)
      next(session)
    case .paste:
      performMappedCommand(.paste(register: register))
      next(session)
    }
  }

  /// The selected text VISUAL measured, read again so a changed selection
  /// is never copied; nil when it changed or cannot be read.
  private func withVisualText(_ session: VisualSession, _ body: @escaping (String?) -> Void) {
    let pid = session.pid
    Self.normalModeAXActionQueue.async {
      let read = NormalModeDispatcher.focusedTextElement(pid: pid, detail: .contents)
      var text: String?
      if let contents = read.text.contents, let string = contents.text,
        contents.selection == session.selected, let range = session.selected
      {
        let units = Array(string.utf16)
        if range.upperBound <= units.count {
          text = String(decoding: units[range], as: UTF16.self)
        }
      }
      DispatchQueue.main.async { body(text) }
    }
  }

  // MARK: Plumbing

  /// Sets `session`'s range as the app's selection and keeps what the app
  /// reports, or leaves VISUAL when the app no longer takes it.
  private func applyVisualSelection(_ session: VisualSession, done: @escaping () -> Void) {
    let pid = session.pid
    Self.normalModeAXActionQueue.async {
      let read = NormalModeDispatcher.focusedTextElement(pid: pid, detail: .contents)
      var applied: VisualSession?
      if let contents = read.text.contents, let string = contents.text,
        let element = read.element
      {
        let buffer = TextBuffer(string)
        let range = VisualPlan.range(
          session.kind, anchor: session.anchor, cursor: session.cursor, in: buffer)
        if element.select(range, pid: pid) {
          applied = session
          applied?.selected = range
        }
      }
      DispatchQueue.main.async {
        defer { done() }
        guard self.modeStore.mode.isVisual else { return }
        if let applied { self.visualSession = applied } else { self.leaveVisual(collapse: false) }
      }
    }
  }

  /// One `input` key through the app's binding, `times` times.
  private func performVisualInput(
    _ motion: InputMotion, times: Int, then: @escaping () -> Void
  ) {
    guard let context = normalModeDispatchContext() else { return then() }
    performSourceCommand(
      URLCommand.inputMotion(motion).requiredSourceCommand, repeatCount: times,
      context: context, strokeIntervalMs: Self.moveStrokeIntervalMs, completion: { _ in then() })
  }

  /// The app's keys, one binding after another.
  private func sendVisualKeys(
    _ keys: [(InputMotion, times: Int)], context: AppContext, then: @escaping () -> Void
  ) {
    guard let first = keys.first else { return then() }
    performSourceCommand(
      URLCommand.inputMotion(first.0).requiredSourceCommand, repeatCount: first.times,
      context: context, strokeIntervalMs: Self.moveStrokeIntervalMs,
      completion: { [weak self] _ in
        self?.sendVisualKeys(Array(keys.dropFirst()), context: context, then: then)
      })
  }

  /// Runs VISUAL's steps one after another: each sees the session the one
  /// before it left.
  func runVisualStep(_ step: @escaping (@escaping () -> Void) -> Void) {
    visualSteps.append(step)
    guard !visualStepRunning else { return }
    runNextVisualStep()
  }

  private func runNextVisualStep() {
    guard !visualSteps.isEmpty else {
      visualStepRunning = false
      return
    }
    visualStepRunning = true
    let step = visualSteps.removeFirst()
    step { [weak self] in
      DispatchQueue.main.async { self?.runNextVisualStep() }
    }
  }
}
