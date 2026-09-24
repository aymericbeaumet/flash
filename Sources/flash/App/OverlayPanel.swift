import AppKit
import FlashCore
import QuartzCore
import os

enum OverlayModeBadgeStyle {
  case insert
  case normal
  case command
}

/// What the overlay shows for the current mode, as one value. Only the mode
/// executor writes it (`setModeSurface`); the bar, the pill, the border colour
/// and capture all read it, so none of them can show a different mode.
struct ModeSurface: Equatable {
  /// The pill's text: the configured label for the mode.
  var label: String
  var style: OverlayModeBadgeStyle
  /// `[statusbar] enabled`: whether the bar window is on screen. The command
  /// line and the focus border render whether or not it is.
  var barVisible: Bool
  /// The overlay owns the keyboard as a command surface (idle NORMAL, the
  /// command line).
  var capturesInput: Bool

  static let initial = ModeSurface(
    label: "INSERT", style: .insert, barVisible: false, capturesInput: false)
}

struct CandidateDisplayItem: Equatable {
  var title: String
  var highlightedRanges: [Range<Int>] = []
  var isSelected: Bool
}

enum OverlayPointerIntent: Equatable {
  case click(OverlayPointerClick)
  case scroll
}

struct OverlayPointerClick: Equatable {
  var action: JumpAction
  var location: CGPoint
  var modifiers: ClickModifiers
  var flashWasActive: Bool = false
  /// The frontmost application's PID at the instant of the click (before the
  /// click could activate anything). When the clicked window belongs to a
  /// *different* app, macOS consumes this first click as a window-activation
  /// event and the control under the cursor never sees it — so Flash must
  /// re-synthesise it. `-1` when unknown.
  var frontmostPIDAtClick: pid_t = -1
}

extension NSScreen {
  /// The CoreGraphics display behind this screen; absent for virtual screens.
  var displayID: CGDirectDisplayID? {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }
}

final class CommandLineTextField: NSTextField {
  override var acceptsFirstResponder: Bool { true }
}

final class OverlayPanel: NSPanel {
  static let transientOverlayWindowLevel: NSWindow.Level = .screenSaver
  // The overlay panel's persistent content is the active-window focus border:
  // an ordinary elevated window above the focused app's normal windows but
  // below Spotlight, banners and the Dock, and still allowed to become key for
  // the no-tap key-window fallback (only `.statusBar`/25 is barred from key).
  static let persistentStatusWindowLevel: NSWindow.Level = .floating
  // The status bar lives in its own click-through window (`StatusBarWindow`)
  // above the native menu bar: app menus at the menu-bar window level 24,
  // extras at `.statusBar`/25, and the auto-hide reveal the system slides down
  // from y<0 at those same levels. A reveal Flash did not ask for — a menu key
  // equivalent flashing its title, Flash becoming active, a wake — therefore
  // slides in behind the bar instead of painting over it for a second.
  // The pointer is the one exception: while the probe sees the native bar
  // actually revealed under it, the window drops to
  // `statusBarYieldedWindowLevel` so reaching for the top edge still gets the
  // real menu bar (`setStatusBarYieldsToNativeMenuBar`).
  static let statusBarWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
  static let statusBarYieldedWindowLevel: NSWindow.Level = .floating
  // The click windows sit above the bar window: macOS only delivers
  // menu-bar-band clicks to windows at (or above) the menu-bar level — lower
  // windows get nothing and the click falls through to the desktop. The bar
  // window ignores mouse events, so the band's clicks reach them regardless.
  // They don't steal native clicks despite outranking the menu bar, because
  // they flip to click-through alongside the bar's yield.
  static let statusBarClickWindowLevel = NSWindow.Level(
    rawValue: NSWindow.Level.statusBar.rawValue + 2)
  static let candidateFinderHorizontalPadding: CGFloat = 8
  static let candidateFinderVerticalPadding: CGFloat = 7
  static let candidateFinderLineSpacing: CGFloat = 2
  /// Vertical gap between the command prompt's bottom edge and the top of
  /// the results panel below it.
  static let candidateFinderPromptGap: CGFloat = 6

  let contentLayer = CALayer()
  var hintLayers: [CAGradientLayer] = []
  var labelLayers: [CATextLayer] = []
  var hintLayerPool: [CAGradientLayer] = []
  var labelLayerPool: [CATextLayer] = []
  let modeBadgeLayer = CAGradientLayer()
  lazy var primaryStatusBarSurface = NativeStatusBarSurface(backgroundLayer: modeBadgeLayer)
  var secondaryStatusBars: [NativeStatusBarSurface] = []
  /// Hosts `modeBadgeLayer` and the secondary bars; see `syncStatusBarWindow`.
  let statusBarWindow: StatusBarWindow
  /// Which displays render the bar (`[statusbar] monitor`). `primary` skips the
  /// secondary (non-main) screen bars. Set by the AppDelegate on config load.
  var statusBarMonitor: Config.StatusBar.Monitor = .all {
    didSet { statusBarLayoutRevision &+= 1 }
  }
  /// Bumped whenever an input of the status-bar relayout changes; see
  /// `ModeBadgeLayoutStamp`.
  var statusBarLayoutRevision: UInt64 = 0
  var lastModeBadgeLayoutStamp: ModeBadgeLayoutStamp?
  /// One full-band click window per screen (the bar's visual lives on the
  /// click-through `statusBarWindow`, so these windows do the click work). They swallow
  /// band clicks so a click on the bar never reveals the desktop, and open a
  /// `#[link=…]` run when the click lands on one. Pooled + repositioned on
  /// render. See `StatusBarClickPanel`.
  var statusBarClickWindows: [StatusBarClickPanel] = []
  /// Signature of the currently-installed band + link rects, so an unchanged
  /// render skips reordering the click windows.
  var lastStatusBarClickSignature: String?
  /// Per-screen clickable and hover-popup rects in screen coordinates, rebuilt
  /// on every `configureModeBadge`. The `f` hint path uses the active window's
  /// screen so every meaningful status segment is hintable without duplicating
  /// mirrored bars. Empty while the bar is hidden.
  var statusBarInteractionsByScreen: [StatusBarScreenInteractions] = []
  let statusTerminals = StatusTerminalRegistry()
  lazy var statusPopupController: StatusPopupController = {
    let controller = StatusPopupController(terminals: statusTerminals)
    controller.sharingType = overlayConfig.screenCapture.sharingType
    return controller
  }()
  var statusBarPopupStyle = Config.StatusBar.PopupStyle() {
    didSet {
      if oldValue != statusBarPopupStyle { statusPopupController.updateStyle(statusBarPopupStyle) }
    }
  }
  var statusBarPopupTexts: [String: String] = [:]
  var statusBarPopupDocuments: [String: [FlashStatusTextSegment]] = [:]
  var activeStatusBarPopupName: String?
  var activeStatusBarPopupContent: String?
  var activeStatusBarPopupVisibleFrame: CGRect?
  /// A banner or alert. It sits above whatever else the overlay shows and
  /// never replaces it: a toast arriving mid-hint-session or over the command
  /// line leaves both intact, and its expiry removes only itself.
  struct Toast {
    let layer: CALayer
    let token: UInt64
    /// Errors stay for their whole dwell; informational toasts go with the
    /// next transient teardown (`hide`).
    let outlivesTeardown: Bool
  }
  var toast: Toast?
  var toastToken: UInt64 = 0
  /// Whether the shared-clock probe that lowers the bar window and makes the
  /// click windows click-through while the native (auto-hidden) menu bar is
  /// revealed under the pointer is currently registered. macOS publishes no
  /// reveal notification, so this is a poll of last resort — armed by the
  /// click view's `mouseEntered` and dropped the moment the pointer leaves
  /// the band, and ticked by `PollScheduler` rather than its own timer.
  var menuBarRevealProbeArmed = false
  /// The probe's last observed reveal state. Written on the probe queue
  /// between `resume()` and `cancel()`, reset on the main thread around
  /// those edges — the timer lifecycle serializes the two.
  var menuBarRevealedShadow = false
  /// True while the bar sits below a pointer-revealed native menu bar; see
  /// `setStatusBarYieldsToNativeMenuBar`.
  var statusBarYieldsToNativeMenuBar = false
  /// Invalidation token for the command-line key-window recovery ladder
  /// (`captureKeyboardInput`): each capture pass bumps it so stale retries
  /// from a superseded pass die silently.
  var commandLineKeyRecoveryGeneration: UInt64 = 0

  /// Supersedes a pending caret re-arm when a newer command-line open starts.
  var commandLineCaretRearmGeneration: UInt64 = 0

  /// Dispatches a named `#[range=user|<name>]` status-bar click through the
  /// `[statusbar.click]` action map. Set by the AppDelegate at startup;
  /// consumed by the click windows and the `f`-hint activation path.
  var statusBarActionHandler: ((String) -> Void)?
  /// The argument requests restoring the previous app; false switches popups in place.
  var statusBarPopupDismissHandler: ((Bool) -> Void)?
  var statusBarTerminalPrepareHandler: ((String) -> Bool)?
  /// Whether hovering `name` would have to fork a terminal child (a declared
  /// terminal popup with no running session). Such popups dwell before they
  /// spawn; see `showStatusBarPopup`.
  var statusBarTerminalNeedsSpawnHandler: ((String) -> Bool)?
  static let statusBarHoverDwellMs = 150
  var statusBarHoverDwellName: String?
  var statusBarHoverDwellWork: DispatchWorkItem?
  var statusBarHoverGate = StatusBarHoverGate.ready
  let commandPromptLayer = CAGradientLayer()
  let commandPromptLabel = CATextLayer()
  let commandTextField = CommandLineTextField(frame: .zero)
  let candidateFinderResultsLayer = CAGradientLayer()
  let candidateFinderResultsLabel = CATextLayer()
  var candidateFinderResultRowLayers: [CATextLayer] = []
  let activeWindowBorderLayer = CAShapeLayer()
  /// The window frame the border currently strokes; nil while it is hidden.
  /// The one record of whether the border shows, written only by
  /// `setActiveWindowBorder`. Its style is derived from `modeSurface.style` on
  /// every stroke, never stored.
  var activeWindowBorderFrame: CGRect?
  /// Bounding box + crosshair for the `--adjust` sub-state: outlines the
  /// matched target and marks the exact point the commit key will click.
  let adjustmentMarkerLayer = CAShapeLayer()
  /// Which interpreter hints-mode keys reach; set only from the coordinator's
  /// `HintSession.keyRoute`.
  var hintKeyRoute = HintKeyRoute.labels {
    didSet { if hintKeyRoute != oldValue { scheduleCursorVisibilityUpdate() } }
  }
  var modeSurface = ModeSurface.initial
  var statusBarModel = FlashStatusBarModel(appText: "", modeText: "", rightText: "")
  var statusBarHintSnapshot = StatusBarHintSnapshot.live
  var commandPromptVisible = false
  var commandPromptPrefix = ":"
  var candidateFinderResultsVisible = false
  var candidateFinderResultsMeasurementText = ""
  var candidateFinderResultsItems: [CandidateDisplayItem] = []
  var candidateFinderResultsShowsEmptyMessage = false
  var activeWindowBorderToken: UInt64 = 0
  var transientContentVisible = false
  var suppressCommandTextFieldChange = false

  /// One shape layer holds every debug border, drawn as a single CGPath. This
  /// is one GPU draw call regardless of how many targets are visible —
  /// vs. N CALayers which previously caused a perceptible stutter when debug
  /// mode was on with 300+ hints.
  let debugShapeLayer = CAShapeLayer()
  var lastTargetLocalRects: [CGRect] = []

  /// Hosts `[overlay] click_feedback` rings in a layer-hosting view of its
  /// own, above the drawing view, so rebuilding `contentLayer.sublayers`
  /// never cuts a ring short.
  let clickFeedbackLayer = CALayer()
  /// Rings still animating; the panel stays ordered in until they finish.
  var clickFeedbackRingsInFlight = 0

  weak var coordinator: OverlayCoordinator?

  /// Set at launch and on config reload. An unchanged value keeps the
  /// status-bar layout memo and the border stroke.
  var overlayConfig: Config.Overlay = .init() {
    didSet {
      guard overlayConfig != oldValue else { return }
      statusBarLayoutRevision &+= 1
      restyleActiveWindowBorder()
      if overlayConfig.screenCapture != oldValue.screenCapture { applyScreenCaptureSharing() }
    }
  }
  var debugConfig: Config.Debug = .init()
  /// Whether macOS draws in dark mode, pushed by `AppearanceObserver` from
  /// `NSApp.effectiveAppearance`. Selects `[overlay.dark]` at the next draw.
  var darkAppearance = false
  /// The chip colours for the current appearance.
  var hintColors: Config.HintColors { overlayConfig.hintColors(dark: darkAppearance) }
  var mouseGridOpacity: Float = 0.5
  var modeLabels: Config.Mode.Labels = .init() {
    didSet { statusBarLayoutRevision &+= 1 }
  }
  var magicModifiers: ClickModifiers = .defaultMagic
  /// `[app] keyboard_layout`'s reference table, or nil while keys read as
  /// typed. Set only by `KeyboardLayoutMonitor`; the key path reads it once
  /// per key (`keyCharacters(for:)`).
  var keyboardLayout: KeyboardLayout?
  var inputMode: OverlayInputMode = .passive {
    didSet { if inputMode != oldValue { scheduleCursorVisibilityUpdate() } }
  }

  /// Hide the mouse cursor while hint labels own the keys, so it can't obscure
  /// a chip or distract from picking one. Pointer mode is the exception — the
  /// cursor is its interface, and so is a cursor-following grid. A projection
  /// of `inputMode` and `hintKeyRoute`.
  var hintCursorShouldHide: Bool { inputMode == .hints && !hintKeyRoute.showsCursor }

  /// Apply `hintCursorShouldHide` once, at the end of the current turn: routing
  /// can pass through intermediate values while a walk hands the keys to its
  /// hints, and the cursor must not flicker through them.
  func scheduleCursorVisibilityUpdate() {
    guard !cursorVisibilityUpdateScheduled else { return }
    cursorVisibilityUpdateScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.cursorVisibilityUpdateScheduled = false
      if self.hintCursorShouldHide { self.hideHintCursor() } else { self.showHintCursor() }
    }
  }
  private var cursorVisibilityUpdateScheduled = false
  /// Guards the ref-counted `CGDisplayHideCursor`/`CGDisplayShowCursor` so the
  /// cursor can never get stuck hidden across repeated hint renders.
  private var hintCursorHidden = false
  private func hideHintCursor() {
    guard !hintCursorHidden else { return }
    CGDisplayHideCursor(CGMainDisplayID())
    hintCursorHidden = true
  }
  private func showHintCursor() {
    guard hintCursorHidden else { return }
    CGDisplayShowCursor(CGMainDisplayID())
    hintCursorHidden = false
  }
  var normalModePending: String = "" {
    didSet {
      if normalModePending.isEmpty {
        normalModePendingUpdatedAt = nil
      }
    }
  }
  var normalModePendingUpdatedAt: Date?
  var normalModeRepeatAnchor: String? {
    didSet {
      if normalModeRepeatAnchor == nil {
        normalModeRepeatAnchorUpdatedAt = nil
      }
    }
  }
  var normalModeRepeatAnchorUpdatedAt: Date?
  var normalModeMappings: CompiledMappings = CompiledMappings(Config.Mode.defaultNormalMappings)
  var normalModeSequenceTimeoutMs: Int = Config.Mode.defaultSequenceTimeoutMs
  var commandLineText: String = "" {
    didSet { commandLineCursorIndex = min(commandLineCursorIndex, commandLineText.count) }
  }
  var commandLineCursorIndex: Int = 0 {
    didSet { commandLineCursorIndex = min(max(commandLineCursorIndex, 0), commandLineText.count) }
  }

  // Fallback border colour when the configured `hint_border` is malformed.
  static let fallbackBorderCGColor = NSColor.black.withAlphaComponent(0.4).cgColor

  // MARK: Screen snapshot cache
  //
  // `NSScreen.screens` walks WindowServer's display list — measurable on
  // multi-display setups, and we call it 3–4× per activation across
  // `display(hints:)`, `displayBanner`, `displayModal`,
  // `ensurePanelFrame`, `configureModeBadge`, `configureCommandPrompt`,
  // and `configureCandidateFinderResults`. The geometry only changes
  // on `didChangeScreenParametersNotification`, so we cache once and
  // invalidate on that notification (observed from `init` below).

  struct ScreenSnapshot {
    /// `notch` is the camera-housing rect in screen coordinates (nil on
    /// screens without one), derived from the auxiliary top areas — the
    /// status bar keeps a safety margin around it.
    var screens: [(scale: CGFloat, frame: CGRect, visibleFrame: CGRect, notch: CGRect?)]
    var unionFrame: CGRect
    /// The fixed primary display at origin (0, 0), independent of keyboard focus.
    var mainFrame: CGRect?
    var mainScale: CGFloat
    var mainVisibleFrame: CGRect
    var nativeStatusBarFallbackHeight: CGFloat
    /// Each display's own native menu bar height, keyed by screen frame. A
    /// notched built-in's bar is taller than an external's, so no single
    /// measurement fits every display.
    var nativeMenuBarHeights: [(screenFrame: CGRect, height: CGFloat)] = []

    func nativeStatusBarFallbackHeight(forScreenFrame screenFrame: CGRect) -> CGFloat {
      nativeMenuBarHeights.first { $0.screenFrame == screenFrame }?.height
        ?? nativeStatusBarFallbackHeight
    }

    /// Width of the camera housing the centre recess mimics: the connected
    /// notched display's, else the 16-inch MacBook Pro housing.
    var referenceNotchWidth: CGFloat {
      screens.compactMap { $0.notch?.width }.first ?? OverlayPanel.defaultNotchWidth
    }
  }

  static let defaultNotchWidth: CGFloat = 185

  private static var snapshotLock = os_unfair_lock_s()
  private static var cachedSnapshot: ScreenSnapshot?
  /// Native menu bar heights per display. They change only with the display
  /// topology, so a Space switch or wake rebuilds the snapshot from these
  /// instead of scanning the window list again.
  private static var cachedNativeMenuBarHeights: [CGDirectDisplayID: CGFloat]?

  static func currentScreenSnapshot() -> ScreenSnapshot {
    os_unfair_lock_lock(&snapshotLock)
    if let cached = cachedSnapshot {
      os_unfair_lock_unlock(&snapshotLock)
      return cached
    }
    os_unfair_lock_unlock(&snapshotLock)
    let snapshot = buildScreenSnapshot()
    os_unfair_lock_lock(&snapshotLock)
    cachedSnapshot = snapshot
    os_unfair_lock_unlock(&snapshotLock)
    return snapshot
  }

  /// Incremented with every invalidation so layout memos keyed on display
  /// geometry (see `ModeBadgeLayoutStamp`) recompute after a screen change.
  private(set) static var screenSnapshotRevision: UInt64 = 0

  static func invalidateScreenSnapshot(remeasuringNativeMenuBars: Bool = false) {
    os_unfair_lock_lock(&snapshotLock)
    cachedSnapshot = nil
    if remeasuringNativeMenuBars { cachedNativeMenuBarHeights = nil }
    screenSnapshotRevision &+= 1
    os_unfair_lock_unlock(&snapshotLock)
  }

  /// Re-read every display's native menu bar, invalidating the snapshot only
  /// when a height moved. Returns whether one did. Main thread.
  static func remeasureNativeMenuBars() -> Bool {
    let measured = measureNativeMenuBarHeights()
    os_unfair_lock_lock(&snapshotLock)
    defer { os_unfair_lock_unlock(&snapshotLock) }
    guard measured != cachedNativeMenuBarHeights else { return false }
    cachedNativeMenuBarHeights = measured
    cachedSnapshot = nil
    screenSnapshotRevision &+= 1
    return true
  }

  private static func nativeMenuBarHeightsByDisplay() -> [CGDirectDisplayID: CGFloat] {
    os_unfair_lock_lock(&snapshotLock)
    let cached = cachedNativeMenuBarHeights
    os_unfair_lock_unlock(&snapshotLock)
    if let cached { return cached }
    let measured = measureNativeMenuBarHeights()
    os_unfair_lock_lock(&snapshotLock)
    cachedNativeMenuBarHeights = measured
    os_unfair_lock_unlock(&snapshotLock)
    return measured
  }

  private static func buildScreenSnapshot() -> ScreenSnapshot {
    var screens: [(scale: CGFloat, frame: CGRect, visibleFrame: CGRect, notch: CGRect?)] = []
    var displays: [(displayID: CGDirectDisplayID?, frame: CGRect)] = []
    for s in NSScreen.screens {
      displays.append((s.displayID, s.frame))
      // A notched display exposes the areas LEFT and RIGHT of the camera
      // housing; the gap between them is the notch itself.
      var notch: CGRect?
      if let auxLeft = s.auxiliaryTopLeftArea, let auxRight = s.auxiliaryTopRightArea,
        auxRight.minX > auxLeft.maxX
      {
        notch = CGRect(
          x: auxLeft.maxX,
          y: auxLeft.minY,
          width: auxRight.minX - auxLeft.maxX,
          height: s.frame.maxY - auxLeft.minY)
      }
      screens.append((s.backingScaleFactor, s.frame, s.visibleFrame, notch))
    }
    let menuBars = resolveNativeMenuBarHeights(
      screens: displays,
      measured: nativeMenuBarHeightsByDisplay(),
      appKitFallback: measureNativeStatusBarFallbackHeight)
    return makeScreenSnapshot(
      screens: screens,
      nativeStatusBarFallbackHeight: menuBars.fallback,
      nativeMenuBarHeights: menuBars.perScreen)
  }

  /// Pair each screen with its display's measured bar. A display without a
  /// bar of its own (a secondary display when Displays have separate Spaces
  /// is off) falls back to the primary display's. AppKit's app-wide
  /// measurement, which follows whichever display last hosted the active menu
  /// bar, is the last resort when the window list shows no bar at all.
  static func resolveNativeMenuBarHeights(
    screens: [(displayID: CGDirectDisplayID?, frame: CGRect)],
    measured: [CGDirectDisplayID: CGFloat],
    appKitFallback: () -> CGFloat
  ) -> (perScreen: [(screenFrame: CGRect, height: CGFloat)], fallback: CGFloat) {
    let perScreen = screens.compactMap { screen in
      screen.displayID.flatMap { measured[$0] }.map { (screenFrame: screen.frame, height: $0) }
    }
    let fallback =
      perScreen.first { $0.screenFrame.origin == .zero }?.height
      ?? perScreen.first?.height
      ?? appKitFallback()
    return (perScreen, fallback)
  }

  /// The native menu bar on one display: the widest main-menu-level window
  /// along its top edge, flush with it when revealed or parked just above it
  /// while auto-hidden. Both inputs use WindowServer's top-left global space.
  static func nativeMenuBarHeight(
    displayBounds display: CGRect, menuBarWindows: [CGRect]
  ) -> CGFloat? {
    menuBarWindows.filter { bar in
      bar.height > 0
        && bar.minX >= display.minX - 1 && bar.maxX <= display.maxX + 1
        && (abs(bar.minY - display.minY) <= 1 || abs(bar.maxY - display.minY) <= 1)
    }
    .max { $0.width < $1.width }?.height
  }

  /// Matches by window level and bounds only, like the reveal probe, so it
  /// reads no window titles and needs no Screen Recording permission.
  /// `.optionAll` because an auto-hidden bar is off-screen.
  private static func measureNativeMenuBarHeights() -> [CGDirectDisplayID: CGFloat] {
    guard
      let infos = WindowSnapshot.windowList([.optionAll])
    else { return [:] }
    let menuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
    let ownPID = Int(getpid())
    let bars = infos.compactMap { info -> CGRect? in
      guard
        info[kCGWindowLayer as String] as? Int == menuLayer,
        info[kCGWindowOwnerPID as String] as? Int != ownPID,
        let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
        let x = bounds["X"], let y = bounds["Y"],
        let width = bounds["Width"], let height = bounds["Height"]
      else { return nil }
      return CGRect(x: x, y: y, width: width, height: height)
    }
    var heights: [CGDirectDisplayID: CGFloat] = [:]
    for id in NSScreen.screens.compactMap(\.displayID) {
      heights[id] = nativeMenuBarHeight(
        displayBounds: CGDisplayBounds(id), menuBarWindows: bars)
    }
    return heights
  }

  static func makeScreenSnapshot(
    screens: [(scale: CGFloat, frame: CGRect, visibleFrame: CGRect, notch: CGRect?)],
    nativeStatusBarFallbackHeight: CGFloat,
    nativeMenuBarHeights: [(screenFrame: CGRect, height: CGFloat)] = []
  ) -> ScreenSnapshot {
    let union = screens.reduce(CGRect.null) { $0.union($1.frame) }
    // NSScreen.main follows the key window and can be a secondary display.
    let primary = screens.first { $0.frame.origin == .zero } ?? screens.first
    return ScreenSnapshot(
      screens: screens,
      unionFrame: union.isNull ? .zero : union,
      mainFrame: primary?.frame,
      mainScale: primary?.scale ?? 2,
      mainVisibleFrame: primary?.visibleFrame ?? .zero,
      nativeStatusBarFallbackHeight: nativeStatusBarFallbackHeight,
      nativeMenuBarHeights: nativeMenuBarHeights)
  }

  private static func measureNativeStatusBarFallbackHeight() -> CGFloat {
    let statusItemBandHeight = max(0, NSStatusBar.system.thickness)
    let app = NSApplication.shared
    if let menuHeight = app.mainMenu?.menuBarHeight, menuHeight > 0 {
      return max(statusItemBandHeight, menuHeight)
    }

    let previousMenu = app.mainMenu
    defer { app.mainMenu = previousMenu }

    // AppKit only resolves the menu-bar reveal height for an installed
    // main menu. Install a temporary measurement menu and restore the
    // LSUIElement app's original menu immediately; this must never become
    // a visible Flash UI surface.
    let measurementMenu = NSMenu(title: "Flash")
    let rootItem = NSMenuItem(title: "Flash", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "Flash")
    submenu.addItem(NSMenuItem(title: "Flash", action: nil, keyEquivalent: ""))
    rootItem.submenu = submenu
    measurementMenu.addItem(rootItem)
    app.mainMenu = measurementMenu

    return max(statusItemBandHeight, measurementMenu.menuBarHeight)
  }

  // MARK: Pre-baked CGColors
  //
  // The Nord palette is built from `NSColor`; `cgColor` does a runtime
  // conversion. These hot paths read CGColors 3–6 times per activation
  // (mode badge, command prompt, candidate finder, banner, modal), so
  // build them once and reuse.

  private var screenParametersObserver: NSObjectProtocol?
  private var statusBarOcclusionObserver: NSObjectProtocol?

  init() {
    let frame = OverlayPanel.unionScreenFrame()
    statusBarWindow = StatusBarWindow(frame: frame)
    super.init(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    screenParametersObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      OverlayPanel.invalidateScreenSnapshot(remeasuringNativeMenuBars: true)
      // A monitor was (un)plugged. The status bar is anchored to `NSScreen.main`
      // and the panel window spans the union of all screens; both just moved, so
      // without a re-layout the bar is stranded on coordinates that no longer
      // exist and appears to vanish. Re-anchor it onto the surviving screens.
      self?.statusBarDidChangeScreenParameters()
      // `visibleFrame` / `NSScreen.main` can settle a beat after the notification
      // (notably when unplugging the display that hosted the menu bar), so
      // re-anchor once more on the next runloop hop against the finalized layout.
      DispatchQueue.main.async {
        OverlayPanel.invalidateScreenSnapshot(remeasuringNativeMenuBars: true)
        self?.statusBarDidChangeScreenParameters()
      }
    }
    // Coming back on screen (display wake, unlock, a full-screen cover gone)
    // repaints the whole bar; see `reassertStatusBar`.
    statusBarOcclusionObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification,
      object: statusBarWindow,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      let visible = self.statusBarWindow.occlusionState.contains(.visible)
      FlashLog.trace("[statusbar] occlusion visible=\(visible)")
      if visible { self.reassertStatusBar(reason: "occlusion_visible") }
    }
    self.level = Self.persistentStatusWindowLevel
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    self.isOpaque = false
    self.backgroundColor = .clear
    self.hasShadow = false
    self.animationBehavior = .none
    self.ignoresMouseEvents = true
    self.hidesOnDeactivate = false
    self.isReleasedWhenClosed = false
    self.acceptsMouseMovedEvents = false
    self.becomesKeyOnlyIfNeeded = false

    let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
    view.wantsLayer = true
    // AppKit owns the editor's layers; Flash only replaces the drawing subtree.
    let drawingView = NSView(frame: view.bounds)
    drawingView.layer = contentLayer
    drawingView.wantsLayer = true
    drawingView.autoresizingMask = [.width, .height]
    view.addSubview(drawingView)
    contentLayer.frame = drawingView.bounds
    contentLayer.actions = OverlayPanel.noActions
    let clickFeedbackView = NSView(frame: view.bounds)
    clickFeedbackView.layer = clickFeedbackLayer
    clickFeedbackView.wantsLayer = true
    clickFeedbackView.autoresizingMask = [.width, .height]
    view.addSubview(clickFeedbackView)
    clickFeedbackLayer.frame = clickFeedbackView.bounds
    clickFeedbackLayer.actions = OverlayPanel.noActions

    debugShapeLayer.fillColor = NSColor.clear.cgColor
    debugShapeLayer.strokeColor = NSColor.systemPink.cgColor
    debugShapeLayer.lineWidth = 1
    debugShapeLayer.isHidden = true
    debugShapeLayer.actions = OverlayPanel.noActions
    contentLayer.addSublayer(debugShapeLayer)

    modeBadgeLayer.cornerRadius = 0
    modeBadgeLayer.borderWidth = 0
    modeBadgeLayer.opacity = 1
    modeBadgeLayer.actions = OverlayPanel.noActions
    commandPromptLayer.cornerRadius = 6
    commandPromptLayer.borderWidth = 1.5
    commandPromptLayer.masksToBounds = false
    commandPromptLayer.shadowColor = NSColor.black.cgColor
    commandPromptLayer.shadowOpacity = 0.48
    commandPromptLayer.shadowRadius = 18
    commandPromptLayer.shadowOffset = CGSize(width: 0, height: -8)
    commandPromptLayer.actions = OverlayPanel.noActions
    commandPromptLabel.alignmentMode = .left
    commandPromptLabel.actions = OverlayPanel.noActions
    // No caret layer: the command text field's own AppKit caret is the only one.
    commandPromptLayer.sublayers = [commandPromptLabel]
    // Match the command-input box exactly so the two stacked boxes read as
    // one surface — same corner radius and border weight as `commandPromptLayer`.
    candidateFinderResultsLayer.cornerRadius = 6
    candidateFinderResultsLayer.borderWidth = 1.5
    candidateFinderResultsLayer.masksToBounds = true
    candidateFinderResultsLayer.actions = OverlayPanel.noActions
    candidateFinderResultsLabel.alignmentMode = .left
    candidateFinderResultsLabel.isWrapped = false
    candidateFinderResultsLabel.isHidden = true
    candidateFinderResultsLabel.actions = OverlayPanel.noActions
    candidateFinderResultsLayer.sublayers = []
    activeWindowBorderLayer.fillColor = NSColor.clear.cgColor
    activeWindowBorderLayer.strokeColor = Self.nordFrost2CG
    activeWindowBorderLayer.lineWidth = 2
    activeWindowBorderLayer.actions = OverlayPanel.noActions
    adjustmentMarkerLayer.fillColor = NSColor.clear.cgColor
    adjustmentMarkerLayer.strokeColor = Self.nordFrost2CG
    adjustmentMarkerLayer.lineWidth = 1.5
    adjustmentMarkerLayer.isHidden = true
    adjustmentMarkerLayer.actions = OverlayPanel.noActions
    contentLayer.addSublayer(adjustmentMarkerLayer)

    self.contentView = view
    configureCommandTextField()
    view.addSubview(commandTextField)
    installPointerMonitors()
  }

  deinit {
    for observer in [screenParametersObserver, statusBarOcclusionObserver].compactMap({ $0 }) {
      NotificationCenter.default.removeObserver(observer)
    }
    removePointerMonitors()
  }

  /// Allocate `count` chip+label layers and stash them in the pools. Called
  /// once at app launch to keep the first-activation layer allocation cost
  /// off the hot path.
  func warmPool(count: Int) {
    hintLayerPool.reserveCapacity(count)
    labelLayerPool.reserveCapacity(count)
    for _ in 0..<count {
      hintLayerPool.append(makeChipLayer())
      labelLayerPool.append(makeLabelLayer())
    }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override var acceptsFirstResponder: Bool { true }

  override func becomeKey() {
    super.becomeKey()
    // Activation can land asynchronously on this macOS, so the window may become
    // key *after* `captureKeyboardInput` already ran. A field editor only shows a
    // blinking caret in a key window, so when we key while a command bar is open,
    // (re)focus the field and restart its blink — otherwise a cancel→reopen left
    // the caret missing until the next keystroke.
    if commandTextFieldIsLaidOut {
      commandTextField.isHidden = false
      makeFirstResponder(commandTextField)
      syncCommandTextFieldSelection()
      rearmCommandLineCaret()
    }
  }

  /// The command field may take focus only once its prompt is on screen and it
  /// has been placed on it. Routing turns `.commandLine` a moment before the
  /// first paint, and focusing the field before then showed it — and macOS's
  /// input-source / caps-lock indicator, which anchors to the caret — at its
  /// unplaced frame in the screen's bottom-left corner.
  var commandTextFieldIsLaidOut: Bool {
    inputMode == .commandLine && commandPromptVisible && !commandTextField.frame.isEmpty
  }

  /// True once the global keyboard tap is installed. NORMAL / hints capture then
  /// runs through the tap instead of the key window, so the overlay no longer
  /// takes key/active status for those modes (the focused app keeps its colored
  /// window controls). Set by the AppDelegate at startup; stays false — and the
  /// key-window path is used — if the tap could not be created.
  var keyboardCaptureActive = false

  /// The current hint session's capture path; pushed from
  /// `HintSession.capture` with the rest of the session's projections.
  var hintSessionCapture = KeyboardCaptureTap.SessionCapture.tap

  /// Whether the tap routes the current input mode's keys: NORMAL, and a
  /// hint session that did not start under secure input. Everything else
  /// reads keys through the key window.
  var tapCapturesInput: Bool {
    guard keyboardCaptureActive else { return false }
    switch inputMode {
    case .normal: return true
    case .hints: return hintSessionCapture == .tap
    case .passive, .commandLine: return false
    }
  }

  var keyboardCaptureIsActive: Bool {
    // NORMAL / hints capture is owned by the keyboard tap, which doesn't depend
    // on key-window focus — being visible is enough. (The recapture machinery
    // keys off this, so reporting "active" here keeps it from churning.)
    if inputMode == .passive { return false }
    if tapCapturesInput {
      return isVisible
    }
    if inputMode == .commandLine {
      return isVisible && isKeyWindow
        && (firstResponder === commandTextField || commandTextField.currentEditor() != nil)
    }
    return isVisible && isKeyWindow && firstResponder === self
  }

  /// Single pair of NSEvent monitors (global + local) that dismiss the
  /// overlay on scroll or any mouse button press. We use NSEvent's
  /// *global* monitor because the panel has `ignoresMouseEvents = true`
  /// so scroll/click events go to whichever app is under the cursor,
  /// not to us — we observe them without intercepting so the underlying
  /// app still gets them. The local monitor catches the rare case where
  /// the overlay or another Flash window is frontmost when a pointer
  /// event arrives.
  ///
  /// Installed once at `init` and left running. The callback gates on
  /// the current overlay state, so install/remove churn per activation
  /// is gone.
  var pointerGlobalMonitor: Any?
  var pointerLocalMonitor: Any?

  /// single device-pixel row and renders crisp.
  static func snap(_ rect: CGRect, scale: CGFloat) -> CGRect {
    guard scale > 0 else { return rect }
    let s = scale
    let x = (rect.origin.x * s).rounded() / s
    let y = (rect.origin.y * s).rounded() / s
    let w = (rect.size.width * s).rounded() / s
    let h = (rect.size.height * s).rounded() / s
    return CGRect(x: x, y: y, width: w, height: h)
  }

  static func unionScreenFrame() -> NSRect {
    currentScreenSnapshot().unionFrame
  }

  /// Hex → NSColor with a tiny memo. `display(hints:)` parses 4 hex
  /// strings per render and `filter(...)` parses one more per
  /// keystroke; the values come from `overlayConfig` so they're
  /// constant across activations until the user edits flash.toml.
  /// Sentinel `NSColor.clear` represents "parse failure" so we can
  /// distinguish nil-cached from absent-from-cache.
  ///
  /// Cache is keyed on the *normalised* hex (whitespace trimmed,
  /// leading `#` removed, lowercased). The previous version keyed on
  /// the raw input, so `"#FFAA00"` and `" #ffaa00 "` got separate
  /// entries and the per-frame parse ran on every variant.
  private var colorCache: [String: NSColor] = [:]
  private static let parseFailureSentinel = NSColor.clear

  func nsColor(fromHex hex: String) -> NSColor? {
    var s = hex.trimmingCharacters(in: .whitespaces).lowercased()
    if s.hasPrefix("#") { s.removeFirst() }
    if let cached = colorCache[s] {
      return cached === OverlayPanel.parseFailureSentinel ? nil : cached
    }
    guard let v = UInt64(s, radix: 16) else {
      colorCache[s] = OverlayPanel.parseFailureSentinel
      return nil
    }
    let result: NSColor?
    switch s.count {
    case 6:
      let r = CGFloat((v >> 16) & 0xff) / 255
      let g = CGFloat((v >> 8) & 0xff) / 255
      let b = CGFloat(v & 0xff) / 255
      result = NSColor(red: r, green: g, blue: b, alpha: 1)
    case 8:
      let r = CGFloat((v >> 24) & 0xff) / 255
      let g = CGFloat((v >> 16) & 0xff) / 255
      let b = CGFloat((v >> 8) & 0xff) / 255
      let a = CGFloat(v & 0xff) / 255
      result = NSColor(red: r, green: g, blue: b, alpha: a)
    default:
      result = nil
    }
    colorCache[s] = result ?? OverlayPanel.parseFailureSentinel
    return result
  }
}

protocol OverlayCoordinator: AnyObject {
  /// The app Flash last saw focused (never Flash itself), so an activation
  /// request can name a source when the workspace's frontmost pointer is stale.
  var lastFocusedApplicationPID: pid_t? { get }
  func overlayDidCancel()
  func overlayDidCancelByPointer(_ intent: OverlayPointerIntent)
  func overlayDidCommit(prefix: String, clickModifiers: ClickModifiers)
  /// One keystroke of the `--adjust` sub-state (edge snap, interpolation,
  /// commit, cancel). Only called while `hintKeyRoute` is `.adjustment`.
  func overlayDidAdjust(_ command: HintAdjustmentCommand, clickModifiers: ClickModifiers)
  /// One keystroke of pointer mode. Only called while `hintKeyRoute` is `.pointer`.
  func overlayDidPointer(_ command: PointerModeCommand)
  /// One keystroke of the `--search` sub-state. Only called while
  /// `hintKeyRoute` is `.search`.
  func overlayDidSearch(_ command: HintSearchCommand, clickModifiers: ClickModifiers)
  /// One keystroke of the mouse grid. Only called while `hintKeyRoute` is
  /// `.grid`.
  func overlayDidGrid(_ command: MouseGridKeyCommand)
  func overlayDidUpdatePrefix(_ prefix: String)
  func overlayDidHandleNormalMode(_ action: MappingCommand?, repeatCount: Int)
  func overlayDidHandleMapping(_ event: NSEvent) -> Bool
  func overlayDidCancelCommandLine()
  func overlayDidUpdateCommandLine(_ command: String, cursorIndex: Int, resetSelection: Bool)
  func overlayDidMoveCommandLineSelection(_ delta: Int) -> Bool
  func overlayDidInsertCommandLineSelection() -> Bool
  func overlayDidSubmitCommandLine(_ command: String)
  func overlayDidForceSubmitCommandLineSelection()
  /// `[flashlight.aliases]` lookup hook. Returns the rewritten buffer +
  /// cursor when the latest keystroke landed on `<space>` after a
  /// registered shorthand bang (`!g ` → `!google `), `nil` otherwise.
  /// Lives on the coordinator so the alias map is sourced from the
  /// live config rather than mirrored onto the panel.
  func overlayExpandFlashlightAlias(
    _ text: String, cursorIndex: Int
  ) -> (text: String, cursorIndex: Int)?
}
