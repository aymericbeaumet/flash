import AppKit
import QuartzCore

/// The persistent status bar's own window. It shares the `OverlayPanel`'s
/// union-of-screens frame, so bar layout stays in overlay coordinates, is
/// transparent and click-through, and is ordered above the native menu bar and
/// its extras, so a reveal Flash did not ask for (a menu key equivalent
/// flashing its title, Flash itself becoming active, a wake) slides those
/// windows down *behind* the bar instead of painting over it. A reveal under
/// the pointer is the exception and lowers the bar; see
/// `OverlayPanel.setStatusBarYieldsToNativeMenuBar`.
final class StatusBarWindow: NSPanel {
  let contentLayer = CALayer()

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(frame: NSRect) {
    super.init(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    level = OverlayPanel.statusBarWindowLevel
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    animationBehavior = .none
    ignoresMouseEvents = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
    view.wantsLayer = true
    view.layer = contentLayer
    contentLayer.frame = view.bounds
    contentLayer.actions = OverlayPanel.noActions
    contentView = view
  }
}

extension OverlayPanel {
  static func statusBarWindowLevel(yieldingToNativeMenuBar yields: Bool) -> NSWindow.Level {
    yields ? statusBarYieldedWindowLevel : statusBarWindowLevel
  }

  /// Host the bar layers in the status-bar window and order it with the bar's
  /// visibility. The layers are parented nowhere else, so transient overlay
  /// renders that rebuild `contentLayer.sublayers` can never detach the bar.
  func syncStatusBarWindow() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    guard modeSurface.barVisible else {
      statusBarWindow.contentLayer.sublayers = nil
      statusBarWindow.orderOut(nil)
      return
    }
    let layers: [CALayer] = [modeBadgeLayer] + secondaryStatusBars.map(\.backgroundLayer)
    let hosted = statusBarWindow.contentLayer.sublayers ?? []
    if hosted.count != layers.count || !zip(hosted, layers).allSatisfy({ $0 === $1 }) {
      statusBarWindow.contentLayer.sublayers = layers
    }
    applyStatusBarWindowLevel()
    statusBarWindow.orderFrontRegardless()
  }

  /// Lower the bar below the native menu bar while the reveal probe sees it
  /// revealed under the pointer, so the native menus show and take the click;
  /// restore the elevated level as soon as it folds away again.
  func setStatusBarYieldsToNativeMenuBar(_ yields: Bool) {
    guard statusBarYieldsToNativeMenuBar != yields else { return }
    statusBarYieldsToNativeMenuBar = yields
    applyStatusBarWindowLevel()
  }

  func applyStatusBarWindowLevel() {
    let target = Self.statusBarWindowLevel(yieldingToNativeMenuBar: statusBarYieldsToNativeMenuBar)
    if statusBarWindow.level != target { statusBarWindow.level = target }
  }
}

extension OverlayPanel {
  /// What the bar window and its layers look like right now, for the HTTP
  /// inspector: enough to tell a bar that is drawn but not shown (window
  /// hidden, occluded, lowered, layers detached, text faded or never drawn)
  /// from a bar whose model is empty.
  func statusBarDiagnostics() -> [String: Any] {
    func opacity(_ layer: CALayer) -> Double {
      Double(layer.presentation()?.opacity ?? layer.opacity)
    }
    func rect(_ r: CGRect) -> [Double] {
      [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
    }
    let surface = primaryStatusBarSurface
    let background = surface.backgroundLayer
    let runs = zip(surface.visibleRuns, surface.runLayers).map { run, layers -> [String: Any] in
      [
        "text": String(run.segment.text.prefix(24)),
        "container_hidden": layers.container.isHidden,
        "container_attached": layers.container.superlayer === background,
        "container_frame": rect(layers.container.frame),
        "container_opacity": opacity(layers.container),
        "text_hidden": layers.text.isHidden,
        "text_drawn": layers.text.contents != nil,
        "text_string_empty": (layers.text.string as? NSAttributedString)?.length ?? 0 == 0,
        "text_opacity": opacity(layers.text),
        "text_frame": rect(layers.text.frame),
        "text_animations": layers.text.animationKeys() ?? [],
      ]
    }
    let hintSnapshot: String
    switch statusBarHintSnapshot {
    case .live: hintSnapshot = "live"
    case .held: hintSnapshot = "held"
    }
    return [
      "bar_visible": modeSurface.barVisible,
      "badge_text": modeSurface.label,
      "badge_style": String(describing: modeSurface.style),
      "hint_snapshot": hintSnapshot,
      "yields_to_native_menu_bar": statusBarYieldsToNativeMenuBar,
      "document_runs": statusBarModel.document.runs.count,
      "window": [
        "visible": statusBarWindow.isVisible,
        "occlusion_visible": statusBarWindow.occlusionState.contains(.visible),
        "on_active_space": statusBarWindow.isOnActiveSpace,
        "level": statusBarWindow.level.rawValue,
        "alpha": Double(statusBarWindow.alphaValue),
        "frame": rect(statusBarWindow.frame),
        "hosted_layers": statusBarWindow.contentLayer.sublayers?.count ?? 0,
      ],
      "background": [
        "attached": background.superlayer === statusBarWindow.contentLayer,
        "hidden": background.isHidden,
        "opacity": opacity(background),
        "frame": rect(background.frame),
      ],
      "render": [
        "visible": surface.lastRenderStats.visible,
        "changed": surface.lastRenderStats.changed,
      ],
      "runs": runs,
    ]
  }
}
