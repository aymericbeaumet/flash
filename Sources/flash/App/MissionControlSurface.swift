import AppKit
import ApplicationServices
import FlashCore
import FlashProviders

/// `f` while Mission Control or App Exposé is up: the Dock's window
/// thumbnails, the Spaces bar's desktops and its add-desktop button, read
/// from the Dock's Accessibility tree under the existing grant. Nothing reads
/// the screen; the view is known from the Dock's own reports
/// (`SystemSurfaceController`), and every commit is a click
/// `ActionDispatcher` posts at the target's centre.
///
/// The tree the Dock builds once the view's animation ends (macOS 14–26):
///
///     AXGroup "mc"                      Mission Control
///       AXGroup "mc.display"            one per display
///         AXGroup "mc.windows"          the current desktop's windows
///           AXButton                    a window thumbnail
///         AXGroup "mc.spaces"           the Spaces bar
///           AXList "mc.spaces.list"     its desktops and full-screen apps
///             AXButton
///           AXButton "mc.spaces.add"    add a desktop
///     AXGroup "appexpose"               App Exposé
///       AXGroup "appexpose.display"
///         AXButton                      one of the app's windows
enum MissionControlSurface {
  static let providerID = "mission_control"
  static let dockBundleIdentifier = "com.apple.dock"

  /// What a target is; its raw value is the target's `contextID`.
  enum Kind: String, CaseIterable {
    case window = "mission_control.window"
    case desktop = "mission_control.desktop"
    case addDesktop = "mission_control.add_desktop"
  }

  enum Identifier {
    static let missionControl = "mc"
    static let display = "mc.display"
    static let windows = "mc.windows"
    static let spaces = "mc.spaces"
    static let spacesList = "mc.spaces.list"
    static let addDesktop = "mc.spaces.add"
    static let appExpose = "appexpose"
  }

  /// One element of the Dock's tree, as read for hinting. Generic over the
  /// element so the extraction runs on a fake tree.
  struct Node<Element> {
    var element: Element
    var identifier: String?
    var role: String?
    /// NSScreen coordinates; nil when unreadable or smaller than 3×3 points.
    var frame: CGRect?
    var hidden: Bool
    var children: [Node<Element>]
  }

  struct Pick<Element> {
    var element: Element
    var kind: Kind
  }

  enum Reading<Element> {
    /// The view's tree is complete: its targets, in label order (possibly
    /// none, App Exposé of an app with no window).
    case ready([Pick<Element>])
    /// The Dock has not built the view's tree yet. Never served as a
    /// partial set.
    case building
  }

  /// The view `f` labels instead of the windows: Mission Control or App
  /// Exposé. Show Desktop shows nothing of the Dock's to press, and an
  /// unknown view (a silent Dock) labels nothing of the Dock's.
  static func labelledView(_ view: DockView?) -> DockView? {
    switch view {
    case .missionControl?, .appWindows?: return view
    case .desktop?, DockView.none?, nil: return nil
    }
  }

  /// The targets of `view` in the Dock application's children `roots`.
  /// Windows come first, display by display from the left and in reading
  /// order on each; then the desktops in Spaces-bar order; then each
  /// display's add-desktop button. Hidden subtrees are skipped whole.
  static func reading<Element>(of view: DockView, in roots: [Node<Element>]) -> Reading<Element> {
    switch view {
    case .missionControl:
      guard
        let group = roots.first(where: { $0.identifier == Identifier.missionControl }),
        !group.hidden
      else { return .building }
      let displays = ordered(
        group.children.filter { $0.identifier == Identifier.display && !$0.hidden })
      // The Spaces bar appears last, a moment after the thumbnails. With
      // "Displays have separate Spaces" off one bar serves every display, so
      // one is what a complete tree has.
      guard
        displays.contains(where: { display in
          display.children.contains { $0.identifier == Identifier.spaces && !$0.hidden }
        })
      else { return .building }
      var windows: [Pick<Element>] = []
      var desktops: [Pick<Element>] = []
      var adds: [Pick<Element>] = []
      for display in displays {
        var shown: [(Element, CGRect)] = []
        for child in display.children where !child.hidden {
          if child.identifier == Identifier.spaces {
            collectSpaces(child, desktops: &desktops, adds: &adds)
          } else {
            collectButtons(child, into: &shown)
          }
        }
        windows += readingOrder(shown).map { Pick(element: $0, kind: .window) }
      }
      return .ready(windows + desktops + adds)
    case .appWindows:
      guard
        let group = roots.first(where: { $0.identifier == Identifier.appExpose }),
        !group.hidden, !group.children.isEmpty
      else { return .building }
      var windows: [Pick<Element>] = []
      for display in ordered(group.children.filter { !$0.hidden }) {
        var shown: [(Element, CGRect)] = []
        collectButtons(display, into: &shown)
        windows += readingOrder(shown).map { Pick(element: $0, kind: .window) }
      }
      return .ready(windows)
    case .desktop, .none:
      return .ready([])
    }
  }

  /// Deeper than any Mission Control layout; guards an AX cycle.
  static let maxDepth = 12

  /// Displays from the left, then from the top; a display without a frame
  /// keeps its place after the others.
  private static func ordered<Element>(_ displays: [Node<Element>]) -> [Node<Element>] {
    displays.enumerated().sorted { lhs, rhs in
      switch (lhs.element.frame, rhs.element.frame) {
      case (let a?, let b?):
        if a.minX != b.minX { return a.minX < b.minX }
        if a.maxY != b.maxY { return a.maxY > b.maxY }
        return lhs.offset < rhs.offset
      case (.some, nil): return true
      case (nil, .some): return false
      case (nil, nil): return lhs.offset < rhs.offset
      }
    }.map(\.element)
  }

  /// Top row first (NSScreen y grows upward), then from the left; ties keep
  /// tree order.
  private static func readingOrder<Element>(_ shown: [(Element, CGRect)]) -> [Element] {
    shown.enumerated().sorted { lhs, rhs in
      let a = lhs.element.1
      let b = rhs.element.1
      if a.maxY.rounded() != b.maxY.rounded() { return a.maxY > b.maxY }
      if a.minX.rounded() != b.minX.rounded() { return a.minX < b.minX }
      return lhs.offset < rhs.offset
    }.map(\.element.0)
  }

  /// Every visible, framed button under `node`, a button's own subtree
  /// excluded (its parts are the button).
  private static func collectButtons<Element>(
    _ node: Node<Element>, depth: Int = 0, into shown: inout [(Element, CGRect)]
  ) {
    guard !node.hidden, depth <= maxDepth else { return }
    if node.role == (kAXButtonRole as String) {
      if let frame = node.frame, !frame.isEmpty { shown.append((node.element, frame)) }
      return
    }
    for child in node.children { collectButtons(child, depth: depth + 1, into: &shown) }
  }

  /// The Spaces bar: its list's buttons in bar order, and its add button.
  private static func collectSpaces<Element>(
    _ spaces: Node<Element>, desktops: inout [Pick<Element>], adds: inout [Pick<Element>]
  ) {
    for child in spaces.children where !child.hidden {
      if child.identifier == Identifier.addDesktop {
        if child.frame.map({ !$0.isEmpty }) == true {
          adds.append(Pick(element: child.element, kind: .addDesktop))
        }
      } else if child.identifier == Identifier.spacesList {
        var shown: [(Element, CGRect)] = []
        collectButtons(child, into: &shown)
        desktops += shown.map { Pick(element: $0.0, kind: .desktop) }
      }
    }
  }

  // MARK: Targets

  /// `picks` as hint targets. `capture` reads one element into a target
  /// that validates its identity before the click (nil when it is gone); the
  /// result is the Dock's, with no pid — the Dock never becomes the frontmost
  /// app, so the click waits on no activation — and never a typing surface.
  static func jumpTargets<Element>(
    _ picks: [Pick<Element>], capture: (Element, String) -> JumpTarget?
  ) -> [JumpTarget] {
    picks.enumerated().compactMap { index, pick in
      guard let captured = capture(pick.element, "\(pick.kind.rawValue)_\(index)") else {
        return nil
      }
      return JumpTarget(
        id: captured.id, frame: captured.frame, role: captured.role,
        accessibilityLabel: captured.accessibilityLabel, url: captured.url,
        contextID: pick.kind.rawValue, pid: nil, resolveClickPoint: captured.resolveClickPoint,
        providerID: providerID)
    }
  }

  static func kind(of target: JumpTarget) -> Kind? {
    guard target.providerID == providerID else { return nil }
    return target.contextID.flatMap(Kind.init(rawValue:))
  }

  /// A window or a desktop leaves Mission Control; the add-desktop button
  /// keeps it open.
  static func clickLeavesView(_ target: JumpTarget?) -> Bool {
    guard let target, let kind = kind(of: target) else { return false }
    return kind != .addDesktop
  }

  // MARK: Accessibility

  /// What one read of the Dock found.
  enum Discovery {
    /// The view's targets, in label order.
    case targets([JumpTarget])
    /// The Dock is still building the view's tree.
    case building
    /// No Dock is running.
    case noDock
  }

  /// The Dock's targets for `view`, read off main: one children read of the
  /// Dock's application element, then the view's group alone (never the
  /// Dock's tiles).
  static func discover(view: DockView, screenH: CGFloat) -> Discovery {
    guard
      let pid = NSRunningApplication.runningApplications(
        withBundleIdentifier: dockBundleIdentifier
      ).first(where: { !$0.isTerminated })?.processIdentifier
    else { return .noDock }
    let app = AXApp.make(pid: pid)
    let wanted = view == .appWindows ? Identifier.appExpose : Identifier.missionControl
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &raw) == .success,
      let children = raw as? [AXUIElement]
    else { return .building }
    let roots = children.compactMap { child -> Node<AXUIElement>? in
      guard string(child, identifierAttribute) == wanted else { return nil }
      return readNode(child, depth: 0, screenH: screenH)
    }
    guard case .ready(let picks) = reading(of: view, in: roots) else { return .building }
    return .targets(
      jumpTargets(picks) { element, id in
        AccessibilityProvider.captureTarget(
          element: element, id: id, pid: pid, screenH: screenH, providerID: providerID,
          bundleIdentifier: dockBundleIdentifier)
      })
  }

  private static let identifierAttribute = "AXIdentifier"

  private static let nodeAttributes: CFArray =
    [
      identifierAttribute as CFString,  // 0
      kAXRoleAttribute,  // 1
      kAXPositionAttribute,  // 2
      kAXSizeAttribute,  // 3
      kAXHiddenAttribute,  // 4
      kAXChildrenAttribute,  // 5
    ] as CFArray

  private static func readNode(
    _ element: AXUIElement, depth: Int, screenH: CGFloat
  ) -> Node<AXUIElement> {
    var raw: CFArray?
    guard
      AXUIElementCopyMultipleAttributeValues(
        element, nodeAttributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
      let values = raw as? [Any], values.count == 6
    else {
      return Node(
        element: element, identifier: nil, role: nil, frame: nil, hidden: false, children: [])
    }
    let children = depth < maxDepth ? (values[5] as? [AXUIElement] ?? []) : []
    return Node(
      element: element,
      identifier: values[0] as? String,
      role: values[1] as? String,
      frame: frame(position: values[2], size: values[3], screenH: screenH)
        ?? axFrame(element, screenH: screenH),
      hidden: values[4] as? Bool ?? false,
      children: children.map { readNode($0, depth: depth + 1, screenH: screenH) })
  }

  private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else {
      return nil
    }
    return raw as? String
  }

  private static func frame(position: Any, size: Any, screenH: CGFloat) -> CGRect? {
    let positionRef = position as CFTypeRef
    let sizeRef = size as CFTypeRef
    guard CFGetTypeID(positionRef) == AXValueGetTypeID(),
      CFGetTypeID(sizeRef) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
      AXValueGetValue(sizeRef as! AXValue, .cgSize, &extent),
      extent.width >= 3, extent.height >= 3
    else { return nil }
    return ScreenRect<AXSpace>(CGRect(origin: origin, size: extent)).toNS(primaryHeight: screenH)
      .cgRect
  }

  /// Dock elements may expose `AXFrame` alone.
  private static func axFrame(_ element: AXUIElement, screenH: CGFloat) -> CGRect? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &raw) == .success,
      let raw, CFGetTypeID(raw) == AXValueGetTypeID()
    else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.width >= 3, rect.height >= 3
    else { return nil }
    return ScreenRect<AXSpace>(rect).toNS(primaryHeight: screenH).cgRect
  }
}
