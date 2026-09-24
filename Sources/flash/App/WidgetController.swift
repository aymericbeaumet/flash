import AppKit

/// Owns the desktop widgets' windows, one per enabled widget per display it
/// shows on, on the main thread. The status controller evaluates the widgets
/// and hands their lines here (`show`); this lays them out, places each
/// window in its display's Flash-usable frame, and reports back whether any
/// window of a widget can be seen, so an occluded widget stops refreshing.
final class WidgetController {
  private struct WindowKey: Hashable, Comparable {
    var widget: String
    var display: CGDirectDisplayID

    static func < (lhs: Self, rhs: Self) -> Bool {
      (lhs.widget, lhs.display) < (rhs.widget, rhs.display)
    }
  }

  private struct Placed {
    let window: WidgetWindow
    let surface: WidgetSurface
    var occlusionObserver: NSObjectProtocol?
    /// Occlusion reports are trusted only once they have shown the window
    /// visible: a desktop-level window whose reports never say `.visible`
    /// would otherwise stop its widget for good.
    var occlusionTrusted = false
    var visible = true
  }

  typealias ScreenLayouts = (Bool, Config.StatusBar.Monitor) -> [WindowScreenLayout]

  private let setVisible: (String, Bool) -> Void
  private let screenLayouts: ScreenLayouts
  private var widgets: [String: Config.Widget] = [:]
  private var lines: [String: [StatusFormatDocument]] = [:]
  private var placed: [WindowKey: Placed] = [:]
  private var reportedVisible: [String: Bool] = [:]
  private var statusBarReservesSpace = false
  private var statusBarMonitor = Config.StatusBar.Monitor.all
  private var screenCapture = ScreenCaptureVisibility.show
  private var screenObserver: NSObjectProtocol?
  /// The displays as of the last full reconcile; a line update re-uses them.
  private var layouts: [WindowScreenLayout] = []

  init(
    setVisible: @escaping (String, Bool) -> Void,
    screenLayouts: @escaping ScreenLayouts = { reserves, monitor in
      WindowMover.screenLayouts(statusBarReservesSpace: reserves, statusBarMonitor: monitor)
    }
  ) {
    self.setVisible = setVisible
    self.screenLayouts = screenLayouts
  }

  /// The enabled widgets and what their placement depends on: whether the
  /// Flash bar reserves its band, and `[overlay] screen_capture`.
  func apply(
    widgets: [String: Config.Widget], statusBarReservesSpace: Bool,
    statusBarMonitor: Config.StatusBar.Monitor, screenCapture: ScreenCaptureVisibility
  ) {
    self.widgets = widgets
    self.statusBarReservesSpace = statusBarReservesSpace
    self.statusBarMonitor = statusBarMonitor
    self.screenCapture = screenCapture
    lines = lines.filter { widgets[$0.key] != nil }
    // A removed widget last reported covered returns to the state every
    // listener gives a widget that appears: visible. Otherwise re-adding it
    // would keep it covered, since its first visible report is not sent.
    for name in Self.forgottenHidden(reportedVisible, keeping: Set(widgets.keys)) {
      setVisible(name, true)
    }
    reportedVisible = reportedVisible.filter { widgets[$0.key] != nil }
    if widgets.isEmpty {
      if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
      screenObserver = nil
    } else if screenObserver == nil {
      // Scoped to having widgets: displays arriving, leaving or changing
      // resolution re-place every window.
      screenObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.reconcile() }
    }
    reconcile()
  }

  /// A widget's newly evaluated lines, from the status controller's sink.
  func show(_ name: String, lines: [StatusFormatDocument]) {
    guard widgets[name] != nil else { return }
    self.lines[name] = lines
    reconcile(only: name)
  }

  func stop() {
    apply(
      widgets: [:], statusBarReservesSpace: statusBarReservesSpace,
      statusBarMonitor: statusBarMonitor, screenCapture: screenCapture)
  }

  /// Create, re-place, redraw or close windows so each enabled widget has one
  /// per display it selects. Frames are set only when they change.
  private func reconcile(only: String? = nil) {
    if only == nil { layouts = screenLayouts(statusBarReservesSpace, statusBarMonitor) }
    var wanted = Set<WindowKey>()
    for name in only.map({ [$0] }) ?? widgets.keys.sorted() {
      guard let widget = widgets[name] else { continue }
      for screen in WidgetPlacement.screens(widget.screen, layouts: layouts, widget: name) {
        let key = WindowKey(widget: name, display: screen.id)
        wanted.insert(key)
        place(key, widget: widget, screen: screen)
      }
    }
    guard only == nil else { return }
    for key in placed.keys.sorted() where !wanted.contains(key) {
      guard let entry = placed.removeValue(forKey: key) else { continue }
      if let observer = entry.occlusionObserver {
        NotificationCenter.default.removeObserver(observer)
      }
      entry.window.orderOut(nil)
      entry.window.close()
    }
    for name in widgets.keys { reportVisibility(name) }
  }

  private func place(_ key: WindowKey, widget: Config.Widget, screen: WindowScreenLayout) {
    let sharing: NSWindow.SharingType =
      widget.hideFromCapture ? .none : screenCapture.sharingType
    if placed[key] == nil {
      let window = WidgetWindow(frame: .zero, sharingType: sharing)
      let surface = WidgetSurface()
      window.contentLayer.addSublayer(surface.backgroundLayer)
      var entry = Placed(window: window, surface: surface)
      entry.occlusionObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
      ) { [weak self] _ in self?.occlusionChanged(key) }
      placed[key] = entry
    }
    guard let entry = placed[key] else { return }
    if entry.window.sharingType != sharing { entry.window.sharingType = sharing }
    guard let lines = lines[key.widget], !lines.isEmpty else {
      // Nothing to show yet: keep the widget refreshing so content can come.
      entry.window.orderOut(nil)
      placed[key]?.visible = true
      return
    }
    let scale =
      NSScreen.screens.first { $0.displayID == screen.id }?.backingScaleFactor
      ?? NSScreen.main?.backingScaleFactor ?? 2
    let size = entry.surface.render(lines: lines, widget: widget, scale: scale)
    let frame = OverlayPanel.snap(
      WidgetPlacement.frame(
        anchor: widget.anchor, gap: CGSize(width: widget.gapX, height: widget.gapY),
        size: size, usable: screen.usableFrame),
      scale: scale)
    if entry.window.frame != frame { entry.window.setFrame(frame, display: false) }
    if !entry.window.isVisible { entry.window.orderFrontRegardless() }
  }

  private func occlusionChanged(_ key: WindowKey) {
    guard var entry = placed[key] else { return }
    let visible = entry.window.occlusionState.contains(.visible)
    if visible { entry.occlusionTrusted = true }
    // A window ordered out for lack of content is not occluded.
    entry.visible = visible || !entry.occlusionTrusted || !entry.window.isVisible
    placed[key] = entry
    reportVisibility(key.widget)
  }

  /// Widgets last reported covered that `names` no longer holds.
  static func forgottenHidden(_ reported: [String: Bool], keeping names: Set<String>) -> [String] {
    reported.filter { !$0.value && !names.contains($0.key) }.map(\.key).sorted()
  }

  /// A widget is visible while any of its windows is — none on a display it
  /// selects means nothing to refresh; the status controller hears only
  /// changes.
  private func reportVisibility(_ name: String) {
    let visible = placed.contains { $0.key.widget == name && $0.value.visible }
    guard reportedVisible[name] != visible else { return }
    let first = reportedVisible[name] == nil
    reportedVisible[name] = visible
    // Every widget starts visible on the controller's side.
    if first && visible { return }
    setVisible(name, visible)
  }

  /// The inspector's view of every widget window.
  func diagnostics() -> [String: Any] {
    func rect(_ r: CGRect) -> [Double] {
      [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
    }
    return [
      "widgets": widgets.keys.sorted(),
      "windows": placed.keys.sorted().compactMap { key -> [String: Any]? in
        guard let entry = placed[key] else { return nil }
        return [
          "widget": key.widget,
          "display": Int(key.display),
          "frame": rect(entry.window.frame),
          "ordered_in": entry.window.isVisible,
          "level": entry.window.level.rawValue,
          "occlusion_visible": entry.window.occlusionState.contains(.visible),
          "occlusion_trusted": entry.occlusionTrusted,
          "refreshing": entry.visible,
          "lines": lines[key.widget]?.count ?? 0,
          "runs": entry.surface.runLayers.filter { !$0.container.isHidden }.count,
        ]
      },
    ]
  }
}
