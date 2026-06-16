import AppKit
import FlashCore

/// Vim-style marks: `m<letter>` records the focused app at the moment
/// the user pressed it; `` `<letter> `` re-activates that app. PIDs
/// aren't stable across launches, so the bundle ID is the durable
/// handle and the pid is the fast-path lookup.
extension AppDelegate {
  // MARK: Vim-style marks

  func setMark(letter: String) {
    guard let key = Self.normalizedMarkKey(letter) else {
      FlashLog.debug("[marks] reject set letter=\(letter) reason=invalid")
      return
    }
    guard let context = normalModeContext() ?? currentNonFlashContext() else {
      FlashLog.debug("[marks] set letter=\(key) reason=no_focused_app")
      return
    }
    marks[key] = MarkState(
      bundleID: context.bundleIdentifier,
      pid: context.processID,
      recordedAt: Date())
    FlashLog.debug(
      "[marks] set letter=\(key) bundle=\(context.bundleIdentifier) pid=\(context.processID)")
    scheduleNormalModeRecapture()
  }

  func jumpToMark(letter: String) {
    guard let key = Self.normalizedMarkKey(letter) else {
      FlashLog.debug("[marks] reject jump letter=\(letter) reason=invalid")
      return
    }
    guard let mark = marks[key] else {
      FlashLog.debug("[marks] jump letter=\(key) reason=unset")
      return
    }
    if let runningApp = NSRunningApplication(processIdentifier: mark.pid),
      !runningApp.isTerminated
    {
      FlashLog.debug("[marks] jump letter=\(key) pid=\(mark.pid)")
      RunningApplicationActivation.activate(runningApp, options: [.activateAllWindows])
      normalModeTargetPID = mark.pid
      scheduleNormalModeRecapture()
      return
    }
    // PID dead → fall back to the durable bundle identifier so a
    // restarted app still answers the jump.
    if let fallback =
      NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == mark.bundleID && !$0.isTerminated
      })
    {
      FlashLog.debug(
        "[marks] jump_fallback letter=\(key) bundle=\(mark.bundleID) pid=\(fallback.processIdentifier)"
      )
      marks[key] = MarkState(
        bundleID: mark.bundleID, pid: fallback.processIdentifier, recordedAt: mark.recordedAt)
      RunningApplicationActivation.activate(fallback, options: [.activateAllWindows])
      normalModeTargetPID = fallback.processIdentifier
      scheduleNormalModeRecapture()
      return
    }
    FlashLog.debug("[marks] jump letter=\(key) reason=app_not_running bundle=\(mark.bundleID)")
  }

  private static func normalizedMarkKey(_ raw: String) -> Character? {
    let trimmed = raw.trimmed
    guard let ch = trimmed.first, trimmed.count == 1, ch.isLetter || ch.isNumber else {
      return nil
    }
    return Character(ch.lowercased())
  }

  func navigateAppMRU(direction: NavigationDirection) {
    var source: [pid_t]
    var destination: [pid_t]
    switch direction {
    case .back:
      source = appBackStack
      destination = appForwardStack
    case .forward:
      source = appForwardStack
      destination = appBackStack
    }
    let flashBundleID = Bundle.main.bundleIdentifier
    while let candidate = source.popLast() {
      guard let app = NSRunningApplication(processIdentifier: candidate),
        !app.isTerminated,
        app.bundleIdentifier != flashBundleID
      else { continue }
      if let current = appCurrent, current != candidate {
        destination.append(current)
      }
      switch direction {
      case .back:
        appBackStack = source
        appForwardStack = destination
      case .forward:
        appForwardStack = source
        appBackStack = destination
      }
      appNavigationTargetPID = candidate
      appCurrent = candidate
      RunningApplicationActivation.activate(app, options: [.activateAllWindows])
      return
    }
    switch direction {
    case .back:
      appBackStack = source
    case .forward:
      appForwardStack = source
    }
  }

  func recordMovement(_ entry: MovementEntry, source: String) {
    guard let identity = movementIdentity(entry) else { return }
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

  func navigateMovementHistory(direction: NavigationDirection) {
    let current = currentMovementEntry()
    if let current { movementCurrent = current }

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
      restoreMovement(target)
      return
    }

    storeMovementStacks(source: sourceStack, destination: destinationStack, direction: direction)
    pruneMovementStacks()
    FlashLog.debug("[movement] no \(label) target")
    applyModeOverlay()
  }

  private func currentMovementEntry() -> MovementEntry? {
    if let current = movementCurrent,
      let context = currentNonFlashContext(),
      current.pid == context.processID
    {
      return current
    }
    if let context = currentNonFlashContext() {
      return .app(pid: context.processID)
    }
    if let current = movementCurrent {
      return current
    }
    if let pid = normalModeTargetPID {
      return .app(pid: pid)
    }
    return nil
  }

  private func restoreMovement(_ entry: MovementEntry) {
    switch entry.kind {
    case .app:
      guard let pid = entry.pid, let item = registry.candidate(forProcessID: pid) else {
        applyModeOverlay()
        return
      }
      openSourceItem(item, recordMovement: false)
    case .candidate:
      guard let candidate = entry.candidate else {
        applyModeOverlay()
        return
      }
      if let navigationURL = candidate.navigationURL,
        registry.canRestoreNavigation(to: navigationURL)
      {
        restoreNavigation(navigationURL, fallback: candidate, pid: candidate.pid)
      } else {
        openSourceItem(candidate, recordMovement: false)
      }
    case .route:
      guard let navigationURL = entry.navigationURL else {
        applyModeOverlay()
        return
      }
      restoreNavigation(navigationURL, fallback: nil, pid: entry.pid)
    }
  }

  private func restoreNavigation(_ url: URL, fallback: Candidate?, pid: pid_t?) {
    registry.restoreNavigation(to: url) { [weak self] result in
      guard let self else { return }
      switch result.disposition {
      case .performed:
        let targetPID = result.targetPID ?? pid
        if let targetPID,
          let app = NSRunningApplication(processIdentifier: targetPID),
          !app.isTerminated
        {
          RunningApplicationActivation.activate(app, options: [.activateAllWindows])
          self.normalModeTargetPID = targetPID
          self.suppressEditableFocus(for: targetPID)
        }
        if let route = result.navigationURL {
          self.movementCurrent = .route(route, pid: targetPID)
        }
        self.scheduleNormalModeRecapture()
      case .failed:
        FlashLog.warn("[movement] route restore failed url=\(url.absoluteString)")
        self.scheduleNormalModeRecapture()
      case .unhandled:
        if let fallback {
          self.openSourceItem(fallback, recordMovement: false)
        } else {
          FlashLog.debug("[movement] route restore unhandled url=\(url.absoluteString)")
          self.applyModeOverlay()
        }
      }
    }
  }

  private func appendMovementEntry(_ entry: MovementEntry, to stack: inout [MovementEntry]) {
    guard let identity = movementIdentity(entry) else { return }
    stack.removeAll { existing in
      guard let existingIdentity = movementIdentity(existing) else { return true }
      return existingIdentity.key == identity.key
    }
    stack.append(entry)
    if stack.count > 20 {
      stack.removeFirst(stack.count - 20)
    }
  }

  private func movementEntriesShareActivation(
    _ current: MovementEntry,
    _ next: MovementEntry
  ) -> Bool {
    current.kind != .app
      && next.kind == .app
      && current.pid != nil
      && current.pid == next.pid
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
      if let pid = candidate.pid, NSRunningApplication(processIdentifier: pid) == nil {
        return nil
      }
      guard registry.source(identifier: candidate.sourceID) != nil else { return nil }
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
}
