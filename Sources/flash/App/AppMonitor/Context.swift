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

  /// The process `frontmostContext` resolves to, without its frame: a
  /// window verb acts on an app, not on a clip rect. The frontmost app costs
  /// no window-list read; only the fallback to the top visible window's app,
  /// when Flash itself is frontmost, reads one.
  func frontmostProcessID(excludingBundleIdentifier ignoredBundleIdentifier: String) -> pid_t? {
    Self.windowVerbTargetPID(
      frontmost: NSWorkspace.shared.frontmostApplication.map {
        (pid: $0.processIdentifier, bundleIdentifier: $0.bundleIdentifier)
      },
      excludingBundleIdentifier: ignoredBundleIdentifier,
      topVisible: {
        self.topVisibleWindowContext(excludingBundleIdentifier: ignoredBundleIdentifier)?
          .processID
      })
  }

  static func windowVerbTargetPID(
    frontmost: (pid: pid_t, bundleIdentifier: String?)?,
    excludingBundleIdentifier ignoredBundleIdentifier: String,
    topVisible: () -> pid_t?
  ) -> pid_t? {
    if let frontmost, frontmost.pid > 0, frontmost.bundleIdentifier != ignoredBundleIdentifier {
      return frontmost.pid
    }
    return topVisible()
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
  /// the prepared-model lookup reads none of its own. `fallback` is the app a
  /// covering surface hides: walked instead when that surface has nothing to
  /// press (a volume or brightness display). `refusedBy` is an
  /// authentication prompt in front, which leaves nothing to walk.
  struct ActivationTarget {
    let context: AppContext
    let windowEntries: [WindowSnapshot.Entry]?
    var fallback: AppContext? = nil
    var refusedBy: String? = nil
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
      WindowSnapshot.entries(from: $0, primaryH: ScreenSpace.primaryHeight)
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
    switch coveringInteractionContext(inFrontOf: base, entries: entries) {
    case nil:
      return ActivationTarget(context: base, windowEntries: entries)
    case .surface(let covering)?:
      return ActivationTarget(context: covering, windowEntries: entries, fallback: base)
    case .refused(let bundleIdentifier)?:
      return ActivationTarget(context: base, windowEntries: entries, refusedBy: bundleIdentifier)
    }
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
        entries: WindowSnapshot.entries(from: info, primaryH: ScreenSpace.primaryHeight),
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
      allScreensFrame: context.allScreensFrame, displays: context.displays,
      walkRoot: context.walkRoot,
      walkedWindow: walkedWindow ?? context.walkedWindow,
      menus: context.menus
    )
  }

  func union(of rects: [CGRect]) -> CGRect {
    var out: CGRect = .null
    for rect in rects { out = out.union(rect) }
    return out
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

    let screens = OverlayPanel.currentScreenSnapshot()
    var screenFrame = screens.unionFrame
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
      allScreensFrame: screenFrame,
      displays: screens.screens.map { AppContext.Display(frame: $0.frame, scale: $0.scale) }
    )
  }

  private func topWindowFrame(for pid: pid_t) -> CGRect? {
    Self.topWindowFrame(for: pid, primaryH: ScreenSpace.primaryHeight)
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
    Self.topApplicationWindowFrame(for: pid, primaryH: ScreenSpace.primaryHeight)
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
      entries: WindowSnapshot.entries(from: info, primaryH: ScreenSpace.primaryHeight),
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
    "com.apple.coreservices.uiagent"
  ]

  /// Processes that ask for a password or Touch ID. Their prompt refuses
  /// hints: Flash walks and clicks neither it nor the window behind it, so no
  /// command — a mapping, or the CLI any local program can run — can answer
  /// an authentication prompt for the user.
  static let authenticationBundleIdentifiers: Set<String> = [
    "com.apple.SecurityAgent",
    "com.apple.LocalAuthentication.UIAgent",
  ]

  /// System processes whose windows draw above apps at levels of their own
  /// (Notification Center's panel at 21, the Dock's stacks and views at
  /// 17–20, Control Center's modules, Spotlight), and which of their windows
  /// is the surface `f` walks.
  enum SystemOverlay: Equatable {
    /// Notification Center: its panel, widgets and notifications included.
    /// A banner is transient and stays with `mouse notifications`.
    case notificationPanel
    /// The Dock: a stack, a menu or a view, never the bar itself.
    case dock
    /// Control Center's panel and modules, SystemUIServer's menus,
    /// Spotlight and the Apps view, the screenshot toolbar.
    case panel
  }

  static let systemOverlays: [String: SystemOverlay] = [
    "com.apple.notificationcenterui": .notificationPanel,
    "com.apple.dock": .dock,
    "com.apple.controlcenter": .panel,
    "com.apple.systemuiserver": .panel,
    "com.apple.Spotlight": .panel,
    "com.apple.screencaptureui": .panel,
  ]

  /// Smaller than a dialog and still the surface: the screenshot toolbar.
  static let minimumCoveringSizes: [String: CGSize] = [
    "com.apple.screencaptureui": CGSize(width: 200, height: 28)
  ]

  /// A Notification Center window this tall is its panel; banners are short.
  static let notificationPanelMinimumHeightFraction: CGFloat = 0.4
  /// A status-level window this short is a menu-bar strip or a status item;
  /// taller, it is a menu extra's popover.
  static let statusStripMaximumHeight: CGFloat = 50

  /// A window in front of `front` that is the thing the user is looking at
  /// but whose process did not become the frontmost app: Gatekeeper's card,
  /// a modal sheet owned by an agent, Notification Center's or Control
  /// Center's panel, a menu extra's popover, a Dock stack. `f` walks it.
  /// Picture in Picture, Stage Manager, menu-bar strips, notification
  /// banners, and another regular app's ordinary window are not that
  /// surface; an authentication prompt refuses hints altogether.
  func coveringInteractionContext(inFrontOf front: AppContext?) -> CoveringContext? {
    guard let front else { return nil }
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = WindowSnapshot.windowList(opts) else { return nil }
    return coveringInteractionContext(
      inFrontOf: front,
      entries: WindowSnapshot.entries(from: info, primaryH: ScreenSpace.primaryHeight)
    )
  }

  /// What a text or word activation walks over `base`: the covering surface,
  /// else `base`; nil while an authentication prompt is in front.
  func hintContext(inFrontOf base: AppContext) -> AppContext? {
    switch coveringInteractionContext(inFrontOf: base) {
    case nil: return base
    case .surface(let covering)?: return covering
    case .refused?: return nil
    }
  }

  func coveringInteractionContext(
    inFrontOf front: AppContext, entries: [WindowSnapshot.Entry]
  ) -> CoveringContext? {
    var screen: CGRect = .null
    for candidate in NSScreen.screens where candidate.frame.intersects(front.frontWindowFrame) {
      screen = candidate.frame
      break
    }
    if screen.isNull { screen = NSScreen.main?.frame ?? front.allScreensFrame }
    let surface = Self.coveringInteractionWindow(
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
    let entry: WindowSnapshot.Entry
    switch surface {
    case nil: return nil
    case .refused(let bundleIdentifier)?:
      FlashLog.debug("[activation] covering_refused bundle=\(bundleIdentifier)")
      return .refused(bundleIdentifier: bundleIdentifier)
    case .window(let window)?: entry = window
    }
    guard let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated
    else { return nil }
    FlashLog.debug(
      "[activation] covering_window pid=\(entry.pid) "
        + "bundle=\(app.bundleIdentifier ?? "") layer=\(entry.layer)")
    return .surface(
      AppContext(
        bundleIdentifier: app.bundleIdentifier ?? "",
        processID: entry.pid,
        runningApp: app,
        frontWindowFrame: entry.nsBounds,
        allScreensFrame: front.allScreensFrame, displays: front.displays,
        walkRoot: .elementsInFrame))
  }
}

/// What `f` walks when something covers the front app.
enum CoveringContext {
  case surface(AppContext)
  /// An authentication prompt is in front: nothing is walked or clicked.
  case refused(bundleIdentifier: String)
}

/// The covering decision over the window list alone.
enum CoveringSurface: Equatable {
  case window(WindowSnapshot.Entry)
  /// SecurityAgent's or LocalAuthentication's prompt: a password or Touch ID
  /// is asked for. Flash neither hints nor clicks it, nor the window behind.
  case refused(bundleIdentifier: String)

  var window: WindowSnapshot.Entry? {
    if case .window(let entry) = self { return entry }
    return nil
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
  ) -> CoveringSurface? {
    let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
    let floatingLayer = Int(CGWindowLevelForKey(.floatingWindow))
    // Lock and login shields draw at and above the screen saver.
    let overlayLayers = 0..<Int(CGWindowLevelForKey(.screenSaverWindow))
    let screenArea = screen.width * screen.height
    for entry in entries {
      guard entry.occludes, entry.pid > 0, !ignoringPids.contains(entry.pid) else { continue }
      let interactionLayer = WindowSnapshot.isInteractionSurfaceLayer(entry.layer)
      if entry.pid == frontPid {
        if interactionLayer { return nil }
        continue
      }
      if entry.layer == statusLayer, entry.nsBounds.height <= statusStripMaximumHeight {
        continue
      }
      guard let owner = ownerOf(entry.pid) else { continue }
      let bundle = owner.bundleIdentifier
      let minimum =
        minimumCoveringSizes[bundle]
        ?? CGSize(width: minimumCoveringWidth, height: minimumCoveringHeight)
      let dialogSized =
        entry.nsBounds.width >= minimum.width && entry.nsBounds.height >= minimum.height
      if authenticationBundleIdentifiers.contains(bundle) {
        guard overlayLayers.contains(entry.layer), dialogSized else { continue }
        return .refused(bundleIdentifier: bundle)
      }
      if let overlay = systemOverlays[bundle] {
        guard overlayLayers.contains(entry.layer), entry.nsBounds.intersects(screen), dialogSized
        else { continue }
        switch overlay {
        case .notificationPanel:
          guard entry.nsBounds.height >= screen.height * notificationPanelMinimumHeightFraction
          else { continue }
        case .dock:
          guard !isDockBar(entry.nsBounds, screen: screen) else { continue }
        case .panel:
          break
        }
        return .window(entry)
      }
      guard interactionLayer else { continue }
      if bundle == ScreenScopeSurfaces.pictureInPictureBundleID
        || bundle == ScreenScopeSurfaces.stageManagerBundleID
      {
        continue
      }
      if isFloatingPlayer(
        entry, regularApp: owner.isRegularApp, floatingLayer: floatingLayer, screenArea: screenArea)
      {
        continue
      }
      if entry.layer == 0 {
        let systemDialog = systemDialogBundleIdentifiers.contains(bundle)
        if owner.isRegularApp, !systemDialog { return nil }
        if dialogSized { return .window(entry) }
        continue
      }
      if dialogSized { return .window(entry) }
    }
    return nil
  }

  /// The Dock's bar: a thin window along a screen edge, at least a third of
  /// that edge long. Its stacks, menus and views are none of that.
  static func isDockBar(_ frame: CGRect, screen: CGRect) -> Bool {
    let slack: CGFloat = 8
    let horizontal =
      frame.height <= 160 && frame.width >= screen.width / 3
      && (abs(frame.minY - screen.minY) <= slack || abs(frame.maxY - screen.maxY) <= slack)
    let vertical =
      frame.width <= 160 && frame.height >= screen.height / 3
      && (abs(frame.minX - screen.minX) <= slack || abs(frame.maxX - screen.maxX) <= slack)
    return horizontal || vertical
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
