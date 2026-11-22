import AppKit
import FlashCore

// App navigation: the app MRU behind `app next` / `app previous`, the
// movement history behind `movement back` / `movement forward`, and the
// focused non-Flash app contexts commands resolve. Named app marks are
// `MarkStore` and `MarkCommands.swift`.

extension AppDelegate {
  func navigateAppMRU(direction: NavigationDirection) {
    let flashBundleID = Bundle.main.bundleIdentifier
    let available: (pid_t) -> Bool = { pid in
      guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
      return !app.isTerminated && app.bundleIdentifier != flashBundleID
    }
    var history = appNavigation
    if history.navigating(direction, isAvailable: available) == nil, let current = history.current {
      history = history.seeded(
        back: NSWorkspace.shared.runningApplications
          .filter {
            $0.processIdentifier != current
              && !$0.isTerminated
              && $0.activationPolicy == .regular
              && $0.bundleIdentifier != flashBundleID
          }
          .sorted {
            let lhsDate = $0.launchDate ?? .distantPast
            let rhsDate = $1.launchDate ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return $0.processIdentifier < $1.processIdentifier
          }
          .map(\.processIdentifier))
      appNavigation = history
      FlashLog.debug("[app] navigation_seeded running_apps=\(history.back.count)")
    }

    guard
      let navigated = history.navigating(direction, isAvailable: available),
      let target = navigated.target,
      let app = NSRunningApplication(processIdentifier: target)
    else {
      FlashLog.debug("[app] navigation_no_target direction=\(direction)")
      return
    }

    let previous = appNavigation
    appNavigation = navigated
    guard RunningApplicationActivation.activate(app, options: [.activateAllWindows]) else {
      appNavigation = previous
      FlashLog.warn("[app] navigation_activation_failed direction=\(direction) pid=\(target)")
      return
    }
    preparePendingApplicationActivation(app, reason: "app_navigation")
  }

  func recordMovement(_ entry: MovementEntry, source: String, isAmbient: Bool = false) {
    let recorded = movementHistory.record(entry, isAmbient: isAmbient, identify: movementIdentity)
    // A move the user made supersedes every location resolution in flight.
    if !isAmbient, recorded != .unidentified { movementLocationResolutionGeneration &+= 1 }
    switch recorded {
    case .unidentified, .dropped:
      break
    case .arrived(let key):
      FlashLog.trace("[movement] activation target=\(key) raw=\(entry.key) source=navigation")
    case .coalesced(let key):
      FlashLog.trace("[movement] coalesced source=\(source) current=\(key) raw=\(entry.key)")
    case .coalescedActivation(let key):
      FlashLog.trace(
        "[movement] coalesced_activation source=\(source) current=\(key) raw=\(entry.key)")
    case .stop(let key):
      FlashLog.trace(
        "[movement] record source=\(source) current=\(key) raw=\(entry.key) "
          + "back=\(movementHistory.back.count) forward=\(movementHistory.forward.count)")
    }
  }

  /// A switch a source performed, naming where it landed (a tmux window, a
  /// Firefox tab). The stop is recorded now, and its key is left settling:
  /// the app's catalog refreshes only once its own burst of changes settles,
  /// so the observation already in flight names the location this switch
  /// left. Without the guard that observation is a stop of its own, which
  /// pushes the step just recorded back onto the stack and reorders a fast
  /// run of `]t`. `recordMovement` drops an ambient observation naming
  /// another location until one names this stop, and the next explicit
  /// record supersedes it.
  func recordPerformedNavigation(_ entry: MovementEntry, source: String) {
    recordMovement(entry, source: source)
    movementHistory.settle(on: entry, identify: movementIdentity)
  }

  /// Gathering and preparing every location catalog costs tens of
  /// milliseconds; it runs off main and only the diff against the recorded
  /// selection comes back.
  func recordPublishedLocations() {
    guard let app = currentNonFlashRunningApplication(), !app.isTerminated else { return }
    let pid = app.processIdentifier
    let registry: SourceRegistry = self.registry
    Self.locationGatherQueue.async {
      let candidates = registry.locationSnapshotCandidates(scope: .all)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.currentNonFlashRunningApplication()?.processIdentifier == pid else {
          return
        }
        if !self.recordPublishedLocations(candidates, processID: pid) {
          self.scheduleAmbientLocationRecord(pid: pid, reason: "location_catalog")
        }
      }
    }
  }

  static let locationGatherQueue = DispatchQueue(
    label: "flash.movement.location_gather", qos: .utility)

  /// The focused app's context by identity alone: no window-list scan, which
  /// the ambient location path used to run three times per focus change.
  private func focusedIdentityContext() -> AppContext? {
    currentNonFlashRunningApplication().flatMap { monitor.makeContext(for: $0) }
  }

  /// Only a changed selection can add a stop. Other catalog publications must
  /// not replay an old selected tab while a direct navigation is settling.
  @discardableResult
  func recordPublishedLocations(_ candidates: [Candidate], processID: pid_t) -> Bool {
    let selected = candidates.filter {
      $0.pid == processID && $0.isLocation && $0.isCurrentLocation && $0.kind != .app
    }
    let keyed = selected.compactMap { candidate -> (String, Candidate)? in
      guard let identity = movementIdentity(.candidate(candidate)) else { return nil }
      return (identity.key, candidate)
    }
    switch movementHistory.noteSelection(Set(keyed.map(\.0)), pid: processID) {
    case .unchanged:
      return true
    case .ambiguous:
      return false
    case .selected(let key):
      guard let candidate = keyed.first(where: { $0.0 == key })?.1 else { return false }
      recordAmbientLocation(candidate, processID: processID, source: "location_catalog")
      return true
    }
  }

  /// Record where focus landed once it settles. Each focus change re-arms
  /// one deadline on the shared clock (the token still discards a resolution
  /// already in flight). `.normal`: movement history is bookkeeping nobody
  /// watches, but `ctrl-o` right after a switch should find it recorded.
  func scheduleAmbientLocationRecord(pid: pid_t, reason: String) {
    ambientLocationRecordToken &+= 1
    let token = ambientLocationRecordToken
    ambientLocationRecord.arm(afterMs: 250) { [weak self] in
      guard let self, self.ambientLocationRecordToken == token else { return }
      guard let context = self.focusedIdentityContext(), context.processID == pid else { return }
      self.resolveAmbientLocation(
        in: context,
        source: reason,
        token: token,
        retryAfterAppFallback: true)
    }
  }

  /// Resolve source-specific locations from one ephemeral plugin snapshot, then
  /// perform the Accessibility fallback on the AX queue. The host retains
  /// neither plugin rows nor the aggregate after this completion.
  private func resolveAmbientLocation(
    in context: AppContext,
    source: String,
    token: UInt64,
    retryAfterAppFallback: Bool
  ) {
    resolveCurrentLocation(in: context) { [weak self] location in
      guard let self, self.ambientLocationRecordToken == token else { return }
      guard self.currentNonFlashRunningApplication()?.processIdentifier == context.processID
      else { return }

      let recordedPreciseLocation = self.recordAmbientLocation(
        location,
        processID: context.processID,
        source: source)
      guard retryAfterAppFallback, !recordedPreciseLocation else { return }

      self.ambientLocationRecord.arm(afterMs: 750) { [weak self] in
        guard let self, self.ambientLocationRecordToken == token else { return }
        guard
          let retryContext = self.focusedIdentityContext(),
          retryContext.processID == context.processID
        else { return }
        self.resolveAmbientLocation(
          in: retryContext,
          source: "\(source)_retry",
          token: token,
          retryAfterAppFallback: false)
      }
    }
  }

  /// Read the warm location catalogs (built-ins + the plugin catalog store)
  /// and run the AX-dependent URL disambiguation serialized on AppMonitor's
  /// queue, both off main. Completion returns to main.
  private func resolveCurrentLocation(
    in context: AppContext,
    completion: @escaping (Candidate?) -> Void
  ) {
    let registry: SourceRegistry = self.registry
    monitor.axQueue.async {
      let candidates = registry.locationSnapshotCandidates(scope: .all)
      let location = registry.currentLocation(in: context, candidates: candidates)
      DispatchQueue.main.async {
        completion(location)
      }
    }
  }

  @discardableResult
  func recordAmbientLocation(
    _ location: Candidate?,
    processID: pid_t,
    source: String
  ) -> Bool {
    if let location {
      recordMovement(.candidate(location), source: source, isAmbient: true)
      return location.kind != .app
    } else {
      recordMovement(.app(pid: processID), source: source, isAmbient: true)
      return false
    }
  }

  func navigateMovementHistory(direction: NavigationDirection) {
    ambientLocationRecordToken &+= 1
    movementLocationResolutionGeneration &+= 1
    let generation = movementLocationResolutionGeneration
    if movementHistory.isSettling {
      finishNavigateMovementHistory(direction: direction, current: movementHistory.current)
      return
    }
    currentMovementEntry { [weak self] current in
      guard let self, generation == self.movementLocationResolutionGeneration else { return }
      self.finishNavigateMovementHistory(direction: direction, current: current)
    }
  }

  private func finishNavigateMovementHistory(
    direction: NavigationDirection,
    current: MovementEntry?
  ) {
    guard let target = takeMovementHistoryTarget(direction: direction, current: current) else {
      applyModeOverlay()
      return
    }
    restoreMovement(target)
  }

  func takeMovementHistoryTarget(
    direction: NavigationDirection,
    current: MovementEntry?
  ) -> MovementEntry? {
    let label = direction == .back ? "back" : "forward"
    guard
      let target = movementHistory.take(direction, from: current, identify: movementIdentity)
    else {
      FlashLog.debug("[movement] no \(label) target")
      return nil
    }
    FlashLog.debug(
      "[movement] navigate \(label) target=\(movementHistory.settlingKey ?? target.key)")
    return target
  }

  private func currentMovementEntry(completion: @escaping (MovementEntry?) -> Void) {
    if let context = focusedIdentityContext() {
      resolveCurrentLocation(in: context) { [weak self] location in
        guard let self,
          self.currentNonFlashRunningApplication()?.processIdentifier == context.processID
        else {
          completion(nil)
          return
        }
        if let location {
          completion(.candidate(location))
        } else {
          completion(.app(pid: context.processID))
        }
      }
      return
    }
    if let current = movementHistory.current {
      completion(current)
      return
    }
    if let pid = normalModeTargetPID {
      completion(.app(pid: pid))
      return
    }
    completion(nil)
  }

  private func restoreMovement(_ entry: MovementEntry) {
    switch entry.kind {
    case .app:
      guard let pid = entry.pid, let item = registry.candidate(forProcessID: pid) else {
        movementHistory.stopSettling()
        applyModeOverlay()
        return
      }
      openSourceItem(
        item, recordMovement: false, movementGeneration: movementLocationResolutionGeneration)
    case .candidate:
      guard let candidate = entry.candidate else {
        movementHistory.stopSettling()
        applyModeOverlay()
        return
      }
      if let navigationURL = candidate.navigationURL,
        registry.canRestoreNavigation(to: navigationURL)
      {
        restoreNavigation(navigationURL, fallback: candidate, pid: candidate.pid)
      } else {
        openSourceItem(
          candidate, recordMovement: false, movementGeneration: movementLocationResolutionGeneration
        )
      }
    case .route:
      guard let navigationURL = entry.navigationURL else {
        movementHistory.stopSettling()
        applyModeOverlay()
        return
      }
      restoreNavigation(navigationURL, fallback: nil, pid: entry.pid)
    }
  }

  private func restoreNavigation(_ url: URL, fallback: Candidate?, pid: pid_t?) {
    let generation = movementLocationResolutionGeneration
    registry.restoreNavigation(to: url) { [weak self] result in
      guard let self, self.movementLocationResolutionGeneration == generation else { return }
      switch result.disposition {
      case .performed:
        let targetPID = result.targetPID ?? pid
        if let targetPID,
          let app = NSRunningApplication(processIdentifier: targetPID),
          !app.isTerminated
        {
          RunningApplicationActivation.activate(app, options: [.activateAllWindows])
          self.normalModeTargetPID = targetPID
        }
        if let route = result.navigationURL {
          self.movementHistory.arrive(
            at: .route(route, pid: targetPID), identify: self.movementIdentity)
        }
        self.scheduleNormalModeRecapture()
      case .failed:
        self.movementHistory.stopSettling()
        FlashLog.warn("[movement] route restore failed scheme=\(url.scheme ?? "nil")")
        self.scheduleNormalModeRecapture()
      case .unhandled:
        if let fallback {
          self.openSourceItem(
            fallback, recordMovement: false, movementGeneration: generation)
        } else {
          self.movementHistory.stopSettling()
          FlashLog.debug("[movement] route restore unhandled scheme=\(url.scheme ?? "nil")")
          self.applyModeOverlay()
        }
      }
    }
  }

  func movementIdentity(_ entry: MovementEntry) -> MovementIdentity? {
    switch entry.kind {
    case .app:
      guard let pid = entry.pid, pid > 0,
        let candidate = registry.candidate(forProcessID: pid)
      else { return nil }
      return Self.appMovementIdentity(candidate)
    case .candidate:
      guard let candidate = entry.candidate else { return nil }
      if let navigationURL = candidate.navigationURL,
        registry.canRestoreNavigation(to: navigationURL)
      {
        return MovementIdentity(key: Self.navigationMovementKey(navigationURL))
      }
      if candidate.kind == .app {
        return Self.appMovementIdentity(candidate)
      }
      guard registry.source(identifier: candidate.sourceID) != nil else { return nil }
      if candidate.isLocation {
        if let url = candidate.url {
          return MovementIdentity(key: Self.locationMovementKey(url))
        }
        return MovementIdentity(key: entry.key)
      }
      if let pid = candidate.pid, NSRunningApplication(processIdentifier: pid) == nil {
        return nil
      }
      return MovementIdentity(key: entry.key)
    case .route:
      guard let navigationURL = entry.navigationURL,
        registry.canRestoreNavigation(to: navigationURL)
      else { return nil }
      return MovementIdentity(key: Self.navigationMovementKey(navigationURL))
    }
  }

  private static func navigationMovementKey(_ url: URL) -> String {
    "route:\(url.absoluteString)"
  }

  private static func locationMovementKey(_ url: URL) -> String {
    "location:\(url.absoluteString)"
  }

  private static func appMovementIdentity(_ candidate: Candidate) -> MovementIdentity? {
    if !candidate.bundleIdentifier.isEmpty {
      return MovementIdentity(key: "app.bundle:\(candidate.bundleIdentifier)")
    }
    if let path = candidate.url?.standardizedFileURL.path, !path.isEmpty {
      return MovementIdentity(key: "app.path:\(path)")
    }
    if let pid = candidate.pid, pid > 0 {
      return MovementIdentity(key: "app.pid:\(pid)")
    }
    return nil
  }

  func currentNonFlashContext() -> AppContext? {
    let flashBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.flash.app"
    return monitor.frontmostContext(excludingBundleIdentifier: flashBundleIdentifier)
  }

  /// `currentNonFlashContext()`'s process, for window verbs: the frontmost
  /// app reads no window list on main.
  func currentNonFlashProcessID() -> pid_t? {
    let flashBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.flash.app"
    return monitor.frontmostProcessID(excludingBundleIdentifier: flashBundleIdentifier)
  }

  /// `currentNonFlashContext()` with the covering dialog resolved from the
  /// same window-list read, for hint activations.
  func currentNonFlashActivationContext() -> AppContext? {
    currentNonFlashActivationTarget()?.context
  }

  /// The activation's app with the window list that chose it.
  func currentNonFlashActivationTarget() -> AppMonitor.ActivationTarget? {
    let flashBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.flash.app"
    return monitor.activationTarget(excludingBundleIdentifier: flashBundleIdentifier)
  }

  func focusedAboutContext() -> AppContext? {
    guard let frame = statusItemController.focusedAboutWindowFrame,
      let app = NSRunningApplication(processIdentifier: getpid())
    else { return nil }
    return monitor.makeContext(for: app, frontWindowFrame: frame)
  }

  func currentDirectNonFlashContext() -> AppContext? {
    let flashBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.flash.app"
    return monitor.frontmostApplicationContext(excludingBundleIdentifier: flashBundleIdentifier)
  }

  func currentNonFlashContext(at point: CGPoint) -> AppContext? {
    let flashBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.flash.app"
    return monitor.context(at: point, excludingBundleIdentifier: flashBundleIdentifier)
  }
}
