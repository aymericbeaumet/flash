import AppKit
import ApplicationServices
import FlashCore

/// Single, universal AX walker. No per-app variants — every macOS app is
/// treated by the same rules: clickable controls, text inputs, and rows in
/// virtualised lists.
///
/// The role/skip/depth/target sets are intentionally *not* exposed for
/// per-app override. The project's working assumption is that generic rules
/// are good enough; if a specific app misbehaves we tune the universal set,
/// not the per-app fork. See AGENTS.md ("Project layout") for the rationale.
///
/// Performance contract:
///   - Exactly one batched IPC per visited element via
///     `AXUIElementCopyMultipleAttributeValues`.
///   - Walks the full `kAXChildrenAttribute` tree. We deliberately do not
///     prefer `kAXVisibleChildrenAttribute` / `kAXVisibleRows`: virtualised-
///     list optimisations hide scrolled-off rows from the dump, which made
///     it impossible to tell whether a missing element was absent from the
///     AX tree or just being filtered. Geometric and visibility filtering
///     happens later in `AppMonitor.collectFocusedTargets`.
///   - No mid-walk deadline truncation: walks always complete (so the set of
///     returned targets is deterministic).
///   - No per-IPC timeout. macOS default (6 s) is in place. Any tighter
///     cap silently dropped Firefox's `AXWebArea` subtree (lazy build).
///   - Top-level subtrees always fan out across concurrent workers via
///     `DispatchQueue.concurrentPerform`, pipelining many AX IPCs
///     against the target app's main thread. The single-attribute
///     children fallback recovers Firefox's batched-IPC drops.
///   - Action-name IPCs needed to confirm tentative targets (web-area
///     roleless-with-AXPress, standalone AXImage) are buffered as
///     `pendingTargets` during the walk and resolved in parallel after
///     it completes, so the IPC pipeline isn't serialised on inline
///     follow-up reads.
public final class AccessibilityProvider: JumpProvider {
  public let identifier: String = "accessibility"
  public let displayName: String = "accessibility"
  public let priority: Int = 10
  public let readinessPolicy: JumpProviderReadinessPolicy = .continuous
  public let capabilities: FlashSourceCapabilities = [.jumpTargets, .documentURL, .tabSelection]

  /// Roles we recognise in native (non-web) AX trees. Broader than the
  /// web allowlist because native apps surface things the web doesn't —
  /// virtualised list rows, disclosure triangles, icon-only AXImage
  /// buttons.
  public static let roles: Set<String> = [
    // Click targets
    "AXButton", "AXLink",
    "AXMenuItem", "AXMenuButton",
    "AXPopUpButton",
    "AXCheckBox", "AXRadioButton",
    "AXTab",
    "AXDisclosureTriangle",
    // Text inputs
    "AXTextField", "AXSearchField", "AXTextArea", "AXComboBox",
    // Virtualised list rows (each row is one click target)
    "AXRow", "AXCell",
    // Icon-only buttons sometimes report as AXImage. Gated below by
    // ancestor-role + AXPress to avoid double-hinting decorative
    // images inside links/buttons.
    "AXImage",
  ]

  /// Roles we accept inside an `AXWebArea`. Vimium-style allowlist:
  /// only true semantic controls. Notably excludes:
  ///   - `AXImage` — web AXImages are nearly always decorative; Vimium
  ///     only hints `<img cursor:zoom-*>` and we can't see CSS via AX.
  ///   - `AXRow` / `AXCell` — web tables aren't click targets the way
  ///     virtualised native lists are.
  ///   - Any AXPress-on-AXGroup fallback. AX surfaces `AXPress` on
  ///     countless structural wrappers; accepting them displaces the
  ///     real link/button via the smaller-frame-wins dedup.
  public static let webClickableRoles: Set<String> = [
    "AXLink", "AXButton",
    "AXCheckBox", "AXRadioButton",
    "AXTextField", "AXSearchField", "AXTextArea", "AXComboBox",
    "AXPopUpButton",
    "AXTab",
    "AXMenuItem",
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

  /// Roles for which "click" really means "focus the input". AXPress on a
  /// search field is a no-op and a synthesized mouse click on top of an
  /// already-keyed app may land in the wrong subview; setting
  /// `kAXFocusedAttribute = true` is the unambiguous AX-level way.
  static let textInputRoles: Set<String> = [
    "AXTextField", "AXSearchField", "AXTextArea", "AXComboBox",
  ]

  /// Runaway guards rather than real limits. Real AX trees rarely exceed
  /// ~30 levels of depth or a few thousand elements, but the previous
  /// caps (80 / 1500) hid genuine tree content from the dump on
  /// virtualised lists with many rows. If a walk hits either cap there
  /// is almost certainly a cycle in the AX tree.
  public static let maxDepth: Int = 500
  public static let maxTargets: Int = 100_000
  /// How many separate `concurrentPerform` fan-outs a single walk path
  /// is allowed. Each fan-out point pays a small dispatch-queue cost
  /// but unblocks N AX IPCs in parallel. Two levels covers the typical
  /// "menu bar + content window + ... + big content group" shape: the
  /// first fan-out splits across the window's direct children; each
  /// of those workers can then fan out one more time inside its
  /// subtree (e.g. inside an AXWebArea or a large AXGroup). Beyond
  /// two levels the dispatch overhead dominates the IPC win.
  public static let maxFanoutLevels: Int = 2

  public init() {}

  public func supports(_ context: AppContext) -> Bool { true }

  public func tabSelect(
    at index: Int,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    guard index > 0 else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    let app = AXUIElementCreateApplication(context.processID)
    guard let focusedWindow = Self.elementAttribute(app, kAXFocusedWindowAttribute as String) else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    let tabs = Self.tabElements(in: focusedWindow)
    guard index <= tabs.count else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    if let runningApp = NSRunningApplication(processIdentifier: context.processID) {
      runningApp.activate(options: [.activateAllWindows])
    }
    let tab = tabs[index - 1]
    let pressed = AXUIElementPerformAction(tab, kAXPressAction as CFString) == .success
    let selected =
      pressed
      || AXUIElementSetAttributeValue(tab, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        == .success
    DispatchQueue.main.async {
      completion(selected ? .performed(pid: context.processID) : .unhandled)
    }
  }

  public func documentURL(in context: AppContext) -> String? {
    let app = AXUIElementCreateApplication(context.processID)
    var focusedRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRaw)
      == .success,
      let element = focusedRaw,
      CFGetTypeID(element) == AXUIElementGetTypeID()
    {
      let focusedElement = element as! AXUIElement
      if let url = Self.documentURLNear(focusedElement) {
        return url
      }
    }

    var windowRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRaw)
        == .success,
      let window = windowRaw,
      CFGetTypeID(window) == AXUIElementGetTypeID()
    else { return nil }
    let focusedWindow = window as! AXUIElement
    if let url = Self.urlAttribute(focusedWindow, kAXDocumentAttribute as String)
      ?? Self.urlAttribute(focusedWindow, kAXURLAttribute as String)
    {
      return url
    }
    return Self.firstDocumentURL(in: focusedWindow, maxNodes: 2_000)
  }

  private static let documentRoles: Set<String> = ["AXWebArea", "AXDocument"]

  private static func documentURLNear(_ element: AXUIElement) -> String? {
    var current = element
    for _ in 0..<10 {
      if role(of: current).map({ documentRoles.contains($0) }) == true {
        if let url = urlAttribute(current, kAXURLAttribute as String)
          ?? urlAttribute(current, kAXDocumentAttribute as String)
        {
          return url
        }
      }
      guard let parent = elementAttribute(current, kAXParentAttribute as String) else {
        return nil
      }
      current = parent
    }
    return nil
  }

  private static func firstDocumentURL(in root: AXUIElement, maxNodes: Int) -> String? {
    var queue = [root]
    var index = 0
    while index < queue.count, index < maxNodes {
      let element = queue[index]
      index += 1
      if role(of: element).map({ documentRoles.contains($0) }) == true {
        if let url = urlAttribute(element, kAXURLAttribute as String)
          ?? urlAttribute(element, kAXDocumentAttribute as String)
        {
          return url
        }
      }
      queue.append(contentsOf: children(of: element))
    }
    return nil
  }

  private static func role(of element: AXUIElement) -> String? {
    stringAttribute(element, kAXRoleAttribute as String)
  }

  private static func children(of element: AXUIElement) -> [AXUIElement] {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
      == .success,
      let children = raw as? [AXUIElement]
    else { return [] }
    return children
  }

  private static func tabElements(in root: AXUIElement) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var seen = Set<UInt>()
    var queue = [root]
    var index = 0
    while index < queue.count, index < 3_000 {
      let element = queue[index]
      index += 1
      let role = role(of: element)
      let subrole = stringAttribute(element, kAXSubroleAttribute as String)
      if role == "AXTab" || subrole == "AXTabButton" {
        if seen.insert(CFHash(element)).inserted {
          out.append(element)
        }
      }
      queue.append(contentsOf: children(of: element))
    }
    return out
  }

  private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
  }

  private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw
    else { return nil }
    return value as? String
  }

  private static func urlAttribute(_ element: AXUIElement, _ name: String) -> String? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
      let value = raw
    else { return nil }
    if let url = value as? URL { return url.absoluteString }
    if CFGetTypeID(value) == CFURLGetTypeID() {
      return (value as! URL).absoluteString
    }
    return value as? String
  }

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

  private static func stringValue(_ v: Any) -> String? {
    guard let value = v as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func urlValue(_ v: Any) -> String? {
    if let url = v as? URL {
      return url.absoluteString
    }
    let cf = v as CFTypeRef
    if CFGetTypeID(cf) == CFURLGetTypeID() {
      return (cf as! URL).absoluteString
    }
    return stringValue(v)
  }

  // The attribute array we pass to AXUIElementCopyMultipleAttributeValues.
  // Indices are hot-path constants — keep them in sync with `walk`.
  private static let batchAttrs: CFArray =
    [
      kAXRoleAttribute,  // 0
      kAXPositionAttribute,  // 1
      kAXSizeAttribute,  // 2
      kAXEnabledAttribute,  // 3
      kAXChildrenAttribute,  // 4
      kAXTitleAttribute,  // 5
      kAXDescriptionAttribute,  // 6
      kAXValueAttribute,  // 7
      kAXURLAttribute,  // 8
      kAXHiddenAttribute,  // 9
    ] as CFArray

  /// Per-worker mutable state. `WalkState` is per-thread under concurrent
  /// walks; serial walks pass one through the whole recursion.
  private struct WalkState {
    var confirmedTargets: [JumpTarget] = []
    /// Targets whose acceptance is contingent on an action-name IPC.
    /// Collected during the walk; resolved in parallel after the
    /// walk completes (see `resolvePendingActionChecks`).
    var pendingTargets: [PendingTarget] = []
    var idCounter: Int = 0
  }

  /// Tentative target awaiting an action-name IPC. The candidate is fully
  /// formed — if the action check passes, it's appended to
  /// `confirmedTargets` as-is; otherwise dropped.
  private struct PendingTarget {
    let candidate: JumpTarget
    let element: AXUIElement
  }

  /// Lock-protected collector for merging per-worker `WalkState`s back
  /// onto the activation's combined result. Allocated once per
  /// concurrent fan-out.
  private final class WalkCollector {
    let lock = NSLock()
    var confirmedTargets: [JumpTarget] = []
    var pendingTargets: [PendingTarget] = []

    func absorb(_ state: WalkState) {
      lock.lock()
      confirmedTargets.append(contentsOf: state.confirmedTargets)
      pendingTargets.append(contentsOf: state.pendingTargets)
      lock.unlock()
    }
  }

  public func discover(in context: AppContext) throws -> [JumpTarget] {
    let app = AXUIElementCreateApplication(context.processID)
    // Wake the target app's a11y engine. Some apps (notably Firefox)
    // run a lazy/idle accessibility service that only exposes the
    // window-decoration buttons until an assistive technology
    // explicitly signals it's reading the tree. The undocumented but
    // widely-used `AXEnhancedUserInterface` and `AXManualAccessibility`
    // attributes are the standard signals — VoiceOver sets the same
    // ones. Best-effort: errors are ignored because most apps don't
    // recognise these attributes and that's fine.
    let trueRef = kCFBooleanTrue as CFTypeRef
    _ = AXUIElementSetAttributeValue(
      app, "AXEnhancedUserInterface" as CFString, trueRef)
    _ = AXUIElementSetAttributeValue(
      app, "AXManualAccessibility" as CFString, trueRef)
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

    // Active-window only. One IPC up front to resolve
    // kAXFocusedWindowAttribute and walk that subtree exclusively. This
    // is the *correct* way to scope to a single window — relying on a
    // geometric region filter alone leaves edge cases where AX-reported
    // frames from sibling windows or the app's AXMenuBar happen to
    // land inside the active window's bounds (full-screen apps, off-
    // screen popovers, AX coordinate quirks) and bleed through as
    // stray hints.
    //
    // If `kAXFocusedWindow` is missing (rare — happens momentarily
    // during app launches and in some automated Firefox sessions), fall
    // back to the first reported app window. This keeps the walk scoped
    // to one foreground-app window without broadening to app/menu-bar
    // children.
    guard let focusedWindow = Self.focusedOrFirstWindow(in: app) else { return [] }

    var state = WalkState()
    // The root walk uses the "r" prefix; concurrent fan-out workers use
    // "w<i>" (see depth-0 fan-out below). This keeps target IDs unique
    // across the focused window's own target (if it's hinted) and the
    // per-worker subtree results.
    walk(
      focusedWindow,
      depth: 0,
      screenH: screenH,
      visible: clip,
      pid: context.processID,
      insideClickable: false,
      insideWebArea: false,
      parentRole: nil,
      idPrefix: "r",
      fanoutBudget: Self.maxFanoutLevels,
      state: &state
    )

    // Parallel resolution of pending action-name checks. These are
    // tentative targets the walker buffered instead of paying an inline
    // IPC per element (the inline pattern doubled the IPC count on
    // web-heavy apps because every AXGroup-in-webarea and every
    // standalone AXImage triggered an extra `AXUIElementCopyActionNames`
    // round-trip). Resolving in parallel lets the target app's main
    // thread service multiple action-name reads concurrently.
    let survivors = resolvePendingActionChecks(state.pendingTargets)
    state.confirmedTargets.append(contentsOf: survivors)
    return state.confirmedTargets
  }

  private static func focusedOrFirstWindow(in app: AXUIElement) -> AXUIElement? {
    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
      if let window = elementAttribute(app, attribute as String),
        role(of: window) == "AXWindow"
      {
        return window
      }
    }
    var windowsRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRaw)
      == .success,
      let windows = windowsRaw as? [AXUIElement]
    {
      return windows.first { role(of: $0) == "AXWindow" }
    }
    return nil
  }

  private func walk(
    _ element: AXUIElement,
    depth: Int,
    screenH: CGFloat,
    visible: CGRect,
    pid: pid_t,
    insideClickable: Bool,
    insideWebArea: Bool,
    parentRole: String?,
    idPrefix: String,
    fanoutBudget: Int,
    state: inout WalkState
  ) {
    if depth > Self.maxDepth { return }
    if state.confirmedTargets.count >= Self.maxTargets { return }

    var valuesRef: CFArray?
    let err = AXUIElementCopyMultipleAttributeValues(
      element,
      Self.batchAttrs,
      AXCopyMultipleAttributeOptions(rawValue: 0),
      &valuesRef
    )
    guard err == .success, let vals = valuesRef as? [Any], vals.count == 10 else { return }

    let role = vals[0] as? String
    let posValue = Self.axValue(vals[1])
    let sizeValue = Self.axValue(vals[2])
    let enabled = (vals[3] as? Bool) ?? true
    let allChildren = vals[4] as? [AXUIElement]
    let label =
      Self.stringValue(vals[5]) ?? Self.stringValue(vals[6]) ?? Self.stringValue(vals[7])
    let url = Self.urlValue(vals[8])
    let hidden = (vals[9] as? Bool) ?? false

    // Role allowlist: web pages use the narrower Vimium-equivalent set
    // (true semantic controls only); native apps use the broader set
    // (rows, cells, disclosure triangles, icon-only AXImage buttons).
    // Disabled elements never hint — they're visible but inert, and
    // the user would just click into a no-op.
    let allowlist = insideWebArea ? Self.webClickableRoles : Self.roles
    var roleAllowed = role.map { allowlist.contains($0) } ?? false
    if roleAllowed, role == "AXImage", insideClickable {
      roleAllowed = false
    }
    // Vimium-parity heuristic for AXLink-only: drop anchors smaller
    // than 13x13. These are virtually always wrappers around a
    // decorative CSS sprite or a hidden hit-region — HN-style upvote
    // arrows, "..." pagination dots, etc. Firefox AX often propagates
    // the child element's `title` attribute to the link, so an
    // accessible-name check doesn't discriminate. Vimium skips them
    // because the visible content (computed style) renders as
    // invisible or non-pointer; we can't see CSS but the size is a
    // reliable proxy (real icon links are 16x16+, real text links
    // are taller than 13px).
    if roleAllowed, insideWebArea, role == "AXLink",
      let posV = posValue, let sizeV = sizeValue,
      let frame = frameFromAX(pos: posV, size: sizeV, screenH: screenH),
      frame.width < 13, frame.height < 13
    {
      roleAllowed = false
    }
    if let posV = posValue, let sizeV = sizeValue,
      let frame = frameFromAX(pos: posV, size: sizeV, screenH: screenH),
      visible.contains(CGPoint(x: frame.midX, y: frame.midY)),
      roleAllowed, enabled, !hidden
    {
      state.idCounter += 1
      let captured = element
      let capturedRole = role ?? "AXUnknown"
      let activate: ((JumpAction) -> Bool) = { action in
        switch action {
        case .leftClick:
          if Self.textInputRoles.contains(capturedRole),
            AXClick.setFocus(captured)
          {
            return true
          }
          return AXClick.tryActions(captured, action: .leftClick)
        case .rightClick:
          return AXClick.tryActions(captured, action: .rightClick)
        case .doubleClick:
          return false
        }
      }
      let candidate = JumpTarget(
        id: "ax-\(pid)-\(idPrefix)-\(state.idCounter)",
        frame: frame,
        role: capturedRole,
        accessibilityLabel: label,
        url: url,
        pid: pid,
        activate: activate,
        providerID: identifier
      )
      if role == "AXImage" {
        state.pendingTargets.append(PendingTarget(candidate: candidate, element: captured))
      } else {
        state.confirmedTargets.append(candidate)
      }
    }

    // Always walk `kAXChildrenAttribute`. We deliberately do NOT prefer
    // `kAXVisibleChildren` / `kAXVisibleRows` even though that would skip
    // scrolled-off rows in NSTableView / NSOutlineView / NSCollectionView:
    // visible filtering is geometric and happens after discovery, so
    // traversal must still see elements that AX marks non-visible but
    // positions inside the focused window.
    //
    // **Single-attribute children fallback**: the batched IPC can
    // occasionally drop `kAXChildrenAttribute` (returns an error
    // placeholder in vals[5] instead of the real child list — Firefox's
    // a11y does this for `AXTabPanel` under concurrent IPC contention).
    // Re-query that one attribute on its own when the batch came back
    // empty.
    var children: [AXUIElement] = allChildren ?? []
    if children.isEmpty {
      var raw: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        == .success,
        let arr = raw as? [AXUIElement]
      {
        children = arr
      }
    }
    let nowInsideClickable =
      insideClickable || (role.map { Self.clickableContainerRoles.contains($0) } ?? false)
    let nowInsideWebArea = insideWebArea || role == "AXWebArea"

    // Concurrent fan-out fires at the first multi-child node on each
    // walk path, up to `maxFanoutLevels` times per path. The original
    // version fanned out only at depth 0 (the focused window's direct
    // children), which left big subtrees serial — Firefox's content
    // AXGroup, AWS Console's web area. Allowing one more fan-out level
    // inside each depth-0 worker pipelines the IPC against the target
    // app's main thread for those big subtrees too.
    //
    // The bottleneck is still the target app's main thread, so each
    // fan-out level pays for itself only if the children would each
    // generate a meaningful IPC stream. Two levels covers the typical
    // case; deeper than that the dispatch overhead dominates. Single-
    // child case falls through to the serial loop below.
    if fanoutBudget > 0, children.count > 1 {
      let collector = WalkCollector()
      let captureScreenH = screenH
      let captureVisible = visible
      let capturePid = pid
      let captureInsideClickable = nowInsideClickable
      let captureInsideWebArea = nowInsideWebArea
      let captureParentRole = role
      let captureDepth = depth
      let captureIdPrefix = idPrefix
      let captureNewBudget = fanoutBudget - 1
      let childrenSnapshot = children
      DispatchQueue.concurrentPerform(iterations: childrenSnapshot.count) { i in
        var workerState = WalkState()
        // Encode the fan-out level into the id prefix so ids stay
        // unique across nested fan-out points. Outer fan-out emits
        // "w0", "w1", ..., inner fan-out emits "<outerPrefix>w0", etc.
        let childPrefix = captureIdPrefix == "r" ? "w\(i)" : "\(captureIdPrefix)w\(i)"
        self.walk(
          childrenSnapshot[i],
          depth: captureDepth + 1,
          screenH: captureScreenH,
          visible: captureVisible,
          pid: capturePid,
          insideClickable: captureInsideClickable,
          insideWebArea: captureInsideWebArea,
          parentRole: captureParentRole,
          idPrefix: childPrefix,
          fanoutBudget: captureNewBudget,
          state: &workerState
        )
        collector.absorb(workerState)
      }
      collector.lock.lock()
      state.confirmedTargets.append(contentsOf: collector.confirmedTargets)
      state.pendingTargets.append(contentsOf: collector.pendingTargets)
      collector.lock.unlock()
      return
    }

    for child in children {
      walk(
        child,
        depth: depth + 1,
        screenH: screenH,
        visible: visible,
        pid: pid,
        insideClickable: nowInsideClickable,
        insideWebArea: nowInsideWebArea,
        parentRole: role,
        idPrefix: idPrefix,
        fanoutBudget: fanoutBudget,
        state: &state
      )
      if state.confirmedTargets.count >= Self.maxTargets { return }
    }
  }

  /// Parallel resolution of action-name IPCs for tentative targets that
  /// the walker bookkept during the recursive descent. Each
  /// `AXUIElementCopyActionNames` is independent so they can run
  /// concurrently, bounded by the target app's main-thread service rate
  /// (and `DispatchQueue.concurrentPerform`'s thread pool sizing).
  ///
  /// The walk previously paid this IPC inline per element — for AWS
  /// Console (every page-tree AXGroup exposes `AXPress`) that doubled
  /// the IPC count. Deferring and parallelising trims ~30–40 % off the
  /// web-heavy-app walk wall time.
  private func resolvePendingActionChecks(_ pending: [PendingTarget]) -> [JumpTarget] {
    if pending.isEmpty { return [] }
    // Per-iteration write into a UInt8 buffer is byte-aligned and the
    // indices are disjoint, so this is safe without locking.
    // (Concurrent reads of `pending` are also safe — it's a value
    // type, never mutated during the parallel pass.)
    var keep = [UInt8](repeating: 0, count: pending.count)
    keep.withUnsafeMutableBufferPointer { buf in
      DispatchQueue.concurrentPerform(iterations: pending.count) { i in
        buf[i] = AXClick.hasPressAction(pending[i].element) ? 1 : 0
      }
    }
    var out: [JumpTarget] = []
    out.reserveCapacity(pending.count)
    for (i, k) in keep.enumerated() where k == 1 {
      out.append(pending[i].candidate)
    }
    return out
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
    // Minimum visual area gate. 1x1 anchors are a common tracking-
    // pixel idiom that Vimium correctly skips (Utils.areClientRectsTooSmall);
    // 3x3 is the conservative threshold that drops them without
    // touching real icon-only buttons (16x16+).
    if sz.width < 3 || sz.height < 3 { return nil }
    let flippedY = screenH - origin.y - sz.height
    return CGRect(x: origin.x, y: flippedY, width: sz.width, height: sz.height)
  }
}
