import AppKit
import ApplicationServices
import FlashCore
import FlashProviders

/// One `:clipboard show` history row. `preview` is the one-line label, `value`
/// the plain text put back on the clipboard. `html` is a formatted copy,
/// `mime` means an image file is served at `/api/clipboard/<id>`, `files`
/// are copied paths, and `pinned` (written only when true) keeps the entry
/// first and out of trimming. The core store uses this for history pages.
struct ClipboardModalEntry: Codable, Equatable {
  var id: String
  var kind: String
  var preview: String
  var value: String
  var html: String?
  var mime: String?
  var files: [String]
  var pinned: Bool

  private enum CodingKeys: String, CodingKey {
    case id, kind, preview, value, html, mime, files, pinned
  }

  init(
    id: String, kind: String, preview: String, value: String, html: String? = nil,
    mime: String? = nil, files: [String] = [], pinned: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.preview = preview
    self.value = value
    self.html = html
    self.mime = mime
    self.files = files
    self.pinned = pinned
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    kind = try container.decode(String.self, forKey: .kind)
    preview = try container.decode(String.self, forKey: .preview)
    value = try container.decode(String.self, forKey: .value)
    html = try container.decodeIfPresent(String.self, forKey: .html)
    mime = try container.decodeIfPresent(String.self, forKey: .mime)
    files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
    pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(kind, forKey: .kind)
    try container.encode(preview, forKey: .preview)
    try container.encode(value, forKey: .value)
    try container.encodeIfPresent(html, forKey: .html)
    try container.encodeIfPresent(mime, forKey: .mime)
    try container.encode(files, forKey: .files)
    if pinned { try container.encode(true, forKey: .pinned) }
  }
}

struct ClipboardHistoryPage: Codable, Equatable {
  var entries: [ClipboardModalEntry]
  var total: Int
  var nextOffset: Int?

  private enum CodingKeys: String, CodingKey {
    case entries
    case total
    case nextOffset = "next_offset"
  }

  /// The last page says `"next_offset": null`; the synthesized encoder would
  /// drop the key, and the help page rejects a page without it.
  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(entries, forKey: .entries)
    try container.encode(total, forKey: .total)
    try container.encode(nextOffset, forKey: .nextOffset)
  }
}

/// Image MIME lookup for pages the browser has loaded. Rank is the entry's
/// newest-first offset, so a rollover evicts the oldest known image first.
struct ClipboardImageCache {
  private struct Record {
    var mime: String
    var rank: Int
    var seen: UInt64
  }

  private let limit: Int
  private var records: [String: Record] = [:]
  private var nextSeen: UInt64 = 0

  init(limit: Int = 10_000) { self.limit = limit }

  func mime(for id: String) -> String? { records[id]?.mime }

  mutating func remember(_ entries: [ClipboardModalEntry], offset: Int) {
    for (index, entry) in entries.enumerated() {
      guard let mime = entry.mime else { continue }
      nextSeen &+= 1
      records[entry.id] = Record(mime: mime, rank: offset + index, seen: nextSeen)
    }
    while records.count > limit {
      guard
        let oldest = records.max(by: {
          ($0.value.rank, UInt64.max - $0.value.seen)
            < ($1.value.rank, UInt64.max - $1.value.seen)
        })?.key
      else { break }
      records.removeValue(forKey: oldest)
    }
  }

  mutating func remove(_ id: String) { records.removeValue(forKey: id) }
}

struct NormalModeKeyDispatchTarget {
  let processID: pid_t
  let bundleIdentifier: String
}

/// Normal-mode coordination — the big one. Handles mode transitions,
/// the normal-mode interpreter's callbacks, command-line entry, help
/// rendering, plugin invocation, scroll suppression, the per-app
/// active-window border tracker, candidate-finder lifecycle, and the
/// movement-history stacks that back `ctrl-o` / `ctrl-i`.
extension AppDelegate {
  // MARK: Normal mode

  func enterNormalMode() {
    FlashLog.trace(
      "[mode] enter_normal from=\(flashMode) hints=\(hintSession.hints.count) "
        + "in_flight=\(activationInFlight)")
    // `mode normal` out of VISUAL (Vim's Control-[ shortcut, ⌘⌃[) deselects
    // as Escape does, leaving the caret at the moving end.
    if Self.modeNormalDeselects(mode: modeStore.mode, hintsActive: hintSession.isActive) {
      return leaveVisual(collapse: true)
    }
    returnActivationIfClosingCommandBar(reason: "enter_normal")
    overlay.dismissEphemeralStatusBarPopup(reason: "enter_normal_mode")
    dispatchMode(.enterNormal)
  }

  /// Whether `mode normal` in `mode` ends a VISUAL selection by
  /// deselecting it, as Escape does: VISUAL without hints over it.
  static func modeNormalDeselects(mode: Mode, hintsActive: Bool) -> Bool {
    mode.isVisual && !hintsActive
  }

  func leaveMode() {
    releaseHeldMouseButton(reason: "leave_mode")
    // TERMINAL mode is a focused popup, text or terminal alike: leaving it
    // closes the popup and restores the prior base mode and app.
    if modeStore.mode.isTerminal {
      dismissPopup()
      return
    }
    // Escape in VISUAL deselects, leaving the caret at the moving end.
    if modeStore.mode.isVisual, !hintSession.isActive {
      return leaveVisual(collapse: true)
    }
    // Escape in an engaged field (D2): hints, a popup and the command line
    // close first; then NORMAL's own keys come back.
    if modeStore.mode == .normal, textScope.isEngaged, !hintSession.isActive,
      !activationInFlight, !overlay.statusPopupController.isVisible,
      overlay.inputMode != .commandLine
    {
      return updateTextScope { $0.disengage(.escape) }
    }
    if overlay.statusPopupController.isVisible { dismissPopup() }
    returnActivationIfClosingCommandBar(reason: "leave_mode")
    overlay.resignCommandTextFieldFocus()
    dispatchMode(.leaveMode(hasHints: hintSession.isActive || activationInFlight))
  }

  /// A mode mapping that closes the open command bar is a cancel: nothing ran,
  /// so activation goes back to the app the bar covered.
  private func returnActivationIfClosingCommandBar(reason: String) {
    guard overlay.inputMode == .commandLine else { return }
    returnActivationToCoveredApp(reason: reason)
  }

  /// `mode layer --name=<name>`: enter the layer as it is declared now.
  /// Returns why nothing happened for a name no `[mode.layers.<name>]`
  /// declares (a mapping naming one is rejected at load, so this is a CLI or
  /// command-line typo); nil once the reducer has the request.
  @discardableResult
  func enterLayer(named name: String) -> String? {
    guard let layer = config.mode.layers[name] else {
      let message = "no layer named \(name); declare [mode.layers.\(name)]"
      FlashLog.info("[mode] layer_unknown", fields: ["name": name])
      return message
    }
    FlashLog.trace(
      "[mode] enter_layer name=\(name) sticky=\(layer.sticky) from=\(flashMode) "
        + "hints=\(hintSession.hints.count) in_flight=\(activationInFlight)")
    returnActivationIfClosingCommandBar(reason: "enter_layer")
    overlay.dismissEphemeralStatusBarPopup(reason: "enter_layer")
    dispatchMode(.enterLayer(name: name, sticky: layer.sticky))
    return nil
  }

  /// A mapping is about to run. A one-shot layer leaves first, so the
  /// command runs in the base mode as if typed there; a mode command
  /// (`mode insert`, `mode leave`, another layer…) decides the mode itself.
  func leaveOneShotLayer(before action: MappingCommand) {
    guard modeStore.mode.isLayer, action.command?.changesMode != true else { return }
    dispatchMode(.layerMappingFired)
  }

  /// The one door into INSERT: bare `mode insert` (`InsertEntry`). Nothing
  /// else enters it; no click, hint or grid commit comes through here.
  func enterInsertMode(_ entry: InsertEntry) {
    FlashLog.trace(
      "[mode] enter_insert reason=\(entry.rawValue) from=\(flashMode) hints=\(hintSession.hints.count) "
        + "in_flight=\(activationInFlight)")
    dispatchMode(.enterInsert(entry))
  }

  /// The single mutation entry point for the mode: feed the event through the
  /// pure reducer, then perform the effects it returns.
  func dispatchMode(_ event: ModeEvent) {
    // Take the previous table down before another mode draws.
    if whichKeyShown { hideWhichKey() }
    let previous = modeStore.mode
    let jump = hintSession.isBigramCapture
    modeStore.dispatch(event)
    if previous != modeStore.mode, modeStore.mode.isHyper || modeStore.mode.isLayer {
      scheduleWhichKeyIfNeeded()
    }
    // Hyper does not clear hint state on entry. A jump that is still holding
    // the keyboard after the mode changed would swallow the next keys.
    guard jump, previous != modeStore.mode, hintSession.isBigramCapture else { return }
    cancelOverlay()
  }

  /// Armed only while HYPER is latched. The session tap is the release path;
  /// this reads the HID key when that release never arrives.
  private static let hyperHoldWatchID = "core:hyper-hold"

  /// Performs the effects the reducer emitted. The reducer DECIDES the
  /// transition and what to sync; this just does the AppKit work, reusing the
  /// existing routines. No decisions live here.
  func applyModeEffects(_ effects: [ModeEffect], previous: Mode, next: Mode) {
    MainThreadActivity.note("mode_effects")
    // The engaged field survives only the INSERT and VISUAL round trips;
    // leaving INSERT engages the field the focus is in.
    textScopeModeChanged(from: previous, to: next)
    // The mapping scope is a projection of the mode, applied on every
    // transition: no path can leave INSERT reading NORMAL's chords, or any
    // mode reading another's table. Idempotent when it does not change.
    let scope = mappingScope(for: next)
    mappings.apply(scope: scope)
    applyInterpreterTable(for: scope)
    // A VISUAL left by any path forgets its selection's ends, which `gv`
    // can select again.
    if previous.isVisual, !next.isVisual {
      if let session = visualSession, session.measured { lastVisualSession = session }
      visualSession = nil
    }
    for effect in effects {
      switch effect {
      case .prepareKeyboardCapture:
        startKeyboardCaptureTap()
      case .prepareModeEntry:
        applyEnterBookkeeping(next)
      case .hideTerminalPopup:
        terminalInputMappings?.flush()
        overlay.statusPopupController.dismiss()
      case .clearTransientHintState:
        // Reads the still-current overlay surface to tear down a command /
        // modal we are leaving, then clears hint + input state.
        closeModalStateForModeExit(reason: "mode_enter")
        resetModeInputState()
        clearTransientHintState(reason: "mode_enter")
      case .renderSurface:
        // A HYPER hold, or a held button, toggles the pill over the same app
        // and window: the border keeps its frame instead of re-reading the
        // window list.
        applyModeOverlay(
          reusesWindowFrame: previous.isHyper != next.isHyper
            || previous.buttonHold != next.buttonHold)
      case .scheduleRecapture:
        scheduleNormalModeRecapture()
      case .restoreCoveredApp(let pid):
        restoreCoveredApp(pid)
      case .hideOverlayIfIdle:
        if hintSession.hints.isEmpty { overlay.hide() }
      }
    }
    refreshOverlayInputRouting()
    // The one reset point for the hold: every exit from HYPER ends it here,
    // whichever event caused the exit.
    overlay.hyperHold.modeChanged(from: previous, to: next)
    // HOLD is the held button: leaving it any other way
    // (`mode normal`, INSERT, the command line, advanced mode turning
    // off) lets the button go.
    if let hold = previous.buttonHold, next.buttonHold == nil {
      releaseHeldMouseButton(reason: "\(hold.rawValue)_exit")
    }
    if next.isHyper != previous.isHyper {
      setHyperHoldWatch(armed: next.isHyper)
    }
    emitModeChanged(from: previous, to: next)
  }

  /// Poll the hyper key's HID state. Registered only while the mode is HYPER,
  /// and only as a backstop: a delivered key-up still leaves on the tap path.
  private func setHyperHoldWatch(armed: Bool) {
    overlay.hyperHoldWatch = HyperHoldWatch()
    if armed {
      PollScheduler.shared.register(
        Self.hyperHoldWatchID, everyMs: PollScheduler.minimumIntervalMs, priority: .system,
        on: .main
      ) { [weak self] in
        self?.sampleHyperHold()
      }
    } else {
      PollScheduler.shared.unregister(Self.hyperHoldWatchID)
    }
  }

  private func sampleHyperHold() {
    guard modeStore.mode.isHyper else { return }
    let down = hyperKeyPhysicallyDown() ?? true
    guard
      overlay.hyperHoldWatch.sample(holding: overlay.leaderHold.holding, keyIsDown: down) == .exit
    else { return }
    finishHyperExit(reason: "held_key_up")
  }

  /// Nil when the configured key cannot be read. Callers stay in HYPER then,
  /// rather than dropping it because the chord did not parse.
  private func hyperKeyPhysicallyDown() -> Bool? {
    guard let chord = config.mode.resolvedHyperMatcher?.chord else { return nil }
    return HyperKeyChord.isPhysicallyDown(chord)
  }

  /// Per-base-mode bookkeeping that must run before the surface is rendered.
  private func applyEnterBookkeeping(_ next: Mode) {
    // Any base-mode transition ends a transient native-surface suspension; end
    // it before the surface renders so capture isn't pinned off afterward.
    nativeSurfaceOwnership.end()
    switch next {
    case .normal, .layer:
      // Identity only: the target pid needs no WindowServer geometry.
      if let context = normalModeDispatchContext() {
        normalModeTargetPID = context.processID
      }
    case .insert, .disabled:
      normalModeTargetPID = nil
    case .command, .terminal, .hyper, .hold, .visual:
      break
    }
  }

  private func restoreCoveredApp(_ pid: pid_t) {
    guard NSApp.isActive,
      let app = NSRunningApplication(processIdentifier: pid),
      !app.isTerminated, app != .current
    else { return }
    yieldActivation(to: app, reason: "popup_dismiss")
  }

  /// The frontmost non-Flash application by identity alone (no geometry):
  /// the workspace frontmost app unless that is Flash itself, in which case
  /// the last observed focused app.
  func currentNonFlashRunningApplication() -> NSRunningApplication? {
    let flashBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.flash.app"
    if let frontmost = NSWorkspace.shared.frontmostApplication,
      frontmost.bundleIdentifier != flashBundleIdentifier
    {
      return frontmost
    }
    guard let observedFocusedAppPID else { return nil }
    return NSRunningApplication(processIdentifier: observedFocusedAppPID)
  }

  /// Map a projected mode label to the user-configured string.
  func modeLabelText(_ label: ModeLabel) -> String {
    switch label {
    case .insert: return config.mode.labels.insert
    case .normal: return config.mode.labels.normal
    case .command: return config.mode.labels.command
    case .terminal: return config.mode.labels.terminal
    case .hyper: return config.mode.labels.hyper
    case .hold: return config.mode.labels.hold
    case .visual(.charwise): return config.mode.labels.visual
    case .visual(.linewise): return config.mode.labels.visualLine
    case .layer(let name): return config.mode.layerLabel(name)
    }
  }

  /// Leader key-down from the tap or the key-window fallback.
  ///
  /// Returns true when the key was consumed as the hyper hold or as a key
  /// typed during it. Other keys return false and follow the NORMAL path.
  func handleLeaderHoldKeyDown(_ event: NSEvent) -> Bool {
    guard let matcher = config.mode.resolvedHyperMatcher else { return false }
    let atom = matcher.atom
    let keys = overlay.keyCharacters(for: event)
    let isHyperKey = NormalModeInterpreter.isHyperKey(
      matcher: matcher,
      keyCode: event.keyCode,
      modifierFlags: event.modifierFlags,
      characters: keys.characters,
      charactersIgnoringModifiers: keys.ignoringModifiers)
    if case .hyper = modeStore.mode {
      if let down = hyperKeyPhysicallyDown(), overlay.leaderHold.holding {
        if HyperHoldWatch.keyArrivedWhileUp(holding: true, keyIsDown: down) {
          finishHyperExit(reason: "next_key")
          return false
        }
        _ = overlay.hyperHoldWatch.sample(holding: true, keyIsDown: true)
      }
      if isHyperKey {
        _ = overlay.leaderHold.step(.leaderDown)
        return true
      }
      _ = overlay.leaderHold.step(.otherKey)
      expireHyperSequences()
      let result = HyperKeyRouter.route(
        hyperPending: overlay.hyperPending,
        leaderFallbackPending: overlay.leaderFallbackPending,
        leaderAtom: currentLeaderAtom() == atom ? atom : nil,
        keyCode: event.keyCode,
        modifierFlags: event.modifierFlags,
        characters: keys.characters,
        charactersIgnoringModifiers: keys.ignoringModifiers,
        hyperMappings: overlay.hyperModeMappings,
        normalMappings: overlay.normalModeMappings)
      overlay.hyperPending = result.hyperPending
      if !result.hyperPending.isEmpty { overlay.hyperPendingUpdatedAt = Date() }
      overlay.leaderFallbackPending = result.leaderFallbackPending
      if result.leaderFallbackPending != nil { overlay.leaderFallbackUpdatedAt = Date() }
      overlayDidHandleNormalMode(
        result.transition.action, repeatCount: result.transition.repeatCount)
      return true
    }
    guard isHyperKey, modeStore.mode == .normal, overlay.inputMode == .normal else { return false }
    // Releasing the leader arms its prefix. That prefix must not block the
    // next hold; only a real `<leader><leader>` mapping, or some other
    // sequence, does.
    guard
      LeaderHold.canEnter(
        pending: overlay.normalModePending,
        leaderRepeatsAnchor: LeaderHold.leaderRepeats(
          anchor: overlay.normalModeRepeatAnchor, leaderAtom: atom),
        leaderAtom: atom,
        leaderContinuesPending: leaderDownContinuesPending(overlay.normalModePending, event: event),
        isRepeat: event.isARepeat)
    else { return false }
    // A hold still latched here never had its exit reset, which the mode
    // transition makes unreachable; it must not enter HYPER as if fresh.
    guard case .enter = overlay.leaderHold.step(.leaderDown) else {
      FlashLog.warn("[mode] hyper_enter_skipped reason=stale_hold")
      return true
    }
    // The hold supersedes whatever NORMAL had armed: the leader prefix, or a
    // repeat the leader just dropped, with the timeout armed for either.
    resetPendingNormalSequence(reason: "hyper_enter")
    FlashLog.trace("[mode] hyper enter")
    dispatchMode(.enterHyper)
    return true
  }

  /// Leader key-up. A clean tap arms the NORMAL `<leader>` prefix; a hold
  /// that typed anything returns to NORMAL without one.
  func handleLeaderKeyUp(_ event: NSEvent) -> Bool {
    guard let matcher = config.mode.resolvedHyperMatcher else { return false }
    let keys = overlay.keyCharacters(for: event)
    guard
      NormalModeInterpreter.isHyperKey(
        matcher: matcher,
        keyCode: event.keyCode,
        modifierFlags: event.modifierFlags,
        characters: keys.characters,
        charactersIgnoringModifiers: keys.ignoringModifiers)
    else { return false }
    return finishHyperExit(reason: "key_up")
  }

  /// Leave a latched hold. `reason` is `key_up` for a delivered release,
  /// `held_key_up` for the HID backstop, and `next_key` when a later key found
  /// the hyper key already up. A clean tap still arms the leader prefix.
  @discardableResult
  private func finishHyperExit(reason: String) -> Bool {
    let step = overlay.leaderHold.step(.leaderUp)
    guard case .exit(let armPrefix) = step else { return false }
    let fallback = overlay.leaderFallbackPending
    overlay.hyperPending = ""
    overlay.leaderFallbackPending = nil
    guard case .hyper = modeStore.mode else { return true }
    FlashLog.trace("[mode] hyper exit arm_prefix=\(armPrefix) reason=\(reason)")
    dispatchMode(.exitHyper)
    guard modeStore.mode == .normal, let atom = config.mode.resolvedHyperKey else { return true }
    if let fallback, !fallback.isEmpty {
      overlay.normalModePending = fallback
      overlay.normalModePendingUpdatedAt = Date()
      overlayDidHandleNormalMode(nil, repeatCount: 1)
    } else if armPrefix, currentLeaderAtom() == atom, leaderAtomArmsPrefix(atom) {
      overlay.normalModePending = atom
      overlay.normalModePendingUpdatedAt = Date()
      overlayDidHandleNormalMode(nil, repeatCount: 1)
    }
    return true
  }

  /// True when this leader key-down extends `pending` into a mapping or a
  /// longer one, so `<leader><leader>` stays a NORMAL sequence.
  private func leaderDownContinuesPending(_ pending: String, event: NSEvent) -> Bool {
    guard !pending.isEmpty else { return false }
    let keys = overlay.keyCharacters(for: event)
    return NormalModeInterpreter.eventKeyAtoms(
      keyCode: event.keyCode,
      modifierFlags: event.modifierFlags,
      characters: keys.characters,
      charactersIgnoringModifiers: keys.ignoringModifiers
    ).contains { atom in
      let sequence = NormalModeInterpreter.appendKeyAtom(pending, atom)
      return overlay.normalModeMappings.mapping(for: sequence) != nil
        || overlay.normalModeMappings.hasStrictPrefix(sequence)
    }
  }

  private func currentLeaderAtom() -> String? {
    config.mode.resolvedLeaderAtom
  }

  private func leaderAtomArmsPrefix(_ atom: String) -> Bool {
    overlay.normalModeMappings.mapping(for: atom) != nil
      || overlay.normalModeMappings.hasStrictPrefix(atom)
  }

  private func expireHyperSequences() {
    guard !whichKeyShown else { return }
    let now = Date()
    let timeout = config.mode.sequenceTimeoutMs
    if NormalModeInterpreter.pendingSequenceTimedOut(
      pending: overlay.hyperPending,
      lastInputAt: overlay.hyperPendingUpdatedAt,
      now: now,
      timeoutMs: timeout)
    {
      overlay.hyperPending = ""
    }
    if let fallback = overlay.leaderFallbackPending,
      NormalModeInterpreter.pendingSequenceTimedOut(
        pending: fallback,
        lastInputAt: overlay.leaderFallbackUpdatedAt,
        now: now,
        timeoutMs: timeout)
    {
      overlay.leaderFallbackPending = nil
    }
  }

  func invalidateActivation(reason: String) {
    if activationInFlight {
      FlashLog.trace(
        "[activation] invalidate reason=\(reason) gen=\(activationGen) "
          + "in_flight_gen=\(String(describing: activationLifecycle.phase))")
    }
    activationLifecycle.invalidate()
  }

  func clearTransientHintState(reason: String) {
    let hadHints = hintSession.isActive
    let hadActivation = activationInFlight
    if hadHints || hadActivation {
      FlashLog.trace(
        "[mode] clear_hints reason=\(reason) hints=\(hintSession.hints.count) "
          + "in_flight=\(activationInFlight)")
    }
    if hadHints {
      overlay.hide()
    }
    clearHintSessionState()
    if hadActivation {
      invalidateActivation(reason: reason)
    }
  }

  func refreshCurrentModeSideEffects(reason: String) {
    // Both modes paint the active-window border (thin green normal / blue insert).
    updateActiveWindowBorder(reason: reason)
  }

  func activeWindowMayHaveChanged(
    pid: pid_t,
    notification: String,
    observedWindow: AXUIElement?
  ) {
    // Identity only — resolving the window context would scan every on-screen
    // window on the main thread, once per event of a drag.
    guard let app = currentNonFlashRunningApplication(), app.processIdentifier == pid else {
      return
    }
    windowLayoutManager.observedWindowEvent(
      pid: pid, window: observedWindow, notification: notification,
      statusBarReservesSpace: statusBarVisible,
      statusBarMonitor: config.statusBar.monitor)
    if AppMonitor.isWindowGeometryNotification(notification), let observedWindow {
      observedWindowGeometryDidChange(
        pid: pid, window: observedWindow, notification: notification,
        statusBarReservesSpace: statusBarVisible,
        statusBarMonitor: config.statusBar.monitor)
      return
    }
    let isFocusChange =
      notification == kAXFocusedWindowChangedNotification as String
      || notification == kAXMainWindowChangedNotification as String
    if isFocusChange {
      // A background window moving while this popup is still key is not the
      // popup losing focus. Once another app is frontmost, the popup has to
      // leave the screen even if its panel never resigned key.
      let front = NSWorkspace.shared.frontmostApplication
      if !NSApp.isActive || front?.bundleIdentifier != Bundle.main.bundleIdentifier {
        overlay.relinquishShownStatusPopup(reason: "window_focus_changed")
      } else {
        overlay.dismissEphemeralStatusBarPopup(reason: "window_focus_changed")
      }
      scheduleAmbientLocationRecord(pid: pid, reason: "window_focus")
    }
    // The stroke goes first and depends on nothing below. Window AX
    // notifications are delivered after the operation: resolve the
    // authoritative WindowServer frame now and replace (or clear) the stroke
    // in one transaction. It used to wait behind the window-list context
    // match below, and a closed or minimized window leaves its app active
    // with some other app's window on top, so that match dropped the event
    // and the stroke stayed on a window that was gone.
    updateActiveWindowBorder(reason: notification)
    scheduleActiveWindowBorderReconciliation(
      delaysMs: Self.activeWindowBorderEventSettleDelaysMs, reason: notification)

    let destroyedWindow =
      notification == kAXUIElementDestroyedNotification as String ? observedWindow : nil
    // `core:ax.changed` leaves with every AX notification from
    // `AppMonitor.focusedElementDidChange`, never from here.
    let emitsFocusChange =
      isFocusChange && hostEventHasSubscriber(HostEvent.windowFocusChanged.rawValue)
    guard destroyedWindow != nil || emitsFocusChange,
      let context = currentNonFlashContext(), context.processID == pid
    else { return }
    if let observedWindow = destroyedWindow {
      windowLayoutManager.observedWindowFrameChange(
        pid: pid,
        window: observedWindow,
        frame: context.frontWindowFrame,
        notification: notification,
        statusBarReservesSpace: statusBarVisible,
        statusBarMonitor: config.statusBar.monitor)
    }
    // The focused-window-changed and main-window-changed AX notifications are
    // exactly the signal plugins want to react to when they care about *which*
    // window inside an app is on top (e.g. an iTerm/Alacritty plugin watching
    // tmux clients move between attached terminals). The generic
    // `core:ax.changed` fires for any AX mutation, so it's too noisy for that
    // use case; this dedicated event names the app so subscribers can filter
    // on it directly.
    if emitsFocusChange {
      emitHostEvent(.windowFocusChanged(pid: pid, bundleID: context.bundleIdentifier))
    }
  }

  /// Drop a half-typed NORMAL sequence, its repeat anchor, the hyper and
  /// leader-fallback sequences, and disown the timeout armed for the pending
  /// command: they were all resolved against one mapping table, so when the
  /// focused app or the effective mappings change, nothing of them may
  /// complete against the next table. The physical leader hold is not a
  /// sequence and is left alone.
  func resetPendingNormalSequence(reason: String) {
    hideWhichKey()
    if !overlay.normalModePending.isEmpty || overlay.normalModeRepeatAnchor != nil
      || !overlay.hyperPending.isEmpty || overlay.leaderFallbackPending != nil
    {
      FlashLog.trace(
        "[input] pending_reset reason=\(reason) pending=\(overlay.normalModePending) "
          + "anchor=\(overlay.normalModeRepeatAnchor ?? "-") hyper=\(overlay.hyperPending)")
    }
    overlay.normalModePending = ""
    overlay.normalModeRepeatAnchor = nil
    overlay.hyperPending = ""
    overlay.leaderFallbackPending = nil
    normalModePendingCommandToken &+= 1
  }

  private func resetModeInputState() {
    cancelCandidateFinderSessionWork()
    resetPendingNormalSequence(reason: "mode_enter")
    overlay.hyperHold = HyperHoldState()
    overlay.commandLineText = ""
    overlay.commandLineCursorIndex = 0
    finder.candidates = []
    finder.matches = []
    finder.selectedIndex = 0
    finder.currentQuery = ""
    hintSession.prefix = ""
  }

  private func closeModalStateForModeExit(reason: String) {
    switch overlay.inputMode {
    case .commandLine:
      FlashLog.trace("[mode] close_modal input=command_line reason=\(reason)")
      overlay.resignCommandTextFieldFocus()
      resetCommandLineState()
      overlay.hide()
    case .passive, .hints, .normal:
      break
    }
  }

  /// Scroll wheel events in idle normal mode are passive: the overlay
  /// panel has `ignoresMouseEvents=true` so the scroll already reaches the
  /// focused app, and we never want a wheel tick to silently flip Flash
  /// into insert mode or re-key normal capture. (Hints visible → still
  /// cancel: the user is scrolling away from the picker.)
  static func pointerScrollShouldPassThrough(
    mode: FlashMode,
    hasHints: Bool
  ) -> Bool {
    NormalModePointerPolicy.pointerScrollShouldPassThrough(mode: mode, hasHints: hasHints)
  }

  /// Whether a native surface (a context menu, the About window) owns the
  /// keyboard, so Flash must not capture it. A hint session over a context
  /// menu takes it back through the tap (`NativeSurfaceOwnership.ownsKeyboard`).
  var nativeKeyboardOwnerActive: Bool {
    NativeSurfaceOwnership.ownsKeyboard(
      owned: nativeSurfaceSuspended, hintSessionActive: hintSession.isActive,
      activationInFlight: activationInFlight,
      tapLive: keyboardCaptureTap != nil && !secureInputObserved)
      || Self.aboutWindowShouldOwnNativeKeyboard(
        visible: aboutWindowVisible, isKey: statusItemController.aboutWindowIsKey,
        hasTransientInput: hintSession.isActive,
        activationInFlight: activationInFlight)
  }

  /// The overlay's key routing, a pure projection of the mode, the hint
  /// session, the activation walk and native keyboard owners.
  var projectedOverlayInputMode: OverlayInputMode {
    modeStore.mode.overlayInputMode(
      hasHints: hintSession.isActive, activationInFlight: activationInFlight,
      nativeSurfaceSuspended: nativeKeyboardOwnerActive)
  }

  /// Re-derive the overlay's key routing. Called whenever one of its inputs
  /// changes — a mode transition, the hint session or activation walk
  /// starting or ending, a native surface taking or releasing the keyboard —
  /// so routing can never outlive the state it was derived from. In INSERT a
  /// stale `.hints` would swallow every key.
  func refreshOverlayInputRouting() {
    guard let overlay else { return }
    let routed = projectedOverlayInputMode
    guard overlay.inputMode != routed else { return }
    FlashLog.trace("[mode] input_route from=\(overlay.inputMode) to=\(routed)")
    overlay.inputMode = routed
    debugStateDidChange()
  }

  func applyModeOverlay(captureOverride: Bool? = nil, reusesWindowFrame: Bool = false) {
    MainThreadActivity.note("mode_overlay")
    let mode = modeStore.mode
    // A pointer-mode session behaves exactly like a hint set being up: the
    // transient overlay owns input (`.hints`) and NORMAL's own capture is off.
    let hasHints = hintSession.isActive
    let inFlight = activationInFlight
    let suspended = nativeKeyboardOwnerActive
    let inputMode = projectedOverlayInputMode
    // A native-surface suspension forces capture off even when a caller passes
    // `captureOverride: true` (e.g. a recapture attempt that raced a menu open).
    let capture =
      (captureOverride ?? mode.ownsKeyboard(hasHints: hasHints, activationInFlight: inFlight))
      && !suspended
    let text = modeLabelText(mode.label)
    FlashLog.trace(
      "[mode] overlay mode=\(mode) input=\(inputMode) capture=\(capture) "
        + "override=\(String(describing: captureOverride)) suspended=\(suspended) "
        + "visible=\(statusBarVisible) hints=\(hintSession.hints.count) in_flight=\(inFlight)")
    statusBarController?.updateModeLabel(text)
    debugStateDidChange()
    overlay.inputMode = inputMode
    // Command entry paints its text and suggestions immediately after the mode
    // transition. Record the surface but don't lay out an empty command surface
    // here only to replace it in the same turn; `displayCommandLine` performs
    // the one complete first paint.
    var entersCommand = false
    if case .command = mode { entersCommand = !overlay.commandPromptVisible }
    // The surface first: the border's colour is derived from its style.
    overlay.setModeSurface(
      ModeSurface(
        label: text, style: mode.badgeStyle, barVisible: statusBarVisible,
        capturesInput: capture),
      render: !entersCommand)
    updateActiveWindowBorder(
      reason: "apply_mode_overlay", read: reusesWindowFrame ? .onlyWithoutCache : .unlessFresh)
    handBackActivationIfIdle(reason: "mode_overlay")
  }

  /// INSERT with Flash still active (see `IdleActivation`): give activation
  /// back to the app Flash tracks as focused, so the keys the tap passes
  /// reach it. Checked on every overlay application and whenever Flash
  /// becomes active.
  func handBackActivationIfIdle(reason: String) {
    guard idleActivationHandsBack() else { return }
    // Off the key's turn: the request is a system round trip. Decided again
    // there, since the turn in between may have changed either side.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.idleActivationHandsBack() else { return }
      self.handBackIdleActivation(reason: reason)
    }
  }

  private func idleActivationHandsBack() -> Bool {
    IdleActivation.handsBack(
      flashActive: NSApp.isActive, mode: modeStore.mode, aboutWindowVisible: aboutWindowVisible,
      hintSessionActive: hintSession.isActive || activationInFlight)
  }

  private func handBackIdleActivation(reason: String) {
    guard let pid = lastFocusedApplicationPID,
      let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
      app != .current
    else { return }
    yieldActivation(to: app, reason: "insert_while_active_\(reason)")
  }

  /// Key codes for the arrow and function-key mapping commands, resolved once
  /// rather than parsed from their names on every (repeated) press.
  private static let arrowKeyCodes: [WindowFocusDirection: CGKeyCode] = {
    var codes: [WindowFocusDirection: CGKeyCode] = [:]
    for direction in WindowFocusDirection.allCases {
      if let key = HotkeySyntax.parseKey(direction.rawValue) { codes[direction] = CGKeyCode(key) }
    }
    return codes
  }()
  private static let functionKeyCodes: [Int: CGKeyCode] = {
    var codes: [Int: CGKeyCode] = [:]
    for index in 1...24 {
      if let key = HotkeySyntax.parseKey("f\(index)") { codes[index] = CGKeyCode(key) }
    }
    return codes
  }()

  static func commandSurfaceModeLabel(labels: Config.Mode.Labels) -> String {
    labels.command
  }

  func scheduleNormalModeRecapture(delaysMs: [Int] = AppDelegate.normalModeRecaptureDelaysMs) {
    // Only a key About window owns the keyboard; left open behind another
    // app it must not keep NORMAL from capturing that app's keys.
    guard !(aboutWindowVisible && statusItemController.aboutWindowIsKey) else {
      FlashLog.trace("[mode] recapture_skip reason=about_window")
      return
    }
    // A native surface the user still holds open keeps the keyboard. The
    // bounded window stands in for a close signal only for a surface Flash
    // never saw open; one it saw open stays owned until it closes.
    let contextMenuWindowActive = Self.contextMenuInteractionRecaptureSuppressionIsActive(
      until: contextMenuInteractionRecaptureSuppressedUntil)
    guard nativeSurfaceOwnership.recaptureRequested(windowActive: contextMenuWindowActive) else {
      FlashLog.trace(
        "[mode] recapture_skip reason="
          + (nativeSurfaceSuspended ? "native_surface_owned" : "context_menu_interaction"))
      return
    }
    normalModeRecaptureToken &+= 1
    let token = normalModeRecaptureToken
    guard shouldCaptureNormalModeInput else {
      FlashLog.trace("[mode] recapture_skip token=\(token) reason=state")
      return
    }
    // Re-derive routing (`.normal` here) synchronously before scheduling the
    // retries. The 0 ms entry below is still a `DispatchQueue.main.asyncAfter`
    // — it doesn't run until the next runloop turn — so routing is current
    // before any later recapture attempt looks at it.
    refreshOverlayInputRouting()
    overlay.recaptureNormalModeKeyboardInput()
    // The session tap owns capture independently of panel focus. Once routing is
    // `.normal`, retrying on nine future run-loop turns cannot improve anything;
    // retain the recovery ladder only for the no-Accessibility key-window path.
    if overlay.keyboardCaptureActive {
      FlashLog.trace("[mode] recapture_complete token=\(token) via=tap")
      return
    }
    let delays = delaysMs.isEmpty ? [0] : delaysMs
    FlashLog.trace(
      "[mode] schedule_recapture token=\(token) delays="
        + delays.map(String.init).joined(separator: ","))
    for delayMs in delays {
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
        guard let self else { return }
        guard self.normalModeRecaptureToken == token else {
          FlashLog.trace("[mode] recapture_skip token=\(token) delay=\(delayMs) reason=stale")
          return
        }
        guard self.shouldCaptureNormalModeInput else {
          FlashLog.trace(
            "[mode] recapture_skip token=\(token) delay=\(delayMs) reason=state "
              + "mode=\(self.flashMode) hints=\(self.hintSession.hints.count) "
              + "in_flight=\(self.activationInFlight) input=\(self.overlay.inputMode)")
          return
        }
        FlashLog.trace("[mode] recapture_apply token=\(token) delay=\(delayMs)")
        self.refreshOverlayInputRouting()
        self.overlay.recaptureNormalModeKeyboardInput()
      }
    }
  }

  func aboutWindowVisibilityDidChange(_ visible: Bool) {
    guard aboutWindowVisible != visible else { return }
    aboutWindowVisible = visible
    normalModeRecaptureToken &+= 1
    applyModeOverlay()
    if !visible, flashMode == .normal {
      scheduleNormalModeRecapture()
    }
  }

  /// The About window owns the keyboard as a normal window does: while it is
  /// the key window. Left open behind another app, it owns nothing.
  static func aboutWindowShouldOwnNativeKeyboard(
    visible: Bool,
    isKey: Bool,
    hasTransientInput: Bool,
    activationInFlight: Bool
  ) -> Bool {
    visible && isKey && !hasTransientInput && !activationInFlight
  }

  func noteMenuBarInteraction(reason: String, now: Date = Date()) {
    menuBarInteractionRecaptureSuppressedUntil = now.addingTimeInterval(
      Double(Self.menuBarInteractionRecaptureSuppressionMs) / 1_000.0)
    normalModeRecaptureToken &+= 1
    FlashLog.trace("[mode] menu_bar_interaction reason=\(reason) recapture_suppressed=true")
  }

  func noteContextMenuInteraction(reason: String, now: Date = Date()) {
    contextMenuInteractionRecaptureSuppressedUntil = now.addingTimeInterval(
      Double(Self.contextMenuInteractionRecaptureSuppressionMs) / 1_000.0)
    normalModeRecaptureToken &+= 1
    FlashLog.trace("[mode] context_menu_interaction reason=\(reason) recapture_suppressed=true")
  }

  func shouldScheduleNormalModeRecaptureAfterWorkspaceActivation(now: Date = Date()) -> Bool {
    let shouldRecapture = Self.workspaceActivationShouldScheduleNormalModeRecapture(
      mode: flashMode,
      menuBarInteractionRecaptureSuppressedUntil: menuBarInteractionRecaptureSuppressedUntil,
      contextMenuInteractionRecaptureSuppressedUntil:
        contextMenuInteractionRecaptureSuppressedUntil,
      now: now)
    if !shouldRecapture,
      Self.menuBarInteractionRecaptureSuppressionIsActive(
        until: menuBarInteractionRecaptureSuppressedUntil,
        now: now)
    {
      FlashLog.trace("[mode] recapture_skip reason=recent_menu_bar_interaction")
    }
    if !shouldRecapture,
      Self.contextMenuInteractionRecaptureSuppressionIsActive(
        until: contextMenuInteractionRecaptureSuppressedUntil,
        now: now)
    {
      FlashLog.trace("[mode] recapture_skip reason=context_menu_interaction")
    }
    recaptureSuppression.pruneExpired(now: now)
    return shouldRecapture
  }

  static func workspaceActivationShouldScheduleNormalModeRecapture(
    mode: FlashMode,
    menuBarInteractionRecaptureSuppressedUntil: Date?,
    contextMenuInteractionRecaptureSuppressedUntil: Date? = nil,
    now: Date
  ) -> Bool {
    mode == .normal
      && !menuBarInteractionRecaptureSuppressionIsActive(
        until: menuBarInteractionRecaptureSuppressedUntil,
        now: now)
      && !contextMenuInteractionRecaptureSuppressionIsActive(
        until: contextMenuInteractionRecaptureSuppressedUntil,
        now: now)
  }

  static func menuBarInteractionRecaptureSuppressionIsActive(
    until: Date?,
    now: Date
  ) -> Bool {
    RecaptureSuppression.active(until, now: now)
  }

  static func contextMenuInteractionRecaptureSuppressionIsActive(
    until: Date?,
    now: Date = Date()
  ) -> Bool {
    RecaptureSuppression.active(until, now: now)
  }

  func scheduleNormalModeRecaptureAfterPointerFocusLoss() {
    if Self.contextMenuInteractionRecaptureSuppressionIsActive(
      until: contextMenuInteractionRecaptureSuppressedUntil)
    {
      FlashLog.trace("[mode] pointer_recapture_skip reason=context_menu_interaction")
      return
    }
    if Self.pointIsInMenuBar(NSEvent.mouseLocation) {
      // The user clicked the menu bar (system menu, app menu, or status
      // item). Recapturing key window here races the menu/status popup's
      // open and can close it immediately.
      noteMenuBarInteraction(reason: "pointer_focus_loss")
      FlashLog.trace("[mode] pointer_recapture_skip target=menu_bar")
      return
    }
    if let click = Self.pointerFocusLossClick(
      pressedMouseButtons: NSEvent.pressedMouseButtons,
      currentEventType: NSApp.currentEvent?.type,
      location: NSEvent.mouseLocation)
    {
      FlashLog.trace(
        "[mode] pointer_focus_loss_handoff action=\(click.action) "
          + "buttons=\(NSEvent.pressedMouseButtons)")
      let decision = NormalModePointerPolicy.appClickDecision(
        mode: flashMode,
        wasCommandLine: overlay.inputMode == .commandLine,
        hasHints: false,
        action: click.action)
      handleAppPointerDecision(decision, click: click)
      return
    }
    if Self.pointerFocusLossShouldDeferRecaptureForPointerMonitor(inputMode: overlay.inputMode) {
      deferNormalModeRecaptureAfterPointerFocusLoss(reason: "await_pointer_monitor")
      return
    }
    FlashLog.trace(
      "[mode] pointer_recapture_force target=\(Self.pointerFocusLossTarget()) "
        + "reason=normal_mode_focus_contract")
    scheduleNormalModeRecapture()
  }

  private func deferNormalModeRecaptureAfterPointerFocusLoss(reason: String) {
    normalModeRecaptureToken &+= 1
    let token = normalModeRecaptureToken
    FlashLog.trace(
      "[mode] pointer_recapture_defer target=\(Self.pointerFocusLossTarget()) "
        + "reason=\(reason) token=\(token)")
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(Self.pointerFocusLossRecaptureDeferralMs)
    ) { [weak self] in
      guard let self else { return }
      guard self.normalModeRecaptureToken == token else {
        FlashLog.trace("[mode] pointer_recapture_defer_skip token=\(token) reason=stale")
        return
      }
      guard self.flashMode == .normal else {
        FlashLog.trace(
          "[mode] pointer_recapture_defer_skip token=\(token) reason=mode "
            + "mode=\(self.flashMode)")
        return
      }
      guard
        !Self.contextMenuInteractionRecaptureSuppressionIsActive(
          until: self.contextMenuInteractionRecaptureSuppressedUntil)
      else {
        FlashLog.trace(
          "[mode] pointer_recapture_defer_skip token=\(token) reason=context_menu_interaction")
        return
      }
      if Self.pointIsInMenuBar(NSEvent.mouseLocation) {
        self.noteMenuBarInteraction(reason: "pointer_focus_loss_deferred")
        FlashLog.trace("[mode] pointer_recapture_defer_skip token=\(token) target=menu_bar")
        return
      }
      FlashLog.trace(
        "[mode] pointer_recapture_force target=\(Self.pointerFocusLossTarget()) "
          + "reason=normal_mode_focus_contract_deferred")
      self.scheduleNormalModeRecapture()
    }
  }

  static let normalModeRecaptureDelaysMs = [0, 10, 30, 60, 120, 250, 500, 900, 1_400]
  static let normalModeFocusChangingRecaptureDelaysMs = [
    0, 1, 4, 8, 16, 30, 60, 120, 250, 500, 900, 1_400,
  ]
  static var normalModeKeyTargetActivationDelayMs: Int { FlashTunables.sendKeyIntervalMs }

  static let normalModeKeyModifierMask: CGEventFlags = [
    .maskCommand, .maskControl, .maskAlternate, .maskShift,
  ]
  static let menuBarInteractionRecaptureSuppressionMs = 1_500
  static let contextMenuInteractionRecaptureSuppressionMs = 1_500
  // Brief: just long enough for the pointer monitor to deliver the click that
  // took focus (and post it again when macOS spent it on activation) before
  // we reclaim key. Any longer and an app that spontaneously steals focus
  // would sit on it while the badge still reads NORMAL — the exact "shown but
  // not capturing" inconsistency we want to make impossible.
  static let pointerFocusLossRecaptureDeferralMs = 120
  /// Follow-up reads after a window AX event. The event arrives while a closing
  /// window is still fading out of the window list, which drops it 35–45 ms
  /// after the close; the second read catches a slower app.
  static let activeWindowBorderEventSettleDelaysMs = [45, 150]
  /// Follow-up reads after an activation or display change. A launching app's
  /// first window is picked up by its focused-window resolution instead.
  static let activeWindowBorderRecoveryDelaysMs = [80, 250, 750]
  static let activeWindowBorderFrameTolerance: CGFloat = 1

  private static func pointerFocusLossTarget() -> String {
    pointIsInMenuBar(NSEvent.mouseLocation) ? "menu_bar" : "window_or_popup"
  }

  static func pointerFocusLossClick(
    pressedMouseButtons: Int,
    currentEventType: NSEvent.EventType? = nil,
    location: CGPoint
  ) -> OverlayPointerClick? {
    if currentEventType == .rightMouseDown {
      return OverlayPointerClick(action: .rightClick, location: location, modifiers: .all)
    }
    if currentEventType == .leftMouseDown || currentEventType == .otherMouseDown {
      return OverlayPointerClick(action: .leftClick, location: location, modifiers: .all)
    }
    guard pressedMouseButtons != 0 else { return nil }
    let action: JumpAction = (pressedMouseButtons & (1 << 1)) != 0 ? .rightClick : .leftClick
    return OverlayPointerClick(action: action, location: location, modifiers: .all)
  }

  static func pointerFocusLossShouldDeferRecaptureForPointerMonitor(
    inputMode: OverlayInputMode
  ) -> Bool {
    OverlayPanel.pointerIntentMonitorShouldRun(inputMode: inputMode)
  }

  static func pointIsInMenuBar(_ point: CGPoint) -> Bool {
    for screen in NSScreen.screens {
      let menuBand = CGRect(
        x: screen.frame.minX,
        y: screen.visibleFrame.maxY,
        width: screen.frame.width,
        height: max(0, screen.frame.maxY - screen.visibleFrame.maxY))
      if menuBand.contains(point) {
        return true
      }
    }
    return false
  }

  var shouldCaptureNormalModeInput: Bool {
    return Self.normalModeShouldOwnKeyboardInput(
      mode: flashMode,
      overlayInputMode: overlay.inputMode,
      hasHints: hintSession.isActive,
      activationInFlight: activationInFlight)
  }

  @discardableResult
  func guardNormalModeInputAfterActionDispatch(force: Bool = false) -> Bool {
    guard shouldCaptureNormalModeInput else { return false }
    // If the panel already owns the key window AND is routing as normal, the
    // command didn't disturb focus (the common case for scroll/tab/vim
    // sequences and back-to-back chords). Capture is already intact, so skip
    // the re-render + recapture ramp: re-asserting on every keystroke runs an
    // `orderOut`+re-key cycle that can momentarily drop a rapid follow-up key
    // to the focused app ("fires late / lands in the wrong window"). Only
    // re-assert when key was actually lost (e.g. the command activated another
    // app) or the input routing is stale.
    if !force, overlay.keyboardCaptureIsActive, overlay.inputMode == .normal { return false }
    applyModeOverlay(captureOverride: true)
    return true
  }

  static func normalModeShouldOwnKeyboardInput(
    mode: FlashMode,
    overlayInputMode: OverlayInputMode,
    hasHints: Bool,
    activationInFlight: Bool
  ) -> Bool {
    guard mode == .normal, !hasHints, !activationInFlight else { return false }
    switch overlayInputMode {
    case .passive, .hints, .normal:
      return true
    case .commandLine:
      return false
    }
  }

  func hasNormalModeBinding(_ cfg: Config) -> Bool {
    cfg.mode.containsAdvancedModeMapping
  }

  /// A single-chord mapping fired natively: a Carbon hotkey, or the chord
  /// match of the tap or the key window. While NORMAL's interpreter owns the
  /// keys it takes the count and register typed before it and is a NORMAL
  /// step, which `.` repeats and a macro records, as a typed key's mapping
  /// is (`3 ctrl+d`, `"a cmd+v`); after a half-typed sequence it runs
  /// nothing (`NormalModeInterpreter.nativeChord`).
  func dispatchNativeMappingAction(_ action: MappingCommand) {
    if flashMode == .normal, overlay.inputMode == .normal {
      let transition = NormalModeInterpreter.nativeChord(
        pending: overlay.normalModePending, action: action)
      overlay.normalModeRepeatAnchor = nil
      normalModePendingCommandToken &+= 1
      guard let chord = transition.action else {
        FlashLog.trace("[input] native_chord abandoned_pending")
        return resetPendingNormalSequence(reason: "native_chord")
      }
      return dispatchNormalModeAction(
        chord, repeatCount: transition.repeatCount, reason: "native_chord")
    }
    leaveOneShotLayer(before: action)
    let wasNormal = flashMode == .normal
    if wasNormal {
      overlay.normalModePending = ""
      overlay.normalModeRepeatAnchor = nil
      normalModePendingCommandToken &+= 1
    }
    performMappingCommand(action)
    guard wasNormal else { return }
    recaptureAfterNormalAction(action)
  }

  /// A NORMAL action may have moved keyboard focus (an app switch, a shell
  /// command): re-assert capture, on the longer ramp when it could have.
  func recaptureAfterNormalAction(_ action: MappingCommand) {
    let focusChanging = Self.normalModeActionMayChangeKeyboardFocus(action)
    guard guardNormalModeInputAfterActionDispatch(force: focusChanging) else { return }
    scheduleNormalModeRecapture(
      delaysMs: focusChanging
        ? Self.normalModeFocusChangingRecaptureDelaysMs
        : Self.normalModeRecaptureDelaysMs)
  }

  static func normalModeActionMayChangeKeyboardFocus(_ action: MappingCommand) -> Bool {
    switch action {
    case .shellCommand:
      return true
    case .flashCommand(let command):
      return normalModeCommandMayChangeKeyboardFocus(command)
    }
  }

  static func normalModeCommandMayChangeKeyboardFocus(_ command: URLCommand) -> Bool {
    switch command {
    case .openApp, .pluginCommand, .appPrev, .appNext, .showAbout,
      .windowState, .appVisibility,
      .movementBack, .movementForward, .quitApp, .saveAndQuit, .appClose:
      return true
    // A system surface belongs to a macOS agent (the Dock, Spotlight,
    // Control Center), not to an app Flash follows; a forced recapture would
    // fight a panel that is key.
    case .systemKey, .systemSurface:
      return false
    case .sendKey(_, _, let flagsRawValue):
      return normalModeKeyDispatchNeedsTargetActivation(
        flags: CGEventFlags(rawValue: flagsRawValue))
    case .sendKeys(_, _, let flagsRawValues):
      return flagsRawValues.contains {
        normalModeKeyDispatchNeedsTargetActivation(flags: CGEventFlags(rawValue: $0))
      }
    default:
      return false
    }
  }

  static func normalModeKeyDispatchNeedsTargetActivation(flags: CGEventFlags) -> Bool {
    flags.intersection(normalModeKeyModifierMask).isEmpty
  }

  /// `confirmed` marks a command the user has already answered `y` to, so a
  /// plugin's `confirm` gate does not ask again. `completion` runs once with
  /// how the command ended: a command asked of the focused app reports its
  /// source's outcome, any other once dispatched.
  func performMappedCommand(
    _ command: URLCommand, repeatCount: Int = 1, confirmed: Bool = false,
    completion: ((NormalModeCommandOutcome) -> Void)? = nil
  ) {
    let repeatCount = normalizedRepeatCount(repeatCount)
    FlashLog.debug(
      "[mappings] action=\(command.diagnosticDescription) repeat=\(repeatCount)")
    var completesLater = false
    defer { if !completesLater { completion?(.performed) } }
    switch command {
    case .confirm(let request):
      presentConfirmation(request.prompt, command: request.command, repeatCount: repeatCount)
    case .insertMode:
      enterInsertMode(.explicitCommand)
    case .normalMode:
      enterNormalMode()
    case .leaveMode:
      leaveMode()
    case .popupRestart(let name):
      restartPopup(named: name)
    case .popupQuit(let name):
      quitPopup(named: name)
    case .commandMode:
      enterCommandLineMode()
    case .terminalMode(let name):
      enterTerminalMode(named: name)
    case .layerMode(let name):
      enterLayer(named: name)
    case .scroll(let kind):
      scrollNormalMode(kind, repeatCount: repeatCount)
    case .systemKey(let key):
      for _ in 0..<repeatCount { SystemKeyboard.perform(key) }
    case .systemAction(let action):
      performSystemAction(action, confirmed: confirmed)
    case .processKill(let pid):
      performProcessKill(pid, confirmed: confirmed)
    case .media(let media):
      performMediaCommand(media, repeatCount: repeatCount)
    case .caffeinate(let request):
      performCaffeinate(request)
    case .macro(let command):
      completesLater = true
      performMacroCommand(command, repeatCount: repeatCount) { outcome, _ in
        completion?(outcome)
      }
    case .appleCatalog(let command):
      performAppleCatalogCommand(command)
    case .calendar(let command):
      completesLater = true
      performCalendarCommand(command, presents: true) { outcome, _ in completion?(outcome) }
    case .marks(let command):
      performMarkCommand(command)
    case .functionKey(let index):
      guard let key = Self.functionKeyCodes[index] else { return }
      sendFocusedModeKey(key, repeatCount: repeatCount)
    case .arrow(let direction, let shift):
      guard let key = Self.arrowKeyCodes[direction] else { return }
      sendFocusedModeKey(key, flags: shift ? .maskShift : [], repeatCount: repeatCount)
    case .sendKey(_, let keyCode, let flagsRawValue):
      sendNormalModeKey(
        keyCode, flags: CGEventFlags(rawValue: flagsRawValue), repeatCount: repeatCount)
    case .sendKeys(_, let keyCodes, let flagsRawValues):
      let sequence = zip(keyCodes, flagsRawValues).map {
        (key: $0.0, flags: CGEventFlags(rawValue: $0.1))
      }
      sendNormalModeKeySequence(sequence, repeatCount: repeatCount)
    case .reload, .undo, .redo, .archive, .resourceNext, .resourcePrevious, .tabClose, .find,
      .findNext, .findPrevious,
      .tabNext, .tabPrev, .tabFirst, .tabLast, .tabMovePrev, .tabMoveNext, .paneNext, .panePrev,
      .paneSplitVertical, .paneSplitHorizontal, .paneClose, .tabReopen, .historyBack,
      .historyForward, .tabNew, .save, .print, .documentOpen, .windowNew, .windowClose,
      .clipboardCopy, .clipboardPaste, .lookUp, .zoomIn, .zoomOut, .zoomReset,
      .viewSource, .inputMotion, .documentSaveAs, .documentExportPDF, .documentRevert,
      .documentDuplicate, .documentRename, .documentPageSetup, .appSettings, .selectAll,
      .appHelp, .appCancel, .appStop, .appDownloads, .developerTools, .windowCloseAll,
      .windowZoom, .urlBookmark, .urlEdit, .historyShow, .tabDuplicate, .tabPin, .tabMute,
      .tabDetach:
      completesLater = true
      performAppCommand(
        command, repeatCount: repeatCount, confirmed: confirmed,
        completion: completion ?? { _ in })
    case .appVisibility(let action):
      completesLater = true
      let outcome = performAppVisibility(action)
      completion?(outcome)
    case .menuPress(let path):
      completesLater = true
      pressFocusedAppMenuItem(
        path, repeatCount: repeatCount, completion: completion ?? { _ in })
    case .move(let move):
      completesLater = true
      performMove(move, repeatCount: repeatCount, completion: completion ?? { _ in })
    case .cursor(let command):
      completesLater = true
      performCursor(command, repeatCount: repeatCount, completion: completion ?? { _ in })
    case .scrollCursor(let position):
      completesLater = true
      performScrollCursor(position, completion: completion ?? { _ in })
    case .visualMode(let kind):
      performVisualMode(kind)
    case .visualReselect:
      performVisualReselect()
    case .appSwitch:
      enterCommandLineMode(initialText: "flashlight ", candidateFinderScope: .running)
    case .flashlight(let query, let restoreMode):
      enterCommandLineMode(
        initialText: URLCommand.flashlightInput(query: query), candidateFinderScope: .all,
        restoreMode: restoreMode)
    case .enterCommand(let input, let restoreMode):
      enterCommandLineMode(
        initialText: input,
        candidateFinderScope: .all,
        restoreMode: restoreMode)
    // A count before a mouse finisher is a finger count (`2f`, `3s`, `2dF`).
    case .mouseTarget(let command):
      activateMouseTarget(command.withFingers(repeatCount), contextOverride: normalModeContext())
    case .mouseBigram(let command):
      activateMouseBigram(command.withFingers(repeatCount), contextOverride: normalModeContext())
    case .mouseTargetScreen(let command):
      activateScreenScopeHints(command)
    case .mouseTargetWords(let command):
      activateWordHints(command.withFingers(repeatCount), contextOverride: normalModeContext())
    // A count before it picks that display (`NormalModeInterpreter`).
    case .mouseScreens(let request):
      activateScreens(request)
    case .mouseWarp(let request):
      performMouseWarp(request)
    case .mouseStep(let direction):
      for _ in 0..<normalizedRepeatCount(repeatCount) { performMouseStep(direction) }
    case .mouseNudge(let direction, let distance):
      performMouseNudge(direction, distance: distance * normalizedRepeatCount(repeatCount))
    case .mouseJump(let jump):
      for _ in 0..<normalizedRepeatCount(repeatCount) { performMouseJump(jump) }
    case .trackpadGesture(let fingers, let motion):
      performGesture(fingers: fingers, motion: motion)
    case .selection(let action, let register):
      performSelection(action, register: register)
    case .mousePosition(let request):
      performMousePosition(request)
    case .mouseGrid(var request):
      request.mouse = request.mouse.withFingers(repeatCount)
      activateMouseGrid(request, contextOverride: normalModeContext())
    case .mouseRepeat:
      performMouseRepeat(repeatCount: repeatCount)
    case .mousePointer:
      enterPointerMode()
    case .mouseButton(let request):
      performMouseButton(request)
    case .holdMode(let button):
      toggleHoldMode(button)
    case .focusInput:
      focusTextInputInNormalMode(index: repeatCount)
    case .scrollTarget:
      activateScrollTargetHints()
    case .mouseDock:
      activateDockHints()
    case .mouseMenuBar:
      activateMenuBarHints()
    case .mouseNotifications:
      activateNotificationHints()
    case .copyURL:
      copyFocusedDocumentURL()
      applyModeOverlay()
    case .yankSelection(let register):
      yankSelection(into: register)
    case .paste(let register, let after):
      pasteRegister(register, repeatCount: repeatCount, after: after)
    case .tabSelect(let explicitIndex):
      completesLater = true
      tabSelectInNormalMode(index: explicitIndex ?? repeatCount, completion: completion ?? { _ in })
    case .movementBack:
      navigateMovementHistory(direction: .back)
    case .movementForward:
      navigateMovementHistory(direction: .forward)
    case .appPrev:
      navigateAppMRU(direction: .back)
    case .appNext:
      navigateAppMRU(direction: .forward)
    case .quitApp(let force):
      quitNormalModeTargetApp(force: force)
    case .saveAndQuit(let force):
      completesLater = true
      performSourceCommand(
        URLCommand.save.requiredSourceCommand,
        completion: { [weak self] outcome in
          guard outcome != .noTarget else {
            completion?(outcome)
            return
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
            self?.performMappedCommand(.quitApp(force: force), completion: completion)
          }
        })
    case .appClose:
      completesLater = true
      performAppClose(
        repeatCount: repeatCount, confirmed: confirmed, completion: completion ?? { _ in })
    case .showUsage(let topic):
      showHelp(topic: topic)
    case .showMappings:
      showMappings()
    case .showPlugins:
      openDebugDashboard(.plugins(id: nil))
    case .reloadPlugins:
      reloadPlugins()
    case .showLogs:
      openDebugDashboard(.logs)
    case .showCommands:
      openDebugDashboard(.commands)
    case .showMonitors:
      openDebugDashboard(.monitors)
    case .showTelemetry:
      openDebugDashboard(.telemetry)
    case .showAbout:
      handleURLCommand(command)
    case .showAlert, .dismissAlert, .dismissHints, .quit, .openApp, .clipboardHistory,
      .clipboardRestore,
      .pluginCommand, .moveWindow, .statusPush, .statusRefresh, .notify, .logWrite, .metricRecord,
      .menuChoose, .configReload, .configEdit,
      .systemSurface,
      .startup, .updates,
      .focusWindow,
      .windowState, .windowSwitch, .windowLast, .tile, .workspace:
      if let completion {
        completesLater = true
        handleURLCommand(command) { outcome, _ in completion(outcome) }
      } else {
        handleURLCommand(command)
      }
    }
  }

  /// A command that asks the focused app for something: sources, then the
  /// Flash-owned primitive (`window close`'s close button), then the app's
  /// binding. The mode stays as it was, Find and a new tab included: typing
  /// into what they opened starts from an explicit INSERT entry. A command a
  /// plugin declares destructive for this app (`confirm` on its `commands[]`
  /// entry) asks first, unless the user already said `y`.
  private func performAppCommand(
    _ command: URLCommand, repeatCount: Int, confirmed: Bool,
    completion: @escaping (NormalModeCommandOutcome) -> Void
  ) {
    guard let source = command.sourceCommand else { return completion(.unavailable) }
    if !confirmed, let context = normalModeDispatchContext(),
      let prompt = Self.appCommandConfirmation(
        command, pluginPrompt: sourceCommandConfirmation(source.name, context: context),
        binding: pluginManager.commandBinding(
          CommandBindingKey(source), in: PluginSelectorContext(bundleID: context.bundleIdentifier)))
    {
      // The question is the outcome; the answer runs the command later.
      presentConfirmation(prompt, command: command, repeatCount: repeatCount)
      return completion(.performed)
    }
    let primitive: ((AppContext, @escaping (Bool) -> Void) -> Void)? =
      source.name == CommandName("window", "close")
      ? { context, done in
        let pid = context.processID
        Self.normalModeAXActionQueue.async {
          let closed = NormalModeDispatcher.closeFocusedWindow(pid: pid)
          DispatchQueue.main.async { done(closed) }
        }
      } : nil
    var validate: (@escaping (Bool) -> Void) -> Void = { $0(true) }
    if case .inputMotion(let motion) = command { validate = focusedTextPermits(motion) }
    if case .appCancel = command { validate = focusTakesTheAppsCancel }
    performSourceCommand(
      source, repeatCount: command.sourceCommandRepeats ? repeatCount : 1, validate: validate,
      primitive: primitive, completion: completion)
  }

  func performMappingCommand(_ action: MappingCommand, repeatCount: Int = 1) {
    switch action {
    case .flashCommand(let command):
      performMappedCommand(command, repeatCount: repeatCount)
    case .shellCommand(let argv):
      let repeatCount = normalizedRepeatCount(repeatCount)
      FlashLog.debug(
        "[mappings] action=\(action.diagnosticDescription) repeat=\(repeatCount)")
      for _ in 0..<repeatCount {
        CommandMappingRunner.run(argv)
      }
    }
  }

  func normalizedRepeatCount(_ repeatCount: Int) -> Int {
    RepeatCount.clamp(repeatCount)
  }

  func enterCommandLineMode(
    initialText: String = "",
    candidateFinderScope: CandidateScope? = nil,
    restoreMode: Bool = false,
    menu: MenuSession? = nil
  ) {
    let invocationTargetPID = finder.invocationTargetPID ?? normalModeDispatchContext()?.processID
    // Snapshot the entry mode *before* `transitionMode` runs anywhere
    // below so `finishCommandLineInteraction` can put the user back where
    // they were. Verbs that don't ask for this clear the slot so a stale
    // value from a prior open doesn't leak.
    normalModePendingCommandToken &+= 1
    overlay.normalModePending = ""
    overlay.normalModeRepeatAnchor = nil
    closeModalStateForModeExit(reason: "enter_command_mode")
    clearTransientHintState(reason: "enter_command_mode")
    resetCommandLineState()
    finder.invocationTargetPID = invocationTargetPID
    // After the reset, which cancels a pick still open: this one replaces it.
    finder.menu = menu
    if let candidateFinderScope {
      self.finder.scope = candidateFinderScope
    } else {
      self.finder.scope = .all
      clearCandidateFinderState()
    }
    let command = Self.commandLineBuffer(from: initialText)
    // The flashlight is just the command line pre-filled with `:flashlight ` on
    // the native command-line surface (native editing, a blinking caret,
    // arrow/Ctrl-N-P candidate navigation). The candidate scope is tracked
    // separately via `self.finder.scope` / `openCandidateFinderSession`.
    dispatchMode(.openCommand(restoreMode: restoreMode))
    if let candidateFinderScope {
      openCandidateFinderSession(scope: candidateFinderScope)
      if let query = NormalModeDispatcher.commandLineCandidateQuery(command) {
        prefetchNonLocationSources(forCandidateQuery: query)
      }
    }
    refreshCommandLine(text: command, cursorIndex: command.count)
  }

  /// Open the help homepage, or `/docs/<topic>` when a topic is supplied: a
  /// manual page by path or alias, else a plugin's guide.
  func showHelp(topic: String? = nil) {
    let topic = topic?.trimmed
    openDebugDashboard(topic?.isEmpty == false ? .docs(page: topic) : .home)
  }

  /// Open a page of the HTTP inspector's browser help in the default browser.
  /// Backs `:help`, `:mappings`, `:plugins show`, `:commands`, `:logs` and
  /// `:clipboard show`. The inspector is loopback-only; it starts on demand when
  /// disabled at launch, and the page opens once the listener has a bound port.
  func openDebugDashboard(_ page: DebugServer.Page) {
    finishCommandLineInteraction(reason: "debug_dashboard")
    if debugServer == nil {
      startDebugServer(host: config.debug.httpInspectorHost, port: config.debug.httpInspectorPort)
    }
    guard let server = debugServer else { return }
    // The listener's ready state answers; 1.5 s bounds one that never binds.
    server.whenListening(timeoutSeconds: 1.5) { [weak self, weak server] port in
      guard let self, let server, self.debugServer === server, let port,
        let url = DebugServer.dashboardURL(
          host: server.host, port: port, page: page, token: self.helpAccessToken)
      else { return }
      NSWorkspace.shared.open(
        url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
      // The address carries the access token: log the page only.
      FlashLog.info("[debug] opened inspector dashboard page=\(page.path) port=\(port)")
    }
  }

  /// `:plugins reload` — stop and restart every loaded plugin.
  func reloadPlugins() {
    let ids = pluginManager.reloadAll()
    FlashLog.info("[plugins] reload command ids=\(ids.joined(separator: ","))")
    // The plugins tab shows live runtime state, so the reload's progress and
    // result land there instead of a one-shot modal.
    openDebugDashboard(.plugins(id: nil))
  }

  /// `:mappings` — the resolved mapping table lives on the browser help's
  /// Mappings page (fed by `debugStateJSON`).
  func showMappings() {
    openDebugDashboard(.mappings)
  }

  /// `:clipboard show` — history lives on the browser help's Clipboard page.
  /// Refresh the first history page, then open the browser there.
  func openClipboardDashboard() {
    refreshClipboardDashboardCache()
    openDebugDashboard(.clipboard)
  }

  /// Refresh the first history page for the inspector.
  func refreshClipboardDashboardCache() {
    clipboardHistoryStore.page(offset: 0) { [weak self] page in
      guard let self else { return }
      self.clipboardImageMimes.remember(page?.entries ?? [], offset: 0)
      self.clipboardTotal = page?.total ?? 0
      self.clipboardNextOffset = page?.nextOffset
      self.clipboardEntries = page?.entries ?? []
    }
  }

  static func decodeClipboardHistoryPage(_ json: String) -> ClipboardHistoryPage? {
    guard let data = json.data(using: .utf8) else { return nil }
    guard let page = try? JSONDecoder().decode(ClipboardHistoryPage.self, from: data),
      (0...10_000).contains(page.total), page.entries.count <= 100,
      page.entries.count <= page.total,
      page.nextOffset.map({ $0 > 0 && $0 < page.total && !page.entries.isEmpty }) ?? true
    else { return nil }
    return page
  }

  /// One inspector clipboard row: the entry's identity and its one-line
  /// preview. The text and formatted copy stay behind
  /// `/api/clipboard/history`, which the page reads on opening, and image
  /// bytes behind `/api/clipboard/<id>` (`mime` tells the page to load it):
  /// the snapshot is rebuilt on main on every change a browser watches, so
  /// it carries no values.
  static func clipboardStateObject(_ entry: ClipboardModalEntry) -> [String: Any] {
    var object: [String: Any] = [
      "id": entry.id,
      "kind": entry.kind,
      "preview": String(entry.preview.prefix(160)),
    ]
    if let mime = entry.mime, !mime.isEmpty { object["mime"] = mime }
    if !entry.files.isEmpty { object["files"] = entry.files }
    if entry.pinned { object["pinned"] = true }
    return object
  }

  func quitNormalModeTargetApp(force: Bool = false) {
    guard let context = normalModeDispatchContext(),
      let app = NSRunningApplication(processIdentifier: context.processID)
    else {
      FlashLog.debug("[normal] no target app for :quit")
      applyModeOverlay()
      return
    }
    FlashLog.debug(
      "[normal] quit pid=\(context.processID) bundle=\(context.bundleIdentifier) "
        + "force=\(force)"
    )
    if force {
      _ = app.forceTerminate()
    } else {
      _ = app.terminate()
    }
    // The command named this app. Focus its predecessor even when command
    // mode's panel is the key window and the MRU cursor has not caught up.
    focusAppAfterQuit(of: context.processID, commanded: true)
    applyModeOverlay()
  }

  /// `app close`, vim's `:q` (`AppClose`): `tab close` first, with its
  /// sources, its plugin confirmation and the app's binding. Only an app
  /// with no tab to close goes on to its windows, counted off the main
  /// thread: the focused one closes while others remain, the last quits
  /// the app. The app must still be the target when the count comes back.
  func performAppClose(
    repeatCount: Int, confirmed: Bool,
    completion: @escaping (NormalModeCommandOutcome) -> Void
  ) {
    performMappedCommand(.tabClose, repeatCount: repeatCount, confirmed: confirmed) {
      [weak self] outcome in
      guard let self else { return }
      guard AppClose.continuesToWindows(after: outcome) else { return completion(outcome) }
      guard let context = self.normalModeDispatchContext() else {
        FlashLog.debug("[normal] no target app for app close")
        return completion(.noTarget)
      }
      let pid = context.processID
      Self.normalModeAXActionQueue.async {
        let windows = NormalModeDispatcher.standardWindowCount(pid: pid)
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          guard self.normalModeDispatchContext()?.processID == pid else {
            return completion(.noTarget)
          }
          let step = AppClose.step(standardWindows: windows)
          FlashLog.debug(
            "[normal] app close pid=\(pid) bundle=\(context.bundleIdentifier) "
              + "windows=\(windows.map { "\($0)" } ?? "?") step=\(step)")
          switch step {
          case .closeWindow:
            self.performMappedCommand(.windowClose, confirmed: confirmed, completion: completion)
          case .quitApp:
            self.quitNormalModeTargetApp()
            completion(.performed)
          }
        }
      }
    }
  }

  /// Focus the previous app after `pid` quits. `:qa`, `:wq`, and `app quit`
  /// pass `commanded: true` from every mode. A terminate notification passes
  /// false, and then only the focused app moves focus — a background app
  /// dying does not.
  func focusAppAfterQuit(of pid: pid_t, commanded: Bool = false) {
    let wasFocused =
      commanded || pid == appNavigation.current || pid == observedFocusedAppPID
      || pid == normalModeTargetPID
    guard wasFocused else {
      appNavigation.forget(pid, clearingCurrent: false)
      return
    }
    let flashBundleID = Bundle.main.bundleIdentifier
    guard
      let refocused = appNavigation.refocusing(
        afterQuitOf: pid,
        isAvailable: { candidate in
          guard
            let app = NSRunningApplication(processIdentifier: candidate),
            !app.isTerminated,
            app.bundleIdentifier != flashBundleID
          else { return false }
          return true
        }),
      let target = refocused.target
    else {
      if normalModeTargetPID == pid { normalModeTargetPID = nil }
      appNavigation.forget(pid, clearingCurrent: true)
      FlashLog.debug("[app] quit_no_previous pid=\(pid)")
      return
    }
    let previous = appNavigation
    appNavigation = refocused
    guard
      let app = NSRunningApplication(processIdentifier: target),
      RunningApplicationActivation.activate(app, options: [.activateAllWindows])
    else {
      appNavigation = previous
      FlashLog.warn("[app] quit_activation_failed pid=\(target)")
      return
    }
    preparePendingApplicationActivation(app, reason: "app_quit")
    FlashLog.debug("[app] quit_focus pid=\(target) after=\(pid)")
  }

  /// Quick AX reads and presses for NORMAL verbs (`y`, `:q`). They are IPC
  /// into the target app, so never on the main run loop; a queue of their own
  /// keeps them from waiting behind a hint walk on `axQueue`.
  static let normalModeAXActionQueue = DispatchQueue(
    label: "flash.normal.ax_action", qos: .userInteractive)

  /// Posts an arrow or F-key into the focused app's key window, `repeatCount`
  /// times. The first stroke is immediate. Later strokes of one count wait
  /// `[mode] send_key_interval_ms`. The app is already key, so this does not
  /// activate it again.
  func sendFocusedModeKey(
    _ key: CGKeyCode,
    flags: CGEventFlags = [],
    repeatCount: Int = 1
  ) {
    let count = normalizedRepeatCount(repeatCount)
    let interval = FlashTunables.sendKeyIntervalMs
    for index in 0..<count {
      let fire = { [weak self] in
        guard let self else { return }
        self.mappings.noteSyntheticKey(virtualKey: UInt32(key), flags: flags)
        FlashLog.debug(
          "[normal] send_focused_key",
          fields: ["key": "\(key)", "repeat": "\(index + 1)"])
        NormalModeDispatcher.sendFocusedKey(virtualKey: key, flags: flags)
      }
      if index == 0 {
        fire()
      } else {
        DispatchQueue.main.asyncAfter(
          deadline: .now() + .milliseconds(index * interval), execute: fire)
      }
    }
  }

  /// Posts `key` to the focused app `repeatCount` times. `completion` runs
  /// once with the outcome: after the last chord was posted, or at once when
  /// there was no app or a terminal would have typed the chord.
  func sendNormalModeKey(
    _ key: CGKeyCode,
    flags: CGEventFlags = [],
    repeatCount: Int = 1,
    completion: @escaping (NormalModeCommandOutcome) -> Void = { _ in }
  ) {
    sendNormalModeKeySequence(
      [(key, flags)], repeatCount: repeatCount, completion: completion)
  }

  func normalModeCommandTargetIsCurrent(_ target: NormalModeKeyDispatchTarget) -> Bool {
    let ownsLocalWindow =
      NSApp.isActive
      && NSApp.keyWindow.map {
        $0 !== overlay && $0.isVisible
      } == true
    return NormalModeCommandDelivery.owns(
      targetPID: target.processID,
      externalPID: currentNonFlashRunningApplication()?.processIdentifier,
      flashPID: getpid(), ownsLocalKeyWindow: ownsLocalWindow)
  }

  /// Posts the captured target's chords only while it still owns delivery.
  /// Each delayed stroke revalidates ownership before touching the app.
  func postNormalModeChords(
    _ chords: [BindingChord],
    to target: NormalModeKeyDispatchTarget,
    repeatCount: Int = 1,
    strokeIntervalMs: Int? = nil,
    delivery suppliedDelivery: NormalModeCommandDelivery? = nil,
    completion: @escaping (NormalModeCommandOutcome) -> Void = { _ in }
  ) {
    let delivery =
      suppliedDelivery
      ?? NormalModeCommandDelivery(
        stillCurrent: { [weak self] in self?.normalModeCommandTargetIsCurrent(target) == true },
        completion: completion)
    delivery.perform { [weak self] in
      guard let self else { return }
      guard !chords.isEmpty else {
        self.scheduleNormalModeRecapture()
        return delivery.complete(.chordSent)
      }
      let count = self.normalizedRepeatCount(repeatCount)
      let interval = strokeIntervalMs ?? FlashTunables.sendKeyIntervalMs
      var offsetMs =
        self.activateNormalModeKeyTargetIfNeeded(target.processID, chords: chords)
        ? Self.normalModeKeyTargetActivationDelayMs : 0
      let trace = Trace.current
      for repeatIndex in 0..<count {
        for (index, chord) in chords.enumerated() {
          let isLast = repeatIndex == count - 1 && index == chords.count - 1
          DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offsetMs)) { [weak self] in
            delivery.perform {
              guard let self else { return }
              self.mappings.noteSyntheticKey(virtualKey: UInt32(chord.key), flags: chord.flags)
              Trace.run(in: trace) {
                FlashLog.debug(
                  "[normal] send_key",
                  fields: ["pid": "\(target.processID)", "repeat": "\(repeatIndex + 1)"])
                NormalModeDispatcher.sendKey(
                  virtualKey: chord.key, flags: chord.flags, to: target.processID)
              }
              if isLast {
                self.scheduleNormalModeRecapture()
                delivery.complete(.chordSent)
              }
            }
          }
          offsetMs += interval
        }
      }
    }
  }

  /// The command field owns keyboard focus while the picker is open. Return it
  /// to the originating app before delivering text, without changing base mode.
  func insertText(_ text: String, viaClipboard: Bool = true, targetPID: pid_t? = nil) {
    returnToCommandTarget(targetPID, proceed: !text.isEmpty) { [weak self] pid, target in
      guard let self else { return }
      guard viaClipboard else {
        // Emoji (and other short glyphs): type the Unicode directly so inserting
        // it doesn't clobber the user's clipboard.
        NormalModeDispatcher.insertUnicode(text, to: pid)
        self.scheduleNormalModeRecapture()
        return
      }
      // Borrowed, not copied: the clipboard gets the user's copy back, and
      // the snippet never lands in a clipboard history.
      guard let giveBack = self.borrowPasteboard(for: text) else { return }
      self.pasteFromClipboard(into: target, pid: pid)
      giveBack()
    }
  }

  /// Close the command line and hand the keyboard back to the app it covered
  /// (`targetPID`, else the session's, else the focused app), without
  /// changing base mode. `deliver` runs once that app is active again, unless
  /// `proceed` is false or another command superseded this one.
  func returnToCommandTarget(
    _ targetPID: pid_t?, proceed: Bool = true,
    deliver: @escaping (pid_t, NSRunningApplication) -> Void
  ) {
    let pid = targetPID ?? finder.invocationTargetPID ?? normalModeDispatchContext()?.processID
    overlay.resignCommandTextFieldFocus()
    overlay.hide()
    resetCommandLineState()
    applyModeOverlay()
    guard proceed, let pid,
      pid != ProcessInfo.processInfo.processIdentifier,
      let target = NSRunningApplication(processIdentifier: pid), !target.isTerminated
    else { return }
    normalModeTargetPID = pid
    RunningApplicationActivation.activate(target, options: [], restoringMinimizedWindows: false)
    let token = normalModePendingCommandToken
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
      guard let self, self.normalModePendingCommandToken == token,
        !target.isTerminated, target.isActive
      else { return }
      deliver(pid, target)
    }
  }

  /// The receiving app's own paste: its `clipboard paste` command.
  func pasteFromClipboard(into target: NSRunningApplication, pid: pid_t) {
    guard let context = monitor.makeContext(for: target) else { return }
    performSourceCommand(
      URLCommand.clipboardPaste.requiredSourceCommand, context: context,
      keyTarget: NormalModeKeyDispatchTarget(
        processID: pid, bundleIdentifier: context.bundleIdentifier))
  }

  private func sendNormalModeKeySequence(
    _ keys: [(CGKeyCode, CGEventFlags)],
    repeatCount: Int = 1,
    completion: @escaping (NormalModeCommandOutcome) -> Void = { _ in }
  ) {
    guard let target = normalModeKeyDispatchTarget() else {
      FlashLog.debug("[normal] no target app for key sequence")
      applyModeOverlay()
      completion(.noTarget)
      return
    }
    // One unbound chord would type its character, so the whole sequence is
    // refused rather than half-delivered.
    if let unsafe = keys.first(where: {
      commandChordTypesText(key: $0.0, flags: $0.1, bundleIdentifier: target.bundleIdentifier)
    }) {
      FlashLog.debug(
        "[normal] suppress unbound terminal command chord key=\(unsafe.0) "
          + "flags=\(unsafe.1.rawValue) bundle=\(target.bundleIdentifier)")
      applyModeOverlay()
      completion(.refused)
      return
    }
    postNormalModeChords(
      keys.map { BindingChord(key: $0.0, flags: $0.1) }, to: target, repeatCount: repeatCount,
      completion: completion)
  }

  @discardableResult
  private func activateNormalModeKeyTargetIfNeeded(
    _ processID: pid_t,
    chords: [BindingChord]
  ) -> Bool {
    guard
      chords.contains(where: { Self.normalModeKeyDispatchNeedsTargetActivation(flags: $0.flags) })
    else { return false }
    return activateNormalModeKeyTarget(processID)
  }

  @discardableResult
  private func activateNormalModeKeyTarget(_ processID: pid_t) -> Bool {
    guard processID != ProcessInfo.processInfo.processIdentifier else { return false }
    guard
      let app = NSRunningApplication(processIdentifier: processID),
      !app.isTerminated
    else { return false }
    // A synthesized key needs the app active, not its minimized windows back.
    RunningApplicationActivation.activate(app, options: [], restoringMinimizedWindows: false)
    return true
  }

  func normalModeKeyDispatchTarget() -> NormalModeKeyDispatchTarget? {
    let hasVisibleNonOverlayKeyWindow =
      NSApp.keyWindow.map {
        $0 !== overlay && $0.isVisible
      } ?? false
    if Self.normalModeKeyDispatchUsesCurrentProcess(
      applicationIsActive: NSApp.isActive,
      hasVisibleNonOverlayKeyWindow: hasVisibleNonOverlayKeyWindow)
    {
      return NormalModeKeyDispatchTarget(
        processID: ProcessInfo.processInfo.processIdentifier,
        bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.flash.app")
    }
    guard let context = normalModeDispatchContext() else { return nil }
    return NormalModeKeyDispatchTarget(
      processID: context.processID,
      bundleIdentifier: context.bundleIdentifier)
  }

  static func normalModeKeyDispatchUsesCurrentProcess(
    applicationIsActive: Bool,
    hasVisibleNonOverlayKeyWindow: Bool
  ) -> Bool {
    applicationIsActive && hasVisibleNonOverlayKeyWindow
  }

  /// `y` captures one selection, commits its bytes, then clears that same
  /// selection. Register choice never changes the selection policy.
  func yankSelection(into register: String?) {
    let app = currentNonFlashRunningApplication()
    guard let context = app.flatMap({ monitor.makeContext(for: $0) }) ?? normalModeDispatchContext()
    else {
      FlashLog.debug("[normal] no target app for yank_selection")
      applyModeOverlay()
      return
    }
    normalModePendingCommandToken &+= 1
    let request = SelectionYankRequest(
      targetPID: context.processID, register: register,
      commandToken: normalModePendingCommandToken)
    Self.normalModeAXActionQueue.async { [weak self] in
      guard
        request.permitsFrontmost(
          NSWorkspace.shared.frontmostApplication?.processIdentifier, flashPID: getpid()),
        request.permitsInput()
      else { return }
      let selection = NormalModeDispatcher.captureTextSelection(pid: request.targetPID)
      DispatchQueue.main.async {
        self?.finishYankSelection(selection, request: request, context: context)
      }
    }
  }

  private func ownsYankSelection(_ request: SelectionYankRequest) -> Bool {
    request.owns(
      targetPID: currentNonFlashRunningApplication()?.processIdentifier,
      commandToken: normalModePendingCommandToken)
  }

  private func validateYankSelection(
    _ selection: NormalModeDispatcher.TextSelectionSnapshot,
    request: SelectionYankRequest, acceptsCollapsed: Bool = false,
    completion: @escaping (Bool) -> Void
  ) {
    guard ownsYankSelection(request) else { return completion(false) }
    Self.normalModeAXActionQueue.async { [weak self] in
      guard
        request.permitsFrontmost(
          NSWorkspace.shared.frontmostApplication?.processIdentifier, flashPID: getpid()),
        request.permitsInput()
      else { return DispatchQueue.main.async { completion(false) } }
      let state = NormalModeDispatcher.textSelectionState(selection, pid: request.targetPID)
      DispatchQueue.main.async {
        guard let self, self.ownsYankSelection(request) else { return completion(false) }
        completion(state == .unchanged || (acceptsCollapsed && state == .collapsed))
      }
    }
  }

  private func finishYankSelection(
    _ selection: NormalModeDispatcher.TextSelectionSnapshot,
    request: SelectionYankRequest, context: AppContext
  ) {
    guard ownsYankSelection(request) else { return }
    if request.register == "_" || selection.identity.text != nil {
      commitYankedSelection(selection.identity.text, selection: selection, request: request)
      return
    }
    let beforeChange = NSPasteboard.general.changeCount
    performSourceCommand(
      URLCommand.clipboardCopy.requiredSourceCommand, context: context,
      keyTarget: NormalModeKeyDispatchTarget(
        processID: request.targetPID, bundleIdentifier: context.bundleIdentifier),
      stillCurrent: { [weak self] in self?.ownsYankSelection(request) ?? false },
      validate: { [weak self] done in
        guard let self else { return done(false) }
        self.validateYankSelection(selection, request: request, completion: done)
      },
      completion: { [weak self] outcome in
        guard let self, self.ownsYankSelection(request),
          outcome == .chordSent || outcome == .performed
        else { return }
        self.pollPasteboard(after: beforeChange, attempts: 20) { [weak self] text in
          self?.commitYankedSelection(
            text, selection: selection, request: request, acceptsCollapsed: true)
        }
      })
  }

  private func commitYankedSelection(
    _ text: String?, selection: NormalModeDispatcher.TextSelectionSnapshot,
    request: SelectionYankRequest, acceptsCollapsed: Bool = false
  ) {
    validateYankSelection(selection, request: request, acceptsCollapsed: acceptsCollapsed) {
      [weak self] valid in
      guard let self, valid else { return }
      if request.complete(
        text: text, write: self.registers.write,
        clear: {
          self.collapseCopiedSelection(selection, request: request, copiedText: text)
        })
      {
        self.debugStateDidChange()
        FlashLog.debug(
          "[normal] yank len=\(text?.count ?? 0) register=\(request.register ?? "*clipboard*")"
        )
      }
      self.applyModeOverlay()
    }
  }

  private func collapseCopiedSelection(
    _ selection: NormalModeDispatcher.TextSelectionSnapshot, request: SelectionYankRequest,
    copiedText: String?
  ) {
    guard ownsYankSelection(request) else { return }
    let bundleID = currentNonFlashRunningApplication()?.bundleIdentifier ?? ""
    let canUseArrow = SelectionYankRequest.permitsArrowFallback(
      isTerminal: TerminalEmulators.contains(bundleID), selection: selection.identity,
      copiedText: copiedText, discard: request.register == "_")
    Self.normalModeAXActionQueue.async { [weak self] in
      guard
        request.permitsFrontmost(
          NSWorkspace.shared.frontmostApplication?.processIdentifier, flashPID: getpid()),
        request.permitsInput()
      else { return }
      guard
        NormalModeDispatcher.collapseSelectedText(
          selection, pid: request.targetPID,
          shouldContinue: {
            request.permitsInput()
              && request.permitsFrontmost(
                NSWorkspace.shared.frontmostApplication?.processIdentifier, flashPID: getpid())
          }) == .unsupported,
        canUseArrow
      else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        self.validateYankSelection(selection, request: request) { [weak self] valid in
          guard let self, valid, self.ownsYankSelection(request),
            let rightArrow = Self.arrowKeyCodes[.right]
          else { return }
          _ = NormalModeDispatcher.sendKey(virtualKey: rightArrow, to: request.targetPID)
        }
      }
    }
  }

  /// `p` — paste `register` into the focused app with the app's own paste
  /// command, instant in every app and one undo step. The unnamed register is
  /// the clipboard, so its paste keeps every format the copy had. A named
  /// register borrows the clipboard (`borrowPasteboard`) and gives the user's
  /// copy back. `repeatCount` pastes that many times (`3p`).
  private func pasteRegister(_ register: String?, repeatCount: Int, after: Bool = false) {
    if after {
      // Vim's `p`: past the character under the cursor first, unless the
      // line ends there; outside text NORMAL acts on, a plain paste.
      return stepPastCursor { [weak self] in
        self?.pasteRegister(register, repeatCount: repeatCount, after: false)
      }
    }
    guard normalModeDispatchContext() != nil else {
      FlashLog.debug("[normal] no target app for paste")
      applyModeOverlay()
      return
    }
    let count = normalizedRepeatCount(repeatCount)
    if RegisterStore.isSystemClipboard(register) {
      guard NSPasteboard.general.pasteboardItems?.isEmpty == false else {
        FlashLog.debug("[normal] paste register=*clipboard* empty")
        applyModeOverlay()
        return
      }
      performAppCommand(.clipboardPaste, repeatCount: count, confirmed: true) { _ in }
      return
    }
    guard let text = registers.read(register: register), !text.isEmpty,
      let giveBack = borrowPasteboard(for: String(repeating: text, count: count))
    else {
      FlashLog.debug("[normal] paste register=\(register ?? "-") empty")
      applyModeOverlay()
      return
    }
    performAppCommand(.clipboardPaste, repeatCount: 1, confirmed: true) { _ in giveBack() }
  }

  /// Lend the clipboard to one paste of `text` (`PasteboardSnapshot`). The
  /// returned closure, called once the paste was asked of the app, puts the
  /// user's copy back after `PasteboardSnapshot.returnDelayMs` unless a newer
  /// copy replaced the loan. Nil when the pasteboard refused the text.
  func borrowPasteboard(for text: String) -> (() -> Void)? {
    let pasteboard = NSPasteboard.general
    let saved = PasteboardSnapshot.capture(pasteboard)
    guard PasteboardSnapshot.lend(text, to: pasteboard) else {
      saved.restore(to: pasteboard)
      return nil
    }
    let lent = pasteboard.changeCount
    pasteboardLoanSerial &+= 1
    let clientID = "core:pasteboard_loan:\(pasteboardLoanSerial)"
    return {
      PollScheduler.shared.scheduleOnce(
        clientID, afterMs: PasteboardSnapshot.returnDelayMs, priority: .normal, on: .main
      ) {
        guard pasteboard.changeCount == lent else { return }
        saved.restore(to: pasteboard)
      }
    }
  }

  /// Poll the general pasteboard until its change-count moves past `change`
  /// (our synthesized ⌘C landed) or `attempts` run out, then hand the string
  /// to `completion` on the main queue, so it composes with the rest of
  /// normal-mode dispatch. macOS posts no pasteboard notification, so this
  /// is a genuine poll: it rides the shared clock at `.system` — the yank is
  /// waiting on each probe — under an id of its own, so a second yank never
  /// replaces the first one's pending probe.
  private func pollPasteboard(
    after change: Int,
    attempts: Int,
    completion: @escaping (String?) -> Void
  ) {
    pasteboardWaitSerial &+= 1
    probePasteboard(
      clientID: "core:pasteboard_wait:\(pasteboardWaitSerial)", after: change,
      attempts: attempts, completion: completion)
  }

  private func probePasteboard(
    clientID: String, after change: Int, attempts: Int,
    completion: @escaping (String?) -> Void
  ) {
    guard attempts > 0 else {
      completion(nil)
      return
    }
    PollScheduler.shared.scheduleOnce(clientID, afterMs: 15, priority: .system, on: .main) {
      [weak self] in
      let pasteboard = NSPasteboard.general
      if pasteboard.changeCount != change {
        completion(pasteboard.string(forType: .string))
      } else {
        self?.probePasteboard(
          clientID: clientID, after: change, attempts: attempts - 1, completion: completion)
      }
    }
  }

  private func copyFocusedDocumentURL() {
    guard let context = normalModeDispatchContext() else {
      FlashLog.debug("[normal] no target app for copyDocumentURL")
      return
    }
    // Resolve the URL on the AX queue, not main: `registry.documentURL` walks the
    // AX tree with blocking IPCs (up to a few thousand nodes on a miss) and the
    // main run loop hosts the keyboard-capture tap, so a wedged app would stall
    // input for a whole `url copy` keystroke. `url copy` has no latency contract;
    // keep the walk off main (mirroring how discovery runs the provider chain on
    // `axQueue`) and write the pasteboard back on main.
    let registry: SourceRegistry = self.registry
    monitor.axQueue.async {
      guard let url = registry.documentURL(in: context) else {
        FlashLog.debug(
          "[normal] no AX document URL exposed by \(context.bundleIdentifier)")
        return
      }
      DispatchQueue.main.async {
        NormalModeDispatcher.copy(url)
      }
    }
  }

  func normalModeContext() -> AppContext? {
    let targetPID = Self.normalModeDispatchTargetPID(
      focusedPID: currentNonFlashRunningApplication()?.processIdentifier,
      capturedPID: normalModeTargetPID)
    if Self.normalModeShouldPreferCapturedContext(
      mode: flashMode,
      overlayInputMode: overlay.inputMode,
      hasHints: hintSession.isActive,
      activationInFlight: activationInFlight,
      normalModeTargetPID: normalModeTargetPID),
      let pid = normalModeTargetPID,
      pid == targetPID,
      let context = monitor.context(for: pid)
    {
      return context
    }
    if let context = currentDirectNonFlashContext() {
      normalModeTargetPID = context.processID
      return context
    }
    if let pid = targetPID,
      let context = monitor.context(for: pid)
    {
      normalModeTargetPID = pid
      return context
    }
    if let context = currentNonFlashContext() {
      normalModeTargetPID = context.processID
      return context
    }
    return nil
  }

  /// Context for actions that only need app identity, not exact WindowServer
  /// geometry. Avoiding `CGWindowListCopyWindowInfo` keeps keyboard dispatch
  /// independent of the size and age of the global window list.
  func normalModeDispatchContext() -> AppContext? {
    if let pid = Self.normalModeDispatchTargetPID(
      focusedPID: currentNonFlashRunningApplication()?.processIdentifier,
      capturedPID: normalModeTargetPID),
      let app = NSRunningApplication(processIdentifier: pid),
      !app.isTerminated
    {
      normalModeTargetPID = pid
      return monitor.makeContext(for: app)
    }
    return nil
  }

  static func normalModeDispatchTargetPID(focusedPID: pid_t?, capturedPID: pid_t?) -> pid_t? {
    focusedPID ?? capturedPID
  }

  static func normalModeShouldPreferCapturedContext(
    mode: FlashMode,
    overlayInputMode: OverlayInputMode,
    hasHints: Bool,
    activationInFlight: Bool,
    normalModeTargetPID: pid_t?
  ) -> Bool {
    mode == .normal
      && overlayInputMode == .normal
      && !hasHints
      && !activationInFlight
      && normalModeTargetPID != nil
  }

  enum NavigationDirection {
    case back
    case forward
  }

  func recordAppActivation(_ pid: pid_t) {
    appNavigation.record(pid)
    windowSwitcherCatalog.appActivated(pid: pid)
    scheduleAmbientLocationRecord(pid: pid, reason: "app_activation")
  }

  /// Raise the app a command asked Flash to bring forward: the terminal
  /// hosting the tmux session a `:tmux window …` mapping just switched to,
  /// or the app `mark jump` saved. Activation fires
  /// `didActivateApplication`, which records the jump into the movement
  /// history — so `ctrl-o`/`ctrl-i` replay these jumps the same as any other
  /// Flash navigation. False when no running app was asked to activate.
  @discardableResult
  func activateCommandTarget(_ pid: pid_t?, navigationURL: URL? = nil) -> Bool {
    if let navigationURL {
      recordMovement(.route(navigationURL, pid: pid), source: "plugin")
    }
    guard let pid,
      let app = NSRunningApplication(processIdentifier: pid),
      !app.isTerminated
    else { return false }
    let activated = RunningApplicationActivation.activate(app, options: [.activateAllWindows])
    if flashMode == .normal {
      normalModeTargetPID = pid
    }
    scheduleNormalModeRecapture()
    return activated
  }

}
