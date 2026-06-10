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
}

final class CommandLineTextField: NSTextField {
  override var acceptsFirstResponder: Bool { true }
}

final class ModalTextView: NSTextView {
  weak var overlayCoordinator: OverlayCoordinator?

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    if let panel = window as? OverlayPanel, panel.consumeModalKeyDown(event) { return }
    overlayCoordinator?.overlayDidPassThroughModalKey(event)
  }

  override func cancelOperation(_ sender: Any?) {
    overlayCoordinator?.overlayDidCancelModal()
  }
}

final class OverlayPanel: NSPanel {
  static let candidateFinderMaxRows = 6
  static let candidateFinderHorizontalPadding: CGFloat = 7
  static let candidateFinderVerticalPadding: CGFloat = 5

  let contentLayer = CALayer()
  var hintLayers: [CAGradientLayer] = []
  var labelLayers: [CATextLayer] = []
  var hintLayerPool: [CAGradientLayer] = []
  var labelLayerPool: [CATextLayer] = []
  let modeBadgeLayer = CAGradientLayer()
  let modeBadgeLabel = CATextLayer()
  let commandPromptLayer = CAGradientLayer()
  let commandPromptLabel = CATextLayer()
  let commandCaretLayer = CALayer()
  let commandTextField = CommandLineTextField(frame: .zero)
  let modalScrollView = NSScrollView(frame: .zero)
  let modalTextView = ModalTextView(frame: .zero)
  let candidateFinderResultsLayer = CAGradientLayer()
  let candidateFinderResultsLabel = CATextLayer()
  let activeWindowBorderLayer = CAShapeLayer()
  var modeBadgeVisible = false
  var modeBadgeText = "INSERT"
  var modeBadgeStyle: OverlayModeBadgeStyle = .insert
  var modeBadgeCapturesInput = false
  var commandPromptVisible = false
  var commandPromptPrefix = ":"
  var candidateFinderResultsVisible = false
  var candidateFinderResultsMeasurementText = ""
  var candidateFinderResultsAttributedText: NSAttributedString?
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
  var inputMode: OverlayInputMode = .hints
  var normalModePending: String = "" {
    didSet {
      if normalModePending.isEmpty {
        normalModePendingUpdatedAt = nil
      }
    }
  }
  var normalModePendingUpdatedAt: Date?
  /// Set when a modified chord with no Flash mapping passes through to
  /// the focused app (e.g. `ctrl+q` as a tmux prefix). For the duration
  /// of `normalModeSequenceTimeoutMs` after that pass-through, any
  /// unmodified keystroke is swallowed without resolving a mapping —
  /// otherwise a tmux prefix followed by `t` would silently fire
  /// `tab_new` instead of staying as part of the user's terminal
  /// sequence. `<esc>` clears the lockout immediately.
  var normalModeChordLockoutUntil: Date?
  var normalModeMappings: CompiledMappings = CompiledMappings(Config.Mode.defaultNormalMappings)
  var normalModeSequenceTimeoutMs: Int = Config.Mode.defaultSequenceTimeoutMs
  var commandLineText: String = "" {
    didSet { commandLineCursorIndex = min(commandLineCursorIndex, commandLineText.count) }
  }
  var commandLineCursorIndex: Int = 0 {
    didSet { commandLineCursorIndex = min(max(commandLineCursorIndex, 0), commandLineText.count) }
  }
  var candidateFinderQuery: String = ""

  /// Dedicated `:clipboard` history modal. When `modalSelectable` is set the
  /// `.modal` surface renders `selectableModalLines` as a navigable list
  /// (arrows / `j` / `k`, Enter pastes the selection) instead of the
  /// read-only help / `:plugins` text where every key is consumed.
  var modalSelectable = false
  var selectableModalLines: [String] = []
  var selectableModalSelectedIndex = 0
  /// One-key vim sequence buffer for the modal: when set, the next
  /// `g` keypress maps to `scrollModal(.top)`. Cleared by any other key
  /// or by the sequence-timeout fired from
  /// `consumeModalScrollKey`.
  var modalScrollGPending = false

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
    var screens: [(scale: CGFloat, frame: CGRect)]
    var unionFrame: CGRect
    var mainFrame: CGRect?
    var mainScale: CGFloat
    var mainVisibleFrame: CGRect
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
    var screens: [(scale: CGFloat, frame: CGRect)] = []
    for s in NSScreen.screens {
      union = union.union(s.frame)
      screens.append((s.backingScaleFactor, s.frame))
    }
    if union.isNull, let main = NSScreen.main { union = main.frame }
    let main = NSScreen.main ?? NSScreen.screens.first
    return ScreenSnapshot(
      screens: screens,
      unionFrame: union,
      mainFrame: main?.frame,
      mainScale: main?.backingScaleFactor ?? 2,
      mainVisibleFrame: main?.visibleFrame ?? union)
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
    self.level = .screenSaver
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

    modeBadgeLayer.cornerRadius = 4
    modeBadgeLayer.borderWidth = 1
    modeBadgeLayer.opacity = 1
    modeBadgeLayer.actions = OverlayPanel.noActions
    modeBadgeLabel.alignmentMode = .center
    modeBadgeLabel.actions = OverlayPanel.noActions
    modeBadgeLayer.sublayers = [modeBadgeLabel]
    commandPromptLayer.cornerRadius = 4
    commandPromptLayer.borderWidth = 1
    commandPromptLayer.masksToBounds = true
    commandPromptLayer.actions = OverlayPanel.noActions
    commandPromptLabel.alignmentMode = .left
    commandPromptLabel.actions = OverlayPanel.noActions
    commandCaretLayer.actions = OverlayPanel.noActions
    commandCaretLayer.backgroundColor = Self.nordSnowStorm2CG
    commandCaretLayer.isHidden = true
    commandPromptLayer.sublayers = [commandPromptLabel, commandCaretLayer]
    candidateFinderResultsLayer.cornerRadius = 4
    candidateFinderResultsLayer.borderWidth = 1
    candidateFinderResultsLayer.masksToBounds = true
    candidateFinderResultsLayer.actions = OverlayPanel.noActions
    candidateFinderResultsLabel.alignmentMode = .left
    candidateFinderResultsLabel.isWrapped = false
    candidateFinderResultsLabel.actions = OverlayPanel.noActions
    candidateFinderResultsLayer.sublayers = [candidateFinderResultsLabel]
    activeWindowBorderLayer.fillColor = NSColor.clear.cgColor
    activeWindowBorderLayer.strokeColor = Self.nordFrost2CG
    activeWindowBorderLayer.lineWidth = 2
    activeWindowBorderLayer.actions = OverlayPanel.noActions

    self.contentView = view
    configureCommandTextField()
    configureModalTextView()
    view.addSubview(commandTextField)
    view.addSubview(modalScrollView)
    installPointerMonitors()
  }

  deinit {
    if let observer = screenParametersObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    removePointerMonitors()
    removeModalDismissMonitors()
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

  var keyboardCaptureIsActive: Bool {
    if inputMode == .commandLine {
      return isVisible && isKeyWindow
        && (firstResponder === commandTextField || commandTextField.currentEditor() != nil)
    }
    if inputMode == .modal {
      return isVisible && isKeyWindow
        && (firstResponder === self || firstResponder === modalTextView)
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
  var modalClickGlobalMonitor: Any?
  var modalClickLocalMonitor: Any?


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
  func overlayDidUpdatePrefix(_ prefix: String)
  func overlayDidHandleNormalMode(_ action: MappingCommand?, repeatCount: Int)
  func overlayDidHandleMapping(_ event: NSEvent) -> Bool
  func overlayDidCancelModal()
  func overlayDidPassThroughModalKey(_ event: NSEvent)
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
  func overlayDidSubmitSelectableModal()
}
