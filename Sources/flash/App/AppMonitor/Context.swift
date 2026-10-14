import AppKit
import ApplicationServices
import FlashCore

/// Focused-app context resolution: turns workspace + WindowServer data
/// into the `AppContext` values that activation discovery and the
/// prepared-model builder consume. Handles "front-most app", "front-most
/// excluding Flash itself", and per-pid lookup.
extension AppMonitor {
  func currentContext() -> AppContext? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return makeContext(for: app)
  }

  func frontmostContext(excludingBundleIdentifier ignoredBundleIdentifier: String) -> AppContext? {
    if let context = frontmostApplicationContext(
      excludingBundleIdentifier: ignoredBundleIdentifier)
    {
      return context
    }
    return topVisibleWindowContext(excludingBundleIdentifier: ignoredBundleIdentifier)
  }

  func frontmostApplicationContext(
    excludingBundleIdentifier ignoredBundleIdentifier: String
  ) -> AppContext? {
    guard let context = currentContext(),
      context.bundleIdentifier != ignoredBundleIdentifier
    else { return nil }
    return clip(context, to: topWindowFrame(for: context.processID) ?? context.frontWindowFrame)
  }

  /// What a hint activation walks, with the window list that chose it, so
  /// the prepared-model lookup reads none of its own.
  struct ActivationTarget {
    let context: AppContext
    let windowEntries: [WindowSnapshot.Entry]?
  }

  func activationContext(excludingBundleIdentifier ignoredBundleIdentifier: String) -> AppContext? {
    activationTarget(excludingBundleIdentifier: ignoredBundleIdentifier)?.context
  }

  /// The app a hint activation walks: the frontmost app clipped to its top
  /// window (else the top visible window's app), or the dialog covering it.
  /// One window-list read serves every step and the lookup after; each is a
  /// synchronous WindowServer round trip on main.
  func activationTarget(excludingBundleIdentifier ignoredBundleIdentifier: String)
    -> ActivationTarget?
  {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let entries = WindowSnapshot.windowList(opts).map {
      WindowSnapshot.entries(from: $0, primaryH: primaryScreenHeight())
    }
    let base: AppContext?
    if let context = currentContext(), context.bundleIdentifier != ignoredBundleIdentifier {
      let top = entries.flatMap { Self.topWindowFrame(entries: $0, pid: context.processID) }
      base = clip(context, to: top ?? context.frontWindowFrame)
    } else if let entries {
      base = topVisibleWindowContext(
        entries: entries, excludingBundleIdentifier: ignoredBundleIdentifier)
    } else {
      base = nil
    }
    guard let base else { return nil }
    guard let entries else { return ActivationTarget(context: base, windowEntries: nil) }
    return ActivationTarget(
      context: coveringInteractionContext(inFrontOf: base, entries: entries) ?? base,
      windowEntries: entries)
  }

  func context(for pid: pid_t) -> AppContext? {
    guard pid > 0,
      let app = NSRunningApplication(processIdentifier: pid)
    else { return nil }
    guard let context = makeContext(for: app) else { return nil }
    return clip(context, to: topWindowFrame(for: pid) ?? context.frontWindowFrame)
  }

  func appWindowContext(for pid: pid_t) -> AppContext? {
    guard pid > 0,
      let app = NSRunningApplication(processIdentifier: pid)
    else { return nil }
    guard let context = makeContext(for: app) else { return nil }
    guard let frame = topApplicationWindowFrame(for: pid) else { return nil }
    return clip(context, to: frame)
  }

  func context(
    at point: CGPoint,
    excludingBundleIdentifier ignoredBundleIdentifier: String
  ) -> AppContext? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = WindowSnapshot.windowList(opts)
    else { return nil }
    guard
      let entry = WindowSnapshot.topInteractionEntry(
        at: point,
        entries: WindowSnapshot.entries(from: info, primaryH: primaryScreenHeight()),
        ignoringPids: [getpid()])
    else { return nil }
    guard let app = NSRunningApplication(processIdentifier: entry.pid),
      !app.isTerminated,
      app.bundleIdentifier != ignoredBundleIdentifier,
      !Self.systemChromeBundleIdentifiers.contains(app.bundleIdentifier ?? "")
    else { return nil }
    return makeContext(for: app, frontWindowFrame: entry.nsBounds)
  }

  func clip(
    _ context: AppContext, to frame: CGRect, walkedWindow: AXUIElement? = nil
  ) -> AppContext {
    AppContext(
      bundleIdentifier: context.bundleIdentifier,
      processID: context.processID,
      runningApp: context.runningApp,
      frontWindowFrame: frame.isNull ? context.frontWindowFrame : frame,
      allScreensFrame: context.allScreensFrame,
      walkRoot: context.walkRoot,
      walkedWindow: walkedWindow ?? context.walkedWindow
    )
  }

  func union(of rects: [CGRect]) -> CGRect {
    var out: CGRect = .null
    for rect in rects { out = out.union(rect) }
    return out
  }

  func primaryScreenHeight() -> CGFloat {
    ScreenSpace.primaryHeight
  }

  /// Push runtime config that should take effect on the next activation.
  func configureRuntime(for cfg: Config) {
    FlashLog.setLevel(cfg.debug.logLevel)
  }

  // MARK: Context

  func makeContext(
    for app: NSRunningApplication,
    frontWindowFrame: CGRect? = nil
  ) -> AppContext? {
    let pid = app.processIdentifier
    guard pid > 0 else { return nil }

    var screenFrame: CGRect = .null
    for s in NSScreen.screens { screenFrame = screenFrame.union(s.frame) }
    if screenFrame.isNull { screenFrame = .zero }

    // Deliberately no AX IPC here. `makeContext` runs on the main thread
    // every time the user activates, and a single kAXFocusedWindowAttribute
    // call on a cold AX server can add 100-300 ms of latency to the
    // overlay appearing. The AX queue builds a WindowServer visibility
    // snapshot and passes a clipped context to providers, so the
    // centre-in-visible check works without needing a precomputed AX
    // window frame from main.
    let windowFrame = frontWindowFrame ?? screenFrame
    return AppContext(
      bundleIdentifier: app.bundleIdentifier ?? "",
      processID: pid,
      runningApp: app,
      frontWindowFrame: windowFrame,
      allScreensFrame: screenFrame
    )
  }

  private func topWindowFrame(for pid: pid_t) -> CGRect? {
    Self.topWindowFrame(for: pid, primaryH: primaryScreenHeight())
  }

  /// Thread-safe (pure WindowServer + `WindowSnapshot`) so callers can resolve
  /// geometry on `geometryQueue`; `primaryH` is read on main beforehand.
  static func topWindowFrame(for pid: pid_t, primaryH: CGFloat) -> CGRect? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = WindowSnapshot.windowList(opts)
    else { return nil }
    return topWindowFrame(entries: WindowSnapshot.entries(from: info, primaryH: primaryH), pid: pid)
  }

  static func topWindowFrame(entries: [WindowSnapshot.Entry], pid: pid_t) -> CGRect? {
    // Match `WindowSnapshot.build`: a layer-0 card anchored over the app's main
    // window (Firefox tab-hover preview) shouldn't become the front window frame.
    let layer0App = entries.filter { $0.layer == 0 && $0.pid == pid && $0.pid != getpid() }
      .map(\.nsBounds)
    return entries.first {
      WindowSnapshot.isInteractionSurfaceLayer($0.layer)
        && $0.pid == pid
        && $0.pid != getpid()
        && !($0.layer == 0 && WindowSnapshot.isAnchoredCard($0.nsBounds, amongLayer0App: layer0App))
    }?
    .nsBounds
  }

  private func topApplicationWindowFrame(for pid: pid_t) -> CGRect? {
    Self.topApplicationWindowFrame(for: pid, primaryH: primaryScreenHeight())
  }

  /// Thread-safe counterpart of `appWindowContext(for:)`'s frame lookup.
  static func topApplicationWindowFrame(for pid: pid_t, primaryH: CGFloat) -> CGRect? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = WindowSnapshot.windowList(opts)
    else { return nil }
    return WindowSnapshot.topApplicationWindowFrame(
      entries: WindowSnapshot.entries(from: info, primaryH: primaryH),
      focusedPid: pid)
  }

  private func topVisibleWindowContext(
    excludingBundleIdentifier ignoredBundleIdentifier: String
  ) -> AppContext? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = WindowSnapshot.windowList(opts)
    else { return nil }
    return topVisibleWindowContext(
      entries: WindowSnapshot.entries(from: info, primaryH: primaryScreenHeight()),
      excludingBundleIdentifier: ignoredBundleIdentifier)
  }

  private func topVisibleWindowContext(
    entries: [WindowSnapshot.Entry], excludingBundleIdentifier ignoredBundleIdentifier: String
  ) -> AppContext? {
    for entry in entries {
      guard WindowSnapshot.isInteractionSurfaceLayer(entry.layer),
        entry.pid > 0,
        entry.pid != getpid(),
        let app = NSRunningApplication(processIdentifier: entry.pid),
        !app.isTerminated,
        app.bundleIdentifier != ignoredBundleIdentifier,
        !Self.systemChromeBundleIdentifiers.contains(app.bundleIdentifier ?? "")
      else { continue }
      return makeContext(for: app, frontWindowFrame: entry.nsBounds)
    }
    return nil
  }

  private static let systemChromeBundleIdentifiers: Set<String> = [
    "com.apple.controlcenter",
    "com.apple.dock",
    "com.apple.notificationcenterui",
    "com.apple.systemuiserver",
  ]

  /// Processes that present a dialog without reliably becoming the frontmost
  /// app. CoreServicesUIAgent can still report a regular activation policy
  /// (it takes a Dock icon while it is verifying), so policy alone would
  /// treat its card as the app-switch lag `WindowSnapshot` repairs.
  static let systemDialogBundleIdentifiers: Set<String> = [
    "com.apple.coreservices.uiagent",
    "com.apple.SecurityAgent",
    "com.apple.LocalAuthentication.UIAgent",
  ]

  /// A window in front of `front` that is the thing the user is looking at
  /// but whose process did not become the frontmost app: Gatekeeper's card,
  /// an authentication panel, a modal sheet owned by an agent. `f` walks it.
  /// Picture in Picture, Stage Manager, menu-bar strips, and another regular
  /// app's ordinary window are not that surface.
  func coveringInteractionContext(inFrontOf front: AppContext?) -> AppContext? {
    guard let front else { return nil }
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = WindowSnapshot.windowList(opts) else { return nil }
    return coveringInteractionContext(
      inFrontOf: front, entries: WindowSnapshot.entries(from: info, primaryH: primaryScreenHeight())
    )
  }

  func coveringInteractionContext(
    inFrontOf front: AppContext, entries: [WindowSnapshot.Entry]
  ) -> AppContext? {
    var screen: CGRect = .null
    for candidate in NSScreen.screens where candidate.frame.intersects(front.frontWindowFrame) {
      screen = candidate.frame
      break
    }
    if screen.isNull { screen = NSScreen.main?.frame ?? front.allScreensFrame }
    guard
      let entry = Self.coveringInteractionWindow(
        entries: entries,
        frontPid: front.processID,
        screen: screen,
        ignoringPids: [getpid()],
        owner: { pid in
          guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
            let bundleIdentifier = app.bundleIdentifier
          else { return nil }
          return CoveringInteractionOwner(
            bundleIdentifier: bundleIdentifier, isRegularApp: app.activationPolicy == .regular)
        }
      )
    else { return nil }
    guard let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated
    else { return nil }
    FlashLog.debug(
      "[activation] covering_window pid=\(entry.pid) "
        + "bundle=\(app.bundleIdentifier ?? "") layer=\(entry.layer)")
    return AppContext(
      bundleIdentifier: app.bundleIdentifier ?? "",
      processID: entry.pid,
      runningApp: app,
      frontWindowFrame: entry.nsBounds,
      allScreensFrame: front.allScreensFrame,
      walkRoot: .elementsInFrame)
  }
}

/// Owner facts `coveringInteractionWindow` needs. Resolved by the caller so
/// the choice itself stays a pure function of the window list.
struct CoveringInteractionOwner: Equatable {
  var bundleIdentifier: String
  var isRegularApp: Bool
}

extension AppMonitor {
  /// Smallest window that is a dialog rather than a tooltip, menu row, or
  /// hover card. Gatekeeper's card and the standard alert are both larger.
  static let minimumCoveringWidth: CGFloat = 180
  static let minimumCoveringHeight: CGFloat = 100

  /// The front-most interaction window above `frontPid` that hint activation
  /// should walk instead of the frontmost app.
  ///
  /// Scan stops at `frontPid`'s own window and at another regular app's
  /// normal-level window. That second case is the z-order lag
  /// `WindowSnapshot` already repairs after an app switch; treating it as a
  /// dialog would hint the app the user just left. A normal-level window of
  /// a non-regular process, or of a known system-dialog process such as
  /// CoreServicesUIAgent, and any elevated dialog-sized window are the
  /// surface. Picture in Picture, Stage Manager, system chrome,
  /// and menu-bar status strips are skipped so they stay out of `f`.
  static func coveringInteractionWindow(
    entries: [WindowSnapshot.Entry],
    frontPid: pid_t,
    screen: CGRect,
    ignoringPids: Set<pid_t> = [],
    owner ownerOf: (pid_t) -> CoveringInteractionOwner?
  ) -> WindowSnapshot.Entry? {
    let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
    let floatingLayer = Int(CGWindowLevelForKey(.floatingWindow))
    let screenArea = screen.width * screen.height
    for entry in entries {
      guard WindowSnapshot.isInteractionSurfaceLayer(entry.layer), entry.occludes,
        entry.pid > 0, !ignoringPids.contains(entry.pid)
      else { continue }
      if entry.pid == frontPid { return nil }
      if entry.layer == statusLayer { continue }
      guard let owner = ownerOf(entry.pid) else { continue }
      if systemChromeBundleIdentifiers.contains(owner.bundleIdentifier) { continue }
      if owner.bundleIdentifier == ScreenScopeSurfaces.pictureInPictureBundleID
        || owner.bundleIdentifier == ScreenScopeSurfaces.stageManagerBundleID
      {
        continue
      }
      if isFloatingPlayer(
        entry, regularApp: owner.isRegularApp, floatingLayer: floatingLayer, screenArea: screenArea)
      {
        continue
      }
      let dialogSized =
        entry.nsBounds.width >= minimumCoveringWidth
        && entry.nsBounds.height >= minimumCoveringHeight
      if entry.layer == 0 {
        let systemDialog = systemDialogBundleIdentifiers.contains(owner.bundleIdentifier)
        if owner.isRegularApp, !systemDialog { return nil }
        if dialogSized { return entry }
        continue
      }
      if dialogSized { return entry }
    }
    return nil
  }

  /// A regular app's small floating window is a Picture in Picture player
  /// (the same shape `ScreenScopeSurfaces` already treats as one). It stays
  /// above the focused app without being the window `f` should switch to.
  private static func isFloatingPlayer(
    _ entry: WindowSnapshot.Entry, regularApp: Bool, floatingLayer: Int, screenArea: CGFloat
  ) -> Bool {
    guard regularApp, entry.layer == floatingLayer, screenArea > 0 else { return false }
    let frame = entry.nsBounds
    let small = frame.width * frame.height <= screenArea * ScreenScopeSurfaces.maxAreaFraction
    return small && min(frame.width, frame.height) >= ScreenScopeSurfaces.minPlayerSide
  }
}
