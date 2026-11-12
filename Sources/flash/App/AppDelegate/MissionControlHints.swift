import AppKit
import FlashCore

/// `f` while Mission Control or App Exposé is up labels the Dock's view
/// instead of the windows it shrank: the window thumbnails, the Spaces bar's
/// desktops and its add-desktop button (`MissionControlSurface`). The view
/// comes from the Dock's own reports (`SystemSurfaceController`), never from
/// a poll or the screen; the read runs on the AX queue, and every commit is
/// a click `ActionDispatcher` posts.
extension AppDelegate {
  /// Reads of a view the Dock is still building, after the first: about
  /// 750 ms in all, the length of a slow opening animation.
  static let missionControlReadyDelaysMs = [50, 100, 200, 400]
  static let missionControlSurfaceName = "mission_control"

  /// The Dock view `f` labels, as the Dock last reported it: Mission Control
  /// or App Exposé; nil otherwise.
  var missionControlView: DockView? { MissionControlSurface.labelledView(observedDockView) }

  /// The Dock reported its view. Labels drawn for the other side of the
  /// change are wrong now, so their session ends.
  func dockViewChanged(_ view: DockView?) {
    let before = missionControlView
    observedDockView = view
    let after = missionControlView
    guard before != after else { return }
    FlashLog.debug("[missioncontrol] view", fields: ["view": after.map { "\($0)" } ?? "none"])
    if hintSession.isActive || activationInFlight,
      Self.dockViewChangeEndsHintSession(
        hintSession, labelled: after, committing: activationLifecycle.isCommitting)
    {
      cancelOverlay()
    }
  }

  /// Whether the Dock's view becoming `labelled` invalidates `session`: an
  /// app's labels once Mission Control opens over it, Mission Control's once
  /// it closes or turns into App Exposé. A click on its way out, the grid
  /// (screen positions) and sessions over no window are left alone.
  static func dockViewChangeEndsHintSession(
    _ session: HintSession, labelled: DockView?, committing: Bool
  ) -> Bool {
    guard !committing, session.surface == .targets, let request = session.request else {
      return false
    }
    if let shown = session.missionControl { return shown != labelled }
    switch request {
    case .target, .screen, .words, .bigram, .scroll: return labelled != nil
    default: return false
    }
  }

  /// `mouse target` (any of its shapes) while the Dock shows `view`.
  /// `prepareHintActivation` already ran.
  func activateMissionControlHints(_ command: MouseCommand, view: DockView) {
    hintSession.sourceAppPID = nil
    hintSession.command = command
    hintSession.surface = .targets
    hintSession.missionControl = view
    hintSession.prefix = ""
    overlay.debugConfig = config.debug
    guard isAccessibilityTrusted() else {
      promptForAccessibility()
      endHintActivationEmpty(
        bundleIdentifier: MissionControlSurface.dockBundleIdentifier,
        path: "accessibility_denied", surface: Self.missionControlSurfaceName,
        countsForApp: false)
      applyModeOverlay()
      return
    }
    let token = activationLifecycle.begin()
    applyModeOverlay()
    discoverMissionControl(view, token: token, attempt: 0) { [weak self] targets in
      self?.presentMissionControlHints(targets, command: command)
    }
  }

  /// A chain over Mission Control after a click that kept it open (the
  /// add-desktop button): read the view again, keeping the labels of the
  /// targets still there. Mission Control gone meanwhile ends the chain.
  func rediscoverMissionControlTargets() {
    guard let view = missionControlView, view == hintSession.missionControl else {
      cancelOverlay()
      return
    }
    let previous = hintSession.hints
    // Re-present the current set so the panel re-keys, as an app's chain does.
    overlay.display(hints: previous)
    let token = activationLifecycle.begin()
    applyModeOverlay()
    discoverMissionControl(view, token: token, attempt: 0) { [weak self] targets in
      guard let self else { return }
      guard !targets.isEmpty else {
        FlashLog.debug("[missioncontrol] chain_no_targets")
        self.cancelOverlay()
        return
      }
      let relabelled = self.assignHints(targets, preserving: previous)
      self.hintSession.hints = relabelled
      self.hintSession.prefix = ""
      self.overlay.display(hints: relabelled)
      FlashLog.debug("[missioncontrol] rediscovered targets=\(relabelled.count)")
    }
  }

  /// One read of the Dock's view on the AX queue. A tree the Dock is still
  /// building is read again on `missionControlReadyDelaysMs`, armed only
  /// while this activation waits on it; the activation going away (Escape, a
  /// replacement, the view closing) ends the climb. `completion` runs on
  /// main once the activation completed, with no targets when the view
  /// never finished building.
  private func discoverMissionControl(
    _ view: DockView, token: UInt64, attempt: Int,
    completion: @escaping ([JumpTarget]) -> Void
  ) {
    let screenH = ScreenSpace.primaryHeight
    monitor.axQueue.async { [weak self] in
      let discovery = MissionControlSurface.discover(view: view, screenH: screenH)
      DispatchQueue.main.async {
        guard let self, self.activationLifecycle.isCurrent(token) else { return }
        let targets: [JumpTarget]
        switch discovery {
        case .targets(let found):
          targets = found
        case .noDock:
          targets = []
        case .building:
          guard attempt < Self.missionControlReadyDelaysMs.count else {
            FlashLog.debug("[missioncontrol] still_building attempts=\(attempt + 1)")
            targets = []
            break
          }
          // `.high`: the user is looking at the view and waiting on its labels.
          self.missionControlReadyDeadline.arm(
            afterMs: Self.missionControlReadyDelaysMs[attempt]
          ) { [weak self] in
            guard let self, self.activationLifecycle.isCurrent(token) else { return }
            self.discoverMissionControl(
              view, token: token, attempt: attempt + 1, completion: completion)
          }
          return
        }
        guard self.activationLifecycle.complete(token: token) else { return }
        completion(targets)
      }
    }
  }

  /// Label what the Dock's view shows; nothing to label stays silent.
  private func presentMissionControlHints(_ targets: [JumpTarget], command: MouseCommand) {
    let shown: [JumpTarget]
    switch command {
    case .copyURL: shown = Self.urlTargets(targets)
    case .copyText: shown = Self.textTargets(targets)
    default: shown = targets
    }
    guard !shown.isEmpty else {
      FlashLog.debug("[missioncontrol] no_targets")
      endHintActivationEmpty(
        bundleIdentifier: MissionControlSurface.dockBundleIdentifier, path: "no_targets",
        surface: Self.missionControlSurfaceName)
      applyModeOverlay()
      return
    }
    let hints = assignHints(shown)
    hintSession.hints = hints
    hintSession.prefix = ""
    applyModeOverlay()
    presentHints(
      hints, prepared: .miss, outcome: .miss,
      bundleIdentifier: MissionControlSurface.dockBundleIdentifier,
      surface: Self.missionControlSurfaceName)
    if command.isSearch {
      hintSession.phase = .search(.init(allHints: hints))
      updateSearchSelectionMarker()
    }
    FlashLog.debug("[missioncontrol] displayed targets=\(hints.count)")
  }
}
