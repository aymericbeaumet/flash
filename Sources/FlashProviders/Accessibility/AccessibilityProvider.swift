import AppKit
import ApplicationServices
import FlashCore

/// Single, universal AX walker. No per-app variants — every macOS app is
/// treated by the same rules: clickable controls, text inputs, and rows in
/// virtualised lists. Section-header rows are suppressed via `skipSubroles`.
///
/// The role/skip/depth/target sets are intentionally *not* exposed for
/// per-app override. The project's working assumption is that generic rules
/// are good enough; if a specific app misbehaves we tune the universal set,
/// not the per-app fork. See AGENTS.md ("Project layout" + "Browser DOM
/// bridge") for the rationale.
///
/// Performance contract:
///   - Exactly one IPC per visited element (batched via
///     AXUIElementCopyMultipleAttributeValues).
///   - Prefer kAXVisibleChildrenAttribute over kAXChildrenAttribute so
///     scrolled-off content in NSOutlineView / NSTableView / NSCollectionView
///     is never walked. On Notes' 292-row sidebar this turns a ~300-element
///     walk into a ~30-element walk — only the visible rows are touched.
///   - No mid-walk deadline truncation: walks always complete (so the set of
///     returned targets is deterministic).
public final class AccessibilityProvider: JumpProvider {
  public let identifier: String = "accessibility"
  public let priority: Int = 10

  /// Every clickable / focusable role we recognise. Generic across apps.
  public static let roles: Set<String> = [
    // Click targets
    "AXButton", "AXLink",
    "AXMenuItem", "AXMenuButton",
    "AXPopUpButton",
    "AXCheckBox", "AXRadioButton",
    "AXTab",
    "AXDisclosureTriangle",
    // Text inputs
    "AXTextField", "AXSearchField", "AXTextArea",
    // Virtualised list rows (each row is one click target)
    "AXRow", "AXCell",
    // Icon-only buttons sometimes report as AXImage. Gated below by
    // ancestor-role + AXPress to avoid double-hinting decorative
    // images inside links/buttons.
    "AXImage",
  ]

  /// Roles whose descendant AXImage is considered decorative (already
  /// covered by the ancestor's hint). Hits the common Firefox case of
  /// `<a><img/>text</a>` exposing both AXLink and AXImage on the same
  /// row — without this filter we'd hint both.
  public static let clickableContainerRoles: Set<String> = [
    "AXLink", "AXButton",
    "AXMenuItem", "AXMenuButton",
    "AXPopUpButton",
    "AXCheckBox", "AXRadioButton",
    "AXTab",
  ]

  /// Roles where we add a target and *do not* descend further. Restricted
  /// to virtualised-list rows because those are the only elements where the
  /// fanout below the target is both huge (per-row icons, labels, dates)
  /// and uninteresting (no independent click targets). For everything
  /// else — buttons, popups, menu items — we descend, which means a
  /// button that has an open menu underneath it gets its menu items
  /// hinted alongside the button itself.
  public static let leafRoles: Set<String> = [
    "AXRow", "AXCell",
  ]

  /// AppKit's standard subroles for "section header" rows in
  /// NSOutlineView/NSTableView. We *don't* add these as targets, but we
  /// keep descending — so the disclosure triangle inside the header gets
  /// hinted on its own.
  public static let skipSubroles: Set<String> = [
    "AXOutlineSecondaryRow",
    "AXSecondaryOutlineRow",
    "AXSeparatorRow",
    "AXGroupRow",
  ]

  /// Roles for which "click" really means "focus the input". AXPress on a
  /// search field is a no-op and a synthesized mouse click on top of an
  /// already-keyed app may land in the wrong subview; setting
  /// `kAXFocusedAttribute = true` is the unambiguous AX-level way.
  static let textInputRoles: Set<String> = [
    "AXTextField", "AXSearchField", "AXTextArea",
  ]

  public static let maxDepth: Int = 80
  public static let maxTargets: Int = 1500

  /// When set, the next walk writes one line per visited element to this
  /// file. Owned and toggled by AppMonitor based on `debug.dump_ax`. The
  /// AX provider runs serially on a single queue (see AppMonitor), so a
  /// plain mutable property is safe here.
  public var dumpURL: URL?

  public init() {}

  public func supports(_ context: AppContext) -> Bool { true }

  // Cached CFTypeID for AXValue. AXUIElementCopyMultipleAttributeValues
  // returns AXValueAttributeError (which is itself an AXValue with type
  // .axError) for attributes the element doesn't implement, so we can't
  // distinguish "real AXValue" from "error placeholder" through Swift's
  // `as?` operator alone — they're both CFType-bridged and the cast
  // always succeeds. Compare CFTypeIDs explicitly.
  private static let axValueTypeID: CFTypeID = AXValueGetTypeID()

  private static func axValue(_ v: Any) -> AXValue? {
    let cf = v as CFTypeRef
    guard CFGetTypeID(cf) == axValueTypeID else { return nil }
    return (cf as! AXValue)
  }

  // The attribute array we pass to AXUIElementCopyMultipleAttributeValues.
  // Indices are hot-path constants — keep them in sync with `walk`.
  private static let batchAttrs: CFArray =
    [
      kAXRoleAttribute,  // 0
      kAXSubroleAttribute,  // 1
      kAXPositionAttribute,  // 2
      kAXSizeAttribute,  // 3
      kAXEnabledAttribute,  // 4
      "AXVisibleChildren",  // 5 — virtualised containers
      "AXVisibleRows",  // 6 — NSTableView / NSOutlineView specifically
      kAXChildrenAttribute,  // 7 — fallback
    ] as CFArray

  public func discover(in context: AppContext, deadline: Date) throws -> [JumpTarget] {
    try discover(in: context, deadline: deadline, descendIntoWebAreas: true)
  }

  /// `descendIntoWebAreas` is false only when a higher-priority browser DOM
  /// provider already returned page targets. In that case AX still
  /// contributes browser chrome controls, but skipping AXWebArea descendants
  /// avoids walking the entire web page twice.
  public func discover(
    in context: AppContext,
    deadline _: Date,
    descendIntoWebAreas: Bool
  ) throws -> [JumpTarget] {
    let app = AXUIElementCreateApplication(context.processID)
    let screenH = primaryScreenHeight()

    // The clip rect is supplied by AppMonitor from its single
    // WindowServer visibility snapshot. This is stricter than the screen
    // frame:
    //   - AX can report frames for scrolled-off rows that happen to fall
    //     within the screen bounds (below the Notes window, on the
    //     wallpaper). Those rejected here.
    //   - Popover/menu windows owned by the same process are included in
    //     the snapshot's visible region. Hints on those items pass
    //     through without doing a second CGWindowListCopyWindowInfo call
    //     per provider.
    let clip = context.frontWindowFrame
    guard !clip.isNull else { return [] }

    var out: [JumpTarget] = []
    var idCounter = 0

    // Open the dump file (truncate) if requested. We hold the handle
    // for the whole walk so per-element writes don't reopen on each
    // line.
    var dumpHandle: FileHandle?
    if let url = dumpURL {
      dumpHandle = openDumpFile(at: url, context: context)
    }
    defer { try? dumpHandle?.close() }

    // Walk straight from the app element. The batched read inside `walk`
    // pulls kAXChildrenAttribute as one of its fields, so we don't need
    // a separate kAXChildrenAttribute IPC on the app first. The app's
    // role (AXApplication) doesn't match `roles`, so it doesn't become
    // a target itself — it just descends.
    walk(
      app, depth: 0, screenH: screenH, visible: clip,
      pid: context.processID, descendIntoWebAreas: descendIntoWebAreas,
      insideClickable: false, parentRole: nil, dump: dumpHandle,
      out: &out, idCounter: &idCounter)
    return out
  }

  private func openDumpFile(at url: URL, context: AppContext) -> FileHandle? {
    let fm = FileManager.default
    try? fm.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    fm.createFile(atPath: url.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
    let header =
      "# flash AX dump  bundle=\(context.bundleIdentifier)  pid=\(context.processID)  time=\(Date())\n"
    if let data = header.data(using: .utf8) { handle.write(data) }
    return handle
  }

  private func walk(
    _ element: AXUIElement,
    depth: Int,
    screenH: CGFloat,
    visible: CGRect,
    pid: pid_t,
    descendIntoWebAreas: Bool,
    insideClickable: Bool,
    parentRole: String?,
    dump: FileHandle?,
    out: inout [JumpTarget],
    idCounter: inout Int
  ) {
    if depth > Self.maxDepth { return }
    if out.count >= Self.maxTargets { return }

    var valuesRef: CFArray?
    let err = AXUIElementCopyMultipleAttributeValues(
      element,
      Self.batchAttrs,
      AXCopyMultipleAttributeOptions(rawValue: 0),
      &valuesRef
    )
    guard err == .success, let vals = valuesRef as? [Any], vals.count == 8 else { return }

    let role = vals[0] as? String
    let subrole = vals[1] as? String
    let posValue = Self.axValue(vals[2])
    let sizeValue = Self.axValue(vals[3])
    let enabled = (vals[4] as? Bool) ?? true
    let visibleChildren = vals[5] as? [AXUIElement]
    let visibleRows = vals[6] as? [AXUIElement]
    let allChildren = vals[7] as? [AXUIElement]

    if !descendIntoWebAreas, role == "AXWebArea" {
      return
    }

    // When dumping, fetch the supported actions + label upfront so the
    // line includes enough signal to diagnose role mismatches. Skipped
    // in the normal hot path — those IPCs are not free.
    var dumpActions: [String]? = nil
    var dumpLabel: String? = nil
    if dump != nil {
      dumpActions = actionNames(element)
      dumpLabel =
        stringAttr(element, kAXTitleAttribute as CFString)
        ?? stringAttr(element, kAXDescriptionAttribute as CFString)
        ?? stringAttr(element, kAXValueAttribute as CFString)
    }

    var addedAsTarget = false
    if enabled,
      let r = role, Self.roles.contains(r),
      let posV = posValue, let sizeV = sizeValue,
      let frame = frameFromAX(pos: posV, size: sizeV, screenH: screenH)
    {
      // Skip subroles that mark non-target group containers (e.g. outline
      // section headers). We still descend, so their children can be
      // hinted individually.
      let suppressed = subrole.map { Self.skipSubroles.contains($0) } ?? false
      // AXImage refinement:
      //   1. If we're inside a clickable container ancestor (AXLink,
      //      AXButton, ...) treat the image as decorative — the
      //      ancestor already owns the hint. Kills the
      //      `<a><img/>text</a>` double-hint case in Firefox.
      //   2. If we're standalone (no clickable ancestor), an AXImage
      //      is only a real click target when it exposes a press
      //      action. Pure decorative `<img>` exposes no actions.
      //   See AccessibilityProvider.clickableContainerRoles.
      var imageDecorative = false
      if r == "AXImage" {
        if insideClickable {
          imageDecorative = true
        } else if !imageHasPressAction(element) {
          imageDecorative = true
        }
      }
      if !suppressed, !imageDecorative {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if visible.contains(center) {
          let clipped = frame.intersection(visible)
          if !clipped.isNull, clipped.width >= 4, clipped.height >= 4 {
            idCounter += 1
            let captured = element
            let capturedRole = r
            // CGEvent uses Y-down screen coords (origin top-left of
            // primary). Our `frame` is in NSScreen coords (Y-up,
            // origin bottom-left), so flip back.
            let cgClickPoint = CGPoint(x: frame.midX, y: screenH - frame.midY)
            let activate: ((JumpAction) -> Bool) = { action in
              switch action {
              case .leftClick:
                // Text inputs don't respond to AXPress — pressing a
                // search field is meaningless. The correct AX-level
                // action is to set kAXFocusedAttribute = true, which
                // moves keyboard focus to the field. The user can
                // then start typing immediately.
                if Self.textInputRoles.contains(capturedRole) {
                  let setErr = AXUIElementSetAttributeValue(
                    captured,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                  )
                  if setErr == .success { return true }
                }
                if AXUIElementPerformAction(captured, kAXPressAction as CFString) == .success {
                  return true
                }
                if AXUIElementPerformAction(captured, "AXOpen" as CFString) == .success {
                  return true
                }
                if AXUIElementPerformAction(captured, "AXConfirm" as CFString) == .success {
                  return true
                }
                // Fallback: AX action didn't take. Try to
                // locate a descendant that *does* expose a
                // press action and click on its centre — the
                // detected node may be an inert
                // `<div role="tab">` whose actual handler
                // lives a level or two below. If no clickable
                // descendant exists, synthesize a click at
                // the detected element's own centre as the
                // ultimate fallback.
                if let (childEl, childCG) = Self.firstActionableDescendant(
                  captured, screenH: screenH)
                {
                  if AXUIElementPerformAction(childEl, kAXPressAction as CFString) == .success {
                    return true
                  }
                  if AXUIElementPerformAction(childEl, "AXOpen" as CFString) == .success {
                    return true
                  }
                  if AXUIElementPerformAction(childEl, "AXConfirm" as CFString) == .success {
                    return true
                  }
                  return Self.synthesizeMouseClick(at: childCG, button: .left)
                }
                return Self.synthesizeMouseClick(at: cgClickPoint, button: .left)
              case .rightClick:
                if AXUIElementPerformAction(captured, kAXShowMenuAction as CFString) == .success {
                  return true
                }
                if let (childEl, childCG) = Self.firstActionableDescendant(
                  captured, screenH: screenH)
                {
                  if AXUIElementPerformAction(childEl, kAXShowMenuAction as CFString) == .success {
                    return true
                  }
                  return Self.synthesizeMouseClick(at: childCG, button: .right)
                }
                return Self.synthesizeMouseClick(at: cgClickPoint, button: .right)
              }
            }
            out.append(
              JumpTarget(
                id: "ax-\(pid)-\(idCounter)",
                frame: frame,
                role: r,
                accessibilityLabel: nil,
                pid: pid,
                activate: activate,
                providerID: identifier
              ))
            addedAsTarget = true
          }
        }
      }
    }

    // Leaf-role pruning: stop descending once we've added a target whose
    // role we consider atomic.
    if addedAsTarget, let r = role, Self.leafRoles.contains(r) {
      return
    }

    // Emit a dump line for this element (after the gating decision so
    // the dump reflects what the walker actually saw + did). We log
    // every visited node, not just the ones that become targets — the
    // false-negatives are exactly the lines without a `hint=1` tag.
    if let dump = dump {
      writeDumpLine(
        dump,
        depth: depth,
        role: role,
        subrole: subrole,
        parentRole: parentRole,
        posValue: posValue,
        sizeValue: sizeValue,
        screenH: screenH,
        enabled: enabled,
        actions: dumpActions ?? [],
        label: dumpLabel,
        hinted: addedAsTarget
      )
    }

    // Prefer the narrowest "visible" view of children that the element
    // implements:
    //   1. kAXVisibleChildrenAttribute (NSCollectionView, generic scroll)
    //   2. kAXVisibleRowsAttribute (NSTableView / NSOutlineView)
    //   3. kAXChildrenAttribute (everything else, fallback)
    // For Notes' 292-row sidebar this drops the walk to the ~12 rows
    // actually rendered on screen.
    let children = visibleChildren ?? visibleRows ?? allChildren ?? []
    let nowInsideClickable =
      insideClickable || (role.map { Self.clickableContainerRoles.contains($0) } ?? false)
    for child in children {
      walk(
        child,
        depth: depth + 1,
        screenH: screenH,
        visible: visible,
        pid: pid,
        descendIntoWebAreas: descendIntoWebAreas,
        insideClickable: nowInsideClickable,
        parentRole: role,
        dump: dump,
        out: &out,
        idCounter: &idCounter
      )
      if out.count >= Self.maxTargets { return }
    }
  }

  private func primaryScreenHeight() -> CGFloat {
    if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
      return primary.frame.height
    }
    return NSScreen.main?.frame.height ?? 1080
  }

  private func frameFromAX(pos: AXValue, size: AXValue, screenH: CGFloat) -> CGRect? {
    guard AXValueGetType(pos) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
    var origin = CGPoint.zero
    var sz = CGSize.zero
    AXValueGetValue(pos, .cgPoint, &origin)
    AXValueGetValue(size, .cgSize, &sz)
    if sz.width <= 0 || sz.height <= 0 { return nil }
    let flippedY = screenH - origin.y - sz.height
    return CGRect(x: origin.x, y: flippedY, width: sz.width, height: sz.height)
  }

  /// Breadth-first search for a descendant of `root` that exposes any of
  /// the press-style AX actions, returning the descendant plus the CGEvent
  /// click point (Y-down screen coords) at its centre. Used at click time
  /// when the detected hint element is an inert wrapper whose actual
  /// handler lives one or two levels deeper — a common pattern on
  /// Firefox tab strips and React `role="tab"`/`role="button"` widgets.
  ///
  /// Bounded by `maxDepth` and `maxNodes` so a single click never blows
  /// up the AX IPC budget on a pathological subtree. The traversal is
  /// only invoked when the root's own AX actions have all failed, so the
  /// extra cost is paid at most once per Flash activation.
  static func firstActionableDescendant(
    _ root: AXUIElement,
    screenH: CGFloat,
    maxDepth: Int = 6,
    maxNodes: Int = 200
  ) -> (AXUIElement, CGPoint)? {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var visited = 0
    while !queue.isEmpty {
      let (el, depth) = queue.removeFirst()
      visited += 1
      if visited > maxNodes { return nil }
      if depth > 0,
        elementHasPressAction(el),
        let frame = frameForElement(el, screenH: screenH)
      {
        let cg = CGPoint(x: frame.midX, y: screenH - frame.midY)
        return (el, cg)
      }
      if depth >= maxDepth { continue }
      var raw: CFTypeRef?
      if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &raw) == .success,
        let children = raw as? [AXUIElement]
      {
        for child in children { queue.append((child, depth + 1)) }
      }
    }
    return nil
  }

  private static func elementHasPressAction(_ element: AXUIElement) -> Bool {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
      let arr = names as? [String]
    else { return false }
    return arr.contains(kAXPressAction)
      || arr.contains("AXOpen")
      || arr.contains("AXConfirm")
  }

  private static func frameForElement(_ element: AXUIElement, screenH: CGFloat) -> CGRect? {
    var posRaw: CFTypeRef?
    var sizeRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRaw) == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRaw) == .success,
      let posCF = posRaw, let sizeCF = sizeRaw,
      CFGetTypeID(posCF) == AXValueGetTypeID(),
      CFGetTypeID(sizeCF) == AXValueGetTypeID()
    else { return nil }
    let posVal = posCF as! AXValue
    let sizeVal = sizeCF as! AXValue
    guard AXValueGetType(posVal) == .cgPoint, AXValueGetType(sizeVal) == .cgSize else { return nil }
    var origin = CGPoint.zero
    var sz = CGSize.zero
    AXValueGetValue(posVal, .cgPoint, &origin)
    AXValueGetValue(sizeVal, .cgSize, &sz)
    if sz.width <= 0 || sz.height <= 0 { return nil }
    let flippedY = screenH - origin.y - sz.height
    return CGRect(x: origin.x, y: flippedY, width: sz.width, height: sz.height)
  }

  /// Post a real `leftMouseDown`+`leftMouseUp` (or right-button equivalent)
  /// pair via CGEvent at the given screen point. Used as the fallback when
  /// no AX action takes — i.e. the element exposes `AXLink`/`AXButton`/
  /// `AXTab` but has no `AXPress`/`AXOpen`/`AXConfirm` handler, which is
  /// common for `<div onclick>` widgets and the Firefox tab strip.
  ///
  /// The events post to `.cghidEventTap` so they're delivered to whichever
  /// app owns the window under the point — that's the same path an actual
  /// user click takes. Requires the Accessibility (assistive) permission
  /// Flash already needs to read AX trees; no extra grant.
  static func synthesizeMouseClick(at point: CGPoint, button: CGMouseButton) -> Bool {
    let source = CGEventSource(stateID: .hidSystemState)
    let downType: CGEventType = (button == .right) ? .rightMouseDown : .leftMouseDown
    let upType: CGEventType = (button == .right) ? .rightMouseUp : .leftMouseUp
    guard
      let down = CGEvent(
        mouseEventSource: source, mouseType: downType,
        mouseCursorPosition: point, mouseButton: button),
      let up = CGEvent(
        mouseEventSource: source, mouseType: upType,
        mouseCursorPosition: point, mouseButton: button)
    else { return false }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }

  private func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    let err = AXUIElementCopyActionNames(element, &names)
    guard err == .success, let arr = names as? [String] else { return [] }
    return arr
  }

  /// Standalone `AXImage` gate. We treat an image as a real click target
  /// only when it exposes a press-style action — pure decorative
  /// `<img>` exposes none. Called only when `role == "AXImage"` and
  /// there is no clickable ancestor, so the one extra IPC per check is
  /// bounded by the per-page image count.
  private func imageHasPressAction(_ element: AXUIElement) -> Bool {
    let actions = Set(actionNames(element))
    return actions.contains(kAXPressAction)
      || actions.contains("AXOpen")
      || actions.contains("AXConfirm")
  }

  private func stringAttr(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var raw: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, attribute, &raw)
    guard err == .success else { return nil }
    let s = raw as? String
    guard let s, !s.isEmpty else { return nil }
    return s
  }

  private func writeDumpLine(
    _ handle: FileHandle,
    depth: Int,
    role: String?,
    subrole: String?,
    parentRole: String?,
    posValue: AXValue?,
    sizeValue: AXValue?,
    screenH: CGFloat,
    enabled: Bool,
    actions: [String],
    label: String?,
    hinted: Bool
  ) {
    let frame: CGRect?
    if let p = posValue, let s = sizeValue {
      frame = frameFromAX(pos: p, size: s, screenH: screenH)
    } else {
      frame = nil
    }
    let indent = String(repeating: "  ", count: min(depth, 40))
    let f =
      frame.map { "(\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))x\(Int($0.height)))" } ?? "-"
    let acts = actions.isEmpty ? "-" : actions.joined(separator: ",")
    let lbl = label.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" } ?? "-"
    let line = """
      \(indent)d=\(depth) role=\(role ?? "?") subrole=\(subrole ?? "-") parent=\(parentRole ?? "-") frame=\(f) enabled=\(enabled) actions=\(acts) label=\(lbl)\(hinted ? " hint=1" : "")
      """
    if let data = (line + "\n").data(using: .utf8) {
      handle.write(data)
    }
  }
}
