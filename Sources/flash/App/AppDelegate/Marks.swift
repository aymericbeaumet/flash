import AppKit
import FlashCore

// Vim-style marks live in `Plugins/marks/`. Activation routes through the
// host's `activatePluginCommandTarget` after the plugin returns
// `target_pid`, which is what scheduled the normal-mode recapture and
// updated `normalModeTargetPID` for the in-process version that lived
// here. The remaining helpers stay because app/movement navigation isn't
// plugin-shaped (yet).

extension AppDelegate {
  func navigateAppMRU(direction: NavigationDirection) {
    let flashBundleID = Bundle.main.bundleIdentifier
    let available: (pid_t) -> Bool = { pid in
      guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
      return !app.isTerminated && app.bundleIdentifier != flashBundleID
    }
    let initialNavigation = Self.appMRUNavigation(
      direction: direction,
      current: appCurrent,
      back: appBackStack,
      forward: appForwardStack,
      isAvailable: available)
    if initialNavigation == nil, let current = appCurrent {
      appBackStack = NSWorkspace.shared.runningApplications
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
        .map(\.processIdentifier)
      appForwardStack.removeAll(keepingCapacity: true)
      FlashLog.debug("[app_navigation] seeded running_apps=\(appBackStack.count)")
    }

    guard
      let navigation = initialNavigation
        ?? Self.appMRUNavigation(
          direction: direction,
          current: appCurrent,
          back: appBackStack,
          forward: appForwardStack,
          isAvailable: available),
      let app = NSRunningApplication(processIdentifier: navigation.target)
    else {
      FlashLog.debug("[app_navigation] no target direction=\(direction)")
      return
    }

    let previous = (
      back: appBackStack,
      forward: appForwardStack,
      target: appNavigationTargetPID,
      current: appCurrent
    )
    appBackStack = navigation.back
    appForwardStack = navigation.forward
    appNavigationTargetPID = navigation.target
    appCurrent = navigation.target
    guard RunningApplicationActivation.activate(app, options: [.activateAllWindows]) else {
      appBackStack = previous.back
      appForwardStack = previous.forward
      appNavigationTargetPID = previous.target
      appCurrent = previous.current
      FlashLog.warn(
        "[app_navigation] activation failed direction=\(direction) pid=\(navigation.target)")
      return
    }
    preparePendingApplicationActivation(app, reason: "app_navigation")
  }

  /// Treat the observed activation history as a ring. A normal activation
  /// appends to `back`; navigation partitions that same ring around its target,
  /// so either direction always has somewhere to go once two apps were seen.
  static func appMRUNavigation(
    direction: NavigationDirection,
    current: pid_t?,
    back: [pid_t],
    forward: [pid_t],
    isAvailable: (pid_t) -> Bool
  ) -> (target: pid_t, back: [pid_t], forward: [pid_t])? {
    guard let current else { return nil }

    var ordered: [pid_t] = []
    var seen = Set<pid_t>()
    for pid in back + [current] + forward.reversed()
    where isAvailable(pid) && seen.insert(pid).inserted {
      ordered.append(pid)
    }
    guard ordered.count > 1, let currentIndex = ordered.firstIndex(of: current) else {
      return nil
    }

    let targetIndex: Int
    switch direction {
    case .back:
      targetIndex = (currentIndex - 1 + ordered.count) % ordered.count
    case .forward:
      targetIndex = (currentIndex + 1) % ordered.count
    }
    return (
      target: ordered[targetIndex],
      back: Array(ordered[..<targetIndex]),
      forward: Array(ordered[ordered.index(after: targetIndex)...].reversed())
    )
  }

  func recordMovement(_ entry: MovementEntry, source: String, isAmbient: Bool = false) {
    guard let identity = movementIdentity(entry) else { return }
    if isAmbient, let target = movementNavigationTargetKey, target != identity.key {
      guard let current = movementCurrent, movementEntryIsApp(current),
        current.pid != nil, current.pid == entry.pid
      else { return }
    }
    if !isAmbient {
      movementLocationResolutionGeneration &+= 1
      movementNavigationTargetKey = nil
    }
    if movementNavigationTargetKey == identity.key {
      movementNavigationTargetKey = nil
      movementCurrent = entry
      pruneMovementStacks()
      FlashLog.trace(
        "[movement] activation target=\(identity.key) raw=\(entry.key) source=navigation")
      return
    }
    if let current = movementCurrent,
      let currentIdentity = movementIdentity(current),
      currentIdentity.key == identity.key
    {
      movementCurrent = entry
      movementNavigationTargetKey = nil
      pruneMovementStacks()
      FlashLog.trace(
        "[movement] coalesced source=\(source) current=\(identity.key) raw=\(entry.key)")
      return
    }
    if let current = movementCurrent,
      movementEntriesShareActivation(current, entry)
    {
      if movementEntryIsApp(current) { movementCurrent = entry }
      movementNavigationTargetKey = nil
      pruneMovementStacks()
      FlashLog.trace(
        "[movement] coalesced_activation source=\(source) current=\(identity.key) raw=\(entry.key)")
      return
    }
    if let current = movementCurrent {
      appendMovementEntry(current, to: &movementBackStack)
    }
    movementCurrent = entry
    movementForwardStack.removeAll(keepingCapacity: true)
    pruneMovementStacks()
    FlashLog.trace(
      "[movement] record source=\(source) current=\(identity.key) raw=\(entry.key) back=\(movementBackStack.count) "
        + "forward=\(movementForwardStack.count)")
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
    let keys = Set(keyed.map(\.0))
    let previous = movementCatalogSnapshot.flatMap { $0.pid == processID ? $0.keys : nil }
    guard previous != keys else { return true }
    movementCatalogSnapshot = (processID, keys)
    let added = keys.subtracting(previous ?? [])
    let choice = added.count == 1 ? added.first : keys.count == 1 ? keys.first : nil
    guard let choice, let candidate = keyed.first(where: { $0.0 == choice })?.1 else {
      return false
    }
    recordAmbientLocation(candidate, processID: processID, source: "location_catalog")
    return true
  }

  func scheduleAmbientLocationRecord(pid: pid_t, reason: String) {
    ambientLocationRecordToken &+= 1
    let token = ambientLocationRecordToken
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
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

      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(750)) { [weak self] in
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
    if movementNavigationTargetKey != nil {
      finishNavigateMovementHistory(direction: direction, current: movementCurrent)
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
    if let current { recordMovement(current, source: "navigation_origin", isAmbient: true) }
    let current = movementCurrent

    var sourceStack: [MovementEntry]
    var destinationStack: [MovementEntry]
    let label: String
    switch direction {
    case .back:
      sourceStack = movementBackStack
      destinationStack = movementForwardStack
      label = "back"
    case .forward:
      sourceStack = movementForwardStack
      destinationStack = movementBackStack
      label = "forward"
    }

    while let target = sourceStack.popLast() {
      guard movementEntryIsRestorable(target) else {
        continue
      }
      let targetIdentity = movementIdentity(target)
      if let current, movementIdentity(current) == targetIdentity { continue }
      if let current,
        let currentIdentity = movementIdentity(current),
        currentIdentity.key != targetIdentity?.key
      {
        appendMovementEntry(current, to: &destinationStack)
      }
      movementCurrent = target
      movementNavigationTargetKey = targetIdentity?.key
      storeMovementStacks(source: sourceStack, destination: destinationStack, direction: direction)
      FlashLog.debug("[movement] navigate \(label) target=\(targetIdentity?.key ?? target.key)")
      return target
    }

    storeMovementStacks(source: sourceStack, destination: destinationStack, direction: direction)
    pruneMovementStacks()
    FlashLog.debug("[movement] no \(label) target")
    return nil
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
    if let current = movementCurrent {
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
        movementNavigationTargetKey = nil
        applyModeOverlay()
        return
      }
      openSourceItem(
        item, recordMovement: false, movementGeneration: movementLocationResolutionGeneration)
    case .candidate:
      guard let candidate = entry.candidate else {
        movementNavigationTargetKey = nil
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
        movementNavigationTargetKey = nil
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
          self.movementCurrent = .route(route, pid: targetPID)
          self.movementNavigationTargetKey =
            self.movementCurrent.flatMap(self.movementIdentity)?.key
        }
        self.scheduleNormalModeRecapture()
      case .failed:
        self.movementNavigationTargetKey = nil
        FlashLog.warn("[movement] route restore failed scheme=\(url.scheme ?? "nil")")
        self.scheduleNormalModeRecapture()
      case .unhandled:
        if let fallback {
          self.openSourceItem(
            fallback, recordMovement: false, movementGeneration: generation)
        } else {
          self.movementNavigationTargetKey = nil
          FlashLog.debug("[movement] route restore unhandled scheme=\(url.scheme ?? "nil")")
          self.applyModeOverlay()
        }
      }
    }
  }

  private func appendMovementEntry(_ entry: MovementEntry, to stack: inout [MovementEntry]) {
    guard let identity = movementIdentity(entry) else { return }
    if let last = stack.last, movementIdentity(last) == identity { return }
    stack.append(entry)
    if stack.count > 20 {
      stack.removeFirst(stack.count - 20)
    }
  }

  private func movementEntriesShareActivation(
    _ current: MovementEntry,
    _ next: MovementEntry
  ) -> Bool {
    (movementEntryIsApp(current) || movementEntryIsApp(next))
      && current.pid != nil
      && current.pid == next.pid
  }

  private func movementEntryIsApp(_ entry: MovementEntry) -> Bool {
    entry.kind == .app || entry.candidate?.kind == .app
  }

  private func movementIdentity(_ entry: MovementEntry) -> MovementIdentity? {
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

  private func movementEntryIsRestorable(_ entry: MovementEntry) -> Bool {
    movementIdentity(entry) != nil
  }

  private func storeMovementStacks(
    source: [MovementEntry],
    destination: [MovementEntry],
    direction: NavigationDirection
  ) {
    switch direction {
    case .back:
      movementBackStack = source
      movementForwardStack = destination
    case .forward:
      movementForwardStack = source
      movementBackStack = destination
    }
  }

  func pruneMovementStacks() {
    movementBackStack.removeAll { !movementEntryIsRestorable($0) }
    movementForwardStack.removeAll { !movementEntryIsRestorable($0) }
  }

  func currentNonFlashContext() -> AppContext? {
    let flashBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.flash.app"
    return monitor.frontmostContext(excludingBundleIdentifier: flashBundleIdentifier)
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
