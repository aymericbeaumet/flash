import AppKit
import FlashCore
import QuartzCore
import os

enum OverlayModeBadgeStyle {
  case insert
  case normal
  case command
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

final class CommandLineTextField: NSTextField {
  override var acceptsFirstResponder: Bool { true }
}

final class OverlayPanel: NSPanel {
  static let transientOverlayWindowLevel: NSWindow.Level = .screenSaver
  // The Flash status bar is an ordinary elevated window: above the focused
  // app's normal windows so it stays visible, but a plain `.floating` level —
  // NOT jammed against the menu-bar band one level under the system menu
  // window, where it competed with the system menu bar for clicks. The native
  // menu bar (app menus at the menu-bar window level 24, extras at
  // `.statusBar`/25, and the auto-hide reveal the system draws on hover) sits
  // well above `.floating`, so by pure window z-order it expands on top of
  // Flash and takes the click; when it's tucked away, the band is Flash's.
  // Normal-mode keystroke capture runs through the session CGEvent tap (not
  // key focus), and the key-window fallback still works at this level (only
  // `.statusBar`/25 is barred from becoming key).
  static let persistentStatusWindowLevel: NSWindow.Level = .floating
  // The status bar's *visual* lives on the `.floating` panel above, but its
  // click windows must sit at the system menu-bar level: macOS only delivers
  // menu-bar-band clicks to windows at (or above) that level — lower windows
  // get nothing and the click falls through to the desktop. They don't steal
  // native clicks despite outranking it, because they flip to click-through
  // (`ignoresMouseEvents`) whenever the native menu bar is revealed; see
  // `nativeMenuBarIsRevealed` / `menuBarRevealTimer`.
  static let statusBarClickWindowLevel: NSWindow.Level = .statusBar
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
  let statusAppLabel = CATextLayer()
  let modeBadgeButtonLayer = CAGradientLayer()
  let modeBadgeLabel = CATextLayer()
  /// Styled text that follows `#{mode}` in the `#[align=left]` bucket. The
  /// mode pill itself only renders the mode label; anything after it (e.g.
  /// `#{mode}#[fg=colour245] · HN …`) is a normal tmux-styled run rendered
  /// here so it doesn't inherit the bold mode-pill palette.
  let statusLeftTrailingLabel = CATextLayer()
  /// The rotating `#{cycle:…}` run in the left-trailing region, rendered in its
  /// own layer (clipped to one line) so it can slide vertically while the text
  /// around it — the mode pill, the "HN" label — stays put.
  let statusLeftTrailingCycleLayer = CATextLayer()
  var lastRenderedLeftTrailingCycle: String?
  let statusRightLabel = CATextLayer()
  /// Status bars rendered on every non-main screen. Allocated lazily by
  /// `configureSecondaryStatusBars` and pruned when displays disconnect.
  /// Each entry mirrors the primary bar's text but uses its own screen's
  /// native top-band height so users see the bar at the right vertical
  /// position regardless of which monitor they look at.
  var secondaryStatusBars: [SecondaryStatusBar] = []
  /// Which displays render the bar (`[statusbar] monitor`). `primary` skips the
  /// secondary (non-main) screen bars. Set by the AppDelegate on config load.
  var statusBarMonitor: Config.StatusBar.Monitor = .all
  /// One full-band click window per screen (the bar's visual lives on this
  /// click-through panel, so these windows do the click work). They swallow
  /// band clicks so a click on the bar never reveals the desktop, and open a
  /// `#[link=…]` run when the click lands on one. Pooled + repositioned on
  /// render. See `StatusBarClickPanel`.
  var statusBarClickWindows: [StatusBarClickPanel] = []
  /// Signature of the currently-installed band + link rects, so an unchanged
  /// render skips reordering the click windows.
  var lastStatusBarClickSignature: String?
  /// Per-screen status-bar `#[link=…]` rects in screen coordinates, rebuilt on
  /// every `configureModeBadge`. Keyed by each screen's frame so the `f` hint
  /// path can place link hints only on the bar of the active window's screen
  /// (not on every mirrored bar). Empty while the bar is hidden.
  var statusBarLinkRectsByScreen: [(screenFrame: CGRect, links: [(rect: CGRect, url: URL)])] = []
  /// Repeating probe that flips the click windows to click-through while the
  /// native (auto-hidden) menu bar is revealed, so native wins those clicks.
  /// Runs on a utility queue (never the main run loop, which owns the
  /// keyboard tap) and only while the pointer is in the top band — armed by
  /// the click view's `mouseEntered`, self-stopping when the pointer leaves.
  var menuBarRevealTimer: DispatchSourceTimer?
  /// The probe's last observed reveal state. Written on the probe queue
  /// between `resume()` and `cancel()`, reset on the main thread around
  /// those edges — the timer lifecycle serializes the two.
  var menuBarRevealedShadow = false
  /// Invalidation token for the command-line key-window recovery ladder
  /// (`captureKeyboardInput`): each capture pass bumps it so stale retries
  /// from a superseded pass die silently.
  var commandLineKeyRecoveryGeneration: UInt64 = 0
  /// Dispatches a named `#[range=user|<name>]` status-bar click through the
  /// `[statusbar.click]` action map. Set by the AppDelegate at startup;
  /// consumed by the click windows and the `f`-hint activation path.
  var statusBarActionHandler: ((String) -> Void)?
  let commandPromptLayer = CAGradientLayer()
  let commandPromptLabel = CATextLayer()
  let commandCaretLayer = CALayer()
  let commandTextField = CommandLineTextField(frame: .zero)
  let candidateFinderResultsLayer = CAGradientLayer()
  let candidateFinderResultsLabel = CATextLayer()
  var candidateFinderResultRowLayers: [CATextLayer] = []
  let activeWindowBorderLayer = CAShapeLayer()
  var modeBadgeVisible = false
  var statusAppText = ""
  var modeBadgeText = "INSERT"
  /// Styled text that follows `#{mode}` in the `#[align=left]` bucket. Held
  /// separately from `modeBadgeText` so a mode change (which rewrites only
  /// the pill label) doesn't blow away the trailing run and flash it.
  var statusLeftTrailingText = ""
  var statusRightText = ""
  /// Last content actually pushed to each status-bar text layer. A
  /// re-render that leaves a segment unchanged skips the `.string`
  /// reassignment + `setNeedsDisplay()` that would otherwise flash it.
  /// Animated segments (`#[breathing]` / `#[blink]`) bypass the cache so
  /// the effects tick keeps advancing.
  var lastRenderedPill: String?
  var lastRenderedPillStyle: OverlayModeBadgeStyle?
  var lastRenderedLeftTrailing: String?
  var lastRenderedCentre: String?
  var lastRenderedRight: String?
  var modeBadgeStyle: OverlayModeBadgeStyle = .insert
  var modeBadgeCapturesInput = false
  var commandPromptVisible = false
  var commandPromptPrefix = ":"
  var candidateFinderResultsVisible = false
  var candidateFinderResultsMeasurementText = ""
  var candidateFinderResultsItems: [CandidateDisplayItem] = []
  var candidateFinderResultsShowsEmptyMessage = false
  var activeWindowBorderToken: UInt64 = 0
  var transientDisplayToken: UInt64 = 0
  var transientContentVisible = false
  var suppressCommandTextFieldChange = false

  /// One shape layer holds every debug border, drawn as a single CGPath. This
  /// is one GPU draw call regardless of how many targets are visible —
  /// vs. N CALayers which previously caused a perceptible stutter when debug
  /// mode was on with 300+ hints.
  let debugShapeLayer = CAShapeLayer()
  var lastTargetLocalRects: [CGRect] = []

  weak var coordinator: OverlayCoordinator?

  var overlayConfig: Config.Overlay = .init()
  var debugConfig: Config.Debug = .init()
  var mouseGridOpacity: Float = 0.5
  var modeLabels: Config.Mode.Labels = .init()
  var magicModifiers: ClickModifiers = .defaultMagic
  var inputMode: OverlayInputMode = .hints {
    didSet {
      guard inputMode != oldValue else { return }
      // Hide the mouse cursor while hints are on screen so it can't obscure a
      // chip or distract from picking one; restore it for every other surface
      // (normal, flashlight, command line, modal) and on dismissal.
      if inputMode == .hints {
        hideHintCursor()
      } else {
        showHintCursor()
      }
    }
  }
  /// Guards the ref-counted `CGDisplayHideCursor`/`CGDisplayShowCursor` so the
  /// cursor can never get stuck hidden across repeated hint renders.
  private var hintCursorHidden = false
  func hideHintCursor() {
    guard !hintCursorHidden else { return }
    CGDisplayHideCursor(CGMainDisplayID())
    hintCursorHidden = true
  }
  func showHintCursor() {
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
  var normalModePassthroughKeyCodes = Set(
    Config.Mode.defaultNormalPassthroughKeys.compactMap(HotkeySyntax.parseKey))
  var normalModePassthroughModifiers = Config.Mode.defaultNormalPassthroughModifiers
  var commandLineText: String = "" {
    didSet { commandLineCursorIndex = min(commandLineCursorIndex, commandLineText.count) }
  }
  var commandLineCursorIndex: Int = 0 {
    didSet { commandLineCursorIndex = min(max(commandLineCursorIndex, 0), commandLineText.count) }
  }
  var candidateFinderQuery: String = ""

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
    var mainFrame: CGRect?
    var mainScale: CGFloat
    var mainVisibleFrame: CGRect
    var nativeStatusBarFallbackHeight: CGFloat
  }

  private static var snapshotLock = os_unfair_lock_s()
  private static var cachedSnapshot: ScreenSnapshot?

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

  static func invalidateScreenSnapshot() {
    os_unfair_lock_lock(&snapshotLock)
    cachedSnapshot = nil
    os_unfair_lock_unlock(&snapshotLock)
  }

  private static func buildScreenSnapshot() -> ScreenSnapshot {
    var union: NSRect = .null
    var screens: [(scale: CGFloat, frame: CGRect, visibleFrame: CGRect, notch: CGRect?)] = []
    for s in NSScreen.screens {
      union = union.union(s.frame)
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
    if union.isNull, let main = NSScreen.main { union = main.frame }
    let main = NSScreen.main ?? NSScreen.screens.first
    return ScreenSnapshot(
      screens: screens,
      unionFrame: union,
      mainFrame: main?.frame,
      mainScale: main?.backingScaleFactor ?? 2,
      mainVisibleFrame: main?.visibleFrame ?? union,
      nativeStatusBarFallbackHeight: measureNativeStatusBarFallbackHeight())
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

  init() {
    let frame = OverlayPanel.unionScreenFrame()
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
    ) { _ in
      OverlayPanel.invalidateScreenSnapshot()
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
    view.layer = contentLayer
    contentLayer.frame = view.bounds
    contentLayer.actions = OverlayPanel.noActions

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
    statusAppLabel.alignmentMode = .left
    statusAppLabel.actions = OverlayPanel.noActions
    modeBadgeButtonLayer.cornerRadius = 4
    modeBadgeButtonLayer.borderWidth = 0
    modeBadgeButtonLayer.actions = OverlayPanel.noActions
    modeBadgeLabel.alignmentMode = .center
    modeBadgeLabel.actions = OverlayPanel.noActions
    modeBadgeButtonLayer.sublayers = [modeBadgeLabel]
    statusLeftTrailingLabel.alignmentMode = .left
    statusLeftTrailingLabel.actions = OverlayPanel.noActions
    statusLeftTrailingCycleLayer.alignmentMode = .left
    statusLeftTrailingCycleLayer.actions = OverlayPanel.noActions
    statusLeftTrailingCycleLayer.masksToBounds = true
    statusLeftTrailingCycleLayer.isHidden = true
    statusRightLabel.alignmentMode = .right
    statusRightLabel.actions = OverlayPanel.noActions
    modeBadgeLayer.sublayers = [
      statusAppLabel, modeBadgeButtonLayer, statusLeftTrailingLabel,
      statusLeftTrailingCycleLayer, statusRightLabel,
    ]
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
    commandCaretLayer.actions = OverlayPanel.noActions
    commandCaretLayer.backgroundColor = Self.nordSnowStorm2CG
    commandCaretLayer.isHidden = true
    commandPromptLayer.sublayers = [commandPromptLabel, commandCaretLayer]
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

    self.contentView = view
    configureCommandTextField()
    view.addSubview(commandTextField)
    installPointerMonitors()
  }

  deinit {
    if let observer = screenParametersObserver {
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
    if inputMode == .commandLine {
      commandTextField.isHidden = false
      makeFirstResponder(commandTextField)
      syncCommandTextFieldSelection()
      (commandTextField.currentEditor() as? NSTextView)?
        .updateInsertionPointStateAndRestartTimer(true)
    }
  }

  /// True once the global keyboard tap is installed. NORMAL / hints capture then
  /// runs through the tap instead of the key window, so the overlay no longer
  /// takes key/active status for those modes (the focused app keeps its colored
  /// window controls). Set by the AppDelegate at startup; stays false — and the
  /// key-window path is used — if the tap could not be created.
  var keyboardCaptureActive = false

  var keyboardCaptureIsActive: Bool {
    // NORMAL / hints capture is owned by the keyboard tap, which doesn't depend
    // on key-window focus — being visible is enough. (The recapture machinery
    // keys off this, so reporting "active" here keeps it from churning.)
    if keyboardCaptureActive, inputMode == .normal || inputMode == .hints {
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
  func overlayDidCancel()
  func overlayDidCancelByPointer(_ intent: OverlayPointerIntent)
  func overlayDidCommit(prefix: String, clickModifiers: ClickModifiers)
  /// `<space>` in the hints surface. Commits the mouse grid's centre cell
  /// and returns `true` when mouse-grid mode is active; returns `false`
  /// otherwise so the panel falls back to cancelling the overlay.
  func overlayDidCommitCenter(clickModifiers: ClickModifiers) -> Bool
  func overlayDidUpdatePrefix(_ prefix: String)
  func overlayDidHandleNormalMode(_ action: MappingCommand?, repeatCount: Int)
  func overlayDidHandleMapping(_ event: NSEvent) -> Bool
  func overlayDidPassthroughNormalModeKey(_ event: NSEvent)
  func overlayDidCancelCommandLine()
  func overlayDidUpdateCommandLine(_ command: String, cursorIndex: Int, resetSelection: Bool)
  func overlayDidMoveCommandLineSelection(_ delta: Int) -> Bool
  func overlayDidInsertCommandLineSelection() -> Bool
  func overlayDidSubmitCommandLine(_ command: String)
  func overlayDidForceSubmitCommandLineSelection()
  func overlayDidCancelCandidateFinder()
  func overlayDidUpdateCandidateFinderQuery(_ query: String)
  func overlayDidMoveCandidateFinderSelection(_ delta: Int)
  func overlayDidSubmitCandidateFinder()
  /// `[flashlight.aliases]` lookup hook. Returns the rewritten buffer +
  /// cursor when the latest keystroke landed on `<space>` after a
  /// registered shorthand bang (`!g ` → `!google `), `nil` otherwise.
  /// Lives on the coordinator so the alias map is sourced from the
  /// live config rather than mirrored onto the panel.
  func overlayExpandFlashlightAlias(
    _ text: String, cursorIndex: Int
  ) -> (text: String, cursorIndex: Int)?
}
