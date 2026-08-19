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
///   - Walks the full `kAXChildrenAttribute` tree, then supplements native
///     table/outline containers with `kAXVisibleRowsAttribute` when available.
///     This keeps the complete tree path deterministic while still catching
///     virtualised native lists that expose rows only through the visible-row
///     attribute.
///   - No mid-walk deadline truncation: walks always complete (so the set of
///     returned targets is deterministic).
///   - Per-IPC messaging timeout is bounded, not the 6 s system default:
///     the walk root is built via `AXApp.make` (guardrail-enforced), which
///     applies `AXApp.defaultMessagingTimeout` (1.5 s) to the app element
///     and every element reached through it, so a wedged app can't beachball
///     the main run loop for the full 6 s. The single-attribute children
///     fallback (below) recovers the batched-IPC drops this cap can cause on
///     Firefox's lazily-built `AXWebArea` subtree.
///   - Top-level subtrees always fan out across concurrent workers via
///     `DispatchQueue.concurrentPerform`, pipelining many AX IPCs
///     against the target app's main thread. The single-attribute
///     children fallback recovers Firefox's batched-IPC drops.
///   - Action-name IPCs needed to confirm tentative targets (web-area
///     roleless-with-AXPress, standalone AXImage) are buffered as
///     `pendingTargets` during the walk and resolved in parallel after
///     it completes, so the IPC pipeline isn't serialised on inline
///     follow-up reads.
public final class AccessibilityProvider: FlashSource {
  public let identifier: String = "accessibility"
  public let displayName: String = "accessibility"
  public let priority: Int = 10
  public let readinessPolicy: FlashSourceReadinessPolicy = .continuous
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
    "AXSlider", "AXIncrementor", "AXHandle",
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

  /// Extra web roles accepted only inside browser-extension documents, and
  /// only after an `AXPress` action check. Password-manager popups expose
  /// vault rows/options this way; ordinary web pages still use the stricter
  /// Vimium-style semantic allowlist above.
  public static let webExtensionPopupPressRoles: Set<String> = [
    "AXGroup",
    "AXList",
    "AXListItem",
    "AXOption",
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

  /// Firefox uses a scoped role-read wake below. Leaving
  /// `AXEnhancedUserInterface` enabled outside that scope makes Accessibility
  /// window moves animate slowly and often land incorrectly.
  public static func shouldExplicitlyWakeAccessibility(bundleIdentifier: String) -> Bool {
    !bundleIdentifier.hasPrefix("com.apple.")
      && !FirefoxAccessibility.matches(bundleIdentifier: bundleIdentifier)
  }

  public func supports(_ context: AppContext) -> Bool { true }

  public func performAction(
    _ action: SourceAction,
    in context: AppContext,
    environment: FlashSourceEnvironment,
    completion: @escaping (SourceActionResult) -> Void
  ) {
    // Generic AX walker only handles `tab_select` today: it walks the focused
    // window for tablist children and presses the Nth tab. Everything else
    // falls through so the next source (or the host keystroke fallback)
    // can run.
    guard case .tabSelect(let index) = action else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    guard index > 0 else {
      DispatchQueue.main.async { completion(.unhandled) }
      return
    }
    let app = AXApp.make(pid: context.processID)
    let selected = FirefoxAccessibility.withTree(
      pid: context.processID,
      bundleIdentifier: context.bundleIdentifier,
      app: app
    ) { app in
      guard let focusedWindow = Self.elementAttribute(app, kAXFocusedWindowAttribute as String)
      else { return false }
      let tabs = Self.tabElements(in: focusedWindow)
      guard index <= tabs.count else { return false }
      if let runningApp = NSRunningApplication(processIdentifier: context.processID) {
        RunningApplicationActivation.activate(runningApp, options: [.activateAllWindows])
      }
      let tab = tabs[index - 1]
      let pressed = AXUIElementPerformAction(tab, kAXPressAction as CFString) == .success
      return pressed
        || AXUIElementSetAttributeValue(tab, kAXSelectedAttribute as CFString, kCFBooleanTrue)
          == .success
    }
    DispatchQueue.main.async {
      completion(selected ? .performed(pid: context.processID) : .unhandled)
    }
  }

  public func documentURL(in context: AppContext) -> String? {
    let app = AXApp.make(pid: context.processID)
    return FirefoxAccessibility.withTree(
      pid: context.processID,
      bundleIdentifier: context.bundleIdentifier,
      app: app
    ) { app in
      Self.documentURL(in: app)
    }
  }

  private static func documentURL(in app: AXUIElement) -> String? {
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
    AXAttribute.role(element)
  }

  private static func children(of element: AXUIElement) -> [AXUIElement] {
    AXAttribute.children(element)
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
    AXAttribute.element(element, name)
  }

  private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    AXAttribute.string(element, name)
  }

  private static func urlAttribute(_ element: AXUIElement, _ name: String) -> String? {
    AXAttribute.url(element, name)
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
      kAXSubroleAttribute,  // 10 — Firefox/Chrome tabs report role
      //      `AXRadioButton`/`AXButton` with
      //      subrole `AXTabButton`; surfacing the
      //      subrole lets the walk paint those as
      //      high-priority (tab-strip anchors) in
      //      one IPC round-trip.
      kAXDocumentAttribute,  // 11
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

  public func discover(in context: AppContext) throws -> [JumpTarget] {
    let app = AXApp.make(pid: context.processID)
    return try FirefoxAccessibility.withTree(
      pid: context.processID,
      bundleIdentifier: context.bundleIdentifier,
      app: app
    ) { app in
      try discover(in: context, app: app)
    }
  }

  private func discover(in context: AppContext, app: AXUIElement) throws -> [JumpTarget] {
    // Wake the target app's a11y engine. Chromium/Electron apps run a lazy/idle
    // accessibility service that only exposes the window-decoration buttons
    // until an assistive technology
    // explicitly signals it's reading the tree. The undocumented but
    // widely-used `AXEnhancedUserInterface` and `AXManualAccessibility`
    // attributes are the standard signals — VoiceOver sets the same
    // ones. Best-effort: errors are ignored because most apps don't
    // recognise these attributes and that's fine.
    //
    // Skipped for Apple's own apps and Firefox. The flag is process-sticky for
    // these apps and tells them an assistive client is permanently watching.
    // SwiftUI-heavy apps like Notes respond with eager accessibility
    // bookkeeping; Firefox is instead activated and restored by the scoped
    // `FirefoxAccessibility.withTree` call above.
    if Self.shouldExplicitlyWakeAccessibility(bundleIdentifier: context.bundleIdentifier) {
      let trueRef = kCFBooleanTrue as CFTypeRef
      _ = AXUIElementSetAttributeValue(
        app, "AXEnhancedUserInterface" as CFString, trueRef)
      _ = AXUIElementSetAttributeValue(
        app, "AXManualAccessibility" as CFString, trueRef)
    }
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

    // Active-surface only. One IPC up front to resolve
    // kAXFocusedWindowAttribute and walk that subtree exclusively. This
    // is the *correct* way to scope to a single window — relying on a
    // geometric region filter alone leaves edge cases where AX-reported
    // frames from sibling windows or the app's AXMenuBar happen to
    // land inside the active window's bounds (full-screen apps, off-
    // screen popovers, AX coordinate quirks) and bleed through as
    // stray hints.
    //
    // If `kAXFocusedWindow` is missing (rare — happens momentarily during
    // app launches and in some automated Firefox sessions), fall back to the
    // first reported app surface. This keeps the walk scoped to one
    // foreground-app surface without broadening to app/menu-bar children.
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
      bundleIdentifier: context.bundleIdentifier,
      insideClickable: false,
      insideWebArea: false,
      insideExtensionDocument: false,
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
        isTopLevelInteractionSurface(window)
      {
        return window
      }
    }
    var windowsRaw: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRaw)
      == .success,
      let windows = windowsRaw as? [AXUIElement]
    {
      return windows.first { isTopLevelInteractionSurface($0) }
    }
    return nil
  }

  private static func isTopLevelInteractionSurface(_ element: AXUIElement) -> Bool {
    if let role = role(of: element), topLevelInteractionSurfaceRoles.contains(role) {
      return true
    }
    guard let subrole = stringAttribute(element, kAXSubroleAttribute as String) else {
      return false
    }
    return topLevelInteractionSurfaceSubroles.contains(subrole)
  }

  private static let topLevelInteractionSurfaceRoles: Set<String> = [
    "AXWindow",
    "AXPopover",
  ]

  private static let topLevelInteractionSurfaceSubroles: Set<String> = [
    "AXDialog",
    "AXFloatingWindow",
    "AXPopover",
    "AXSheet",
    "AXSystemDialog",
  ]

  private func walk(
    _ element: AXUIElement,
    depth: Int,
    screenH: CGFloat,
    visible: CGRect,
    pid: pid_t,
    bundleIdentifier: String,
    insideClickable: Bool,
    insideWebArea: Bool,
    insideExtensionDocument: Bool,
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
    guard err == .success, let vals = valuesRef as? [Any], vals.count == 12 else { return }

    let role = vals[0] as? String
    let posValue = Self.axValue(vals[1])
    let sizeValue = Self.axValue(vals[2])
    let enabled = (vals[3] as? Bool) ?? true
    let allChildren = vals[4] as? [AXUIElement]
    let label =
      Self.stringValue(vals[5]) ?? Self.stringValue(vals[6]) ?? Self.stringValue(vals[7])
    let url = Self.urlValue(vals[8]) ?? Self.urlValue(vals[11])
    let hidden = (vals[9] as? Bool) ?? false
    let subrole = vals[10] as? String
    let currentOrAncestorInsideExtensionDocument =
      insideExtensionDocument || Self.isExtensionDocumentURL(url)

    // Role allowlist: web pages use the narrower Vimium-equivalent set
    // (true semantic controls only); native apps use the broader set
    // (rows, cells, disclosure triangles, icon-only AXImage buttons).
    // Disabled elements never hint — they're visible but inert, and
    // the user would just click into a no-op.
    //
    // Electron apps (Slack, Discord, etc.) render their entire UI inside
    // an `AXWebArea`, so the strict web allowlist would skip their
    // list/row chrome. Admit `AXRow`/`AXCell` here too — the
    // `isRowOrCell` branch below routes them through the deferred
    // `AXPress` check, so decorative HTML table cells (no press action)
    // are filtered out while genuine click targets like Slack channels
    // come through.
    let isRowOrCellRole = role == "AXRow" || role == "AXCell"
    let isExtensionPopupPressRole =
      insideWebArea
      && currentOrAncestorInsideExtensionDocument
      && (role.map { Self.webExtensionPopupPressRoles.contains($0) } ?? false)
    let baseAllowlist = insideWebArea ? Self.webClickableRoles : Self.roles
    var roleAllowed =
      role.map { baseAllowlist.contains($0) } ?? false
      || (insideWebArea && isRowOrCellRole)
      || isExtensionPopupPressRole
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
    // `enabled` is checked per-branch below rather than in this gate: a
    // disabled row/cell can still be the real click target (see the
    // row/cell branch), whereas every other disabled element stays inert.
    if let posV = posValue, let sizeV = sizeValue,
      let frame = frameFromAX(pos: posV, size: sizeV, screenH: screenH),
      visible.containsInclusive(CGPoint(x: frame.midX, y: frame.midY)),
      roleAllowed, !hidden
    {
      state.idCounter += 1
      let captured = element
      let capturedRole = role ?? "AXUnknown"
      // Browser tab strips report their entries either as native `AXTab` or as
      // `AXRadioButton` / `AXButton` with subrole `AXTabButton` (Firefox +
      // Chromium). Raising their priority signals the renderer to paint them in
      // the accent style so the user can pick out tabs from a dense element grid
      // at a glance.
      let isTabAnchor =
        capturedRole == "AXTab"
        || (subrole == "AXTabButton"
          && (capturedRole == "AXRadioButton" || capturedRole == "AXButton"))
      // Multi-line web links report a union bounding box whose centre can fall
      // in the empty gap between wrapped lines, so a synthesized click there
      // misses. Resolve the first character's box centre instead — guaranteed
      // on the element — lazily at commit (no hint-walk cost) and only when the
      // target is clearly multi-line; single-line targets keep the proven
      // frame centre.
      let resolveClickPoint: (() -> CGPoint?)? =
        insideWebArea
        ? {
          FirefoxAccessibility.withTree(
            pid: pid,
            bundleIdentifier: bundleIdentifier
          ) { _ in
            guard
              let charRect = AXAttribute.boundsForRange(
                captured, location: 0, length: 1, screenH: screenH),
              frame.height > charRect.height * 1.5
            else { return nil }
            return CGPoint(x: charRect.midX, y: charRect.midY)
          }
        }
        : nil
      let candidate = JumpTarget(
        id: "ax-\(pid)-\(idPrefix)-\(state.idCounter)",
        frame: frame,
        role: capturedRole,
        accessibilityLabel: label,
        url: url,
        pid: pid,
        resolveClickPoint: resolveClickPoint,
        entersInsertMode: JumpTarget.textInputRoles.contains(capturedRole),
        priority: isTabAnchor ? .urgent : .normal,
        providerID: identifier
      )
      let isRowOrCell = capturedRole == "AXRow" || capturedRole == "AXCell"
      if enabled {
        // Icon-only AXImage buttons defer to the AXPress check (decorative
        // images report no press action); web-area rows do the same so
        // HTML <tr>/<td> stays filtered while Slack/Discord/Electron
        // channel rows (which expose AXPress) come through; everything
        // else is confirmed.
        if role == "AXImage" || (insideWebArea && isRowOrCell) || isExtensionPopupPressRole {
          state.pendingTargets.append(PendingTarget(candidate: candidate, element: captured))
        } else {
          state.confirmedTargets.append(candidate)
        }
      } else if isRowOrCell {
        // Virtualised list rows/cells frequently report enabled=false even
        // when they are the real click target — Messages conversation rows
        // do exactly this, which is why `f` surfaced no hints over the chat
        // list. Admit them only when they actually expose AXPress so we
        // recover the actionable rows without hinting genuinely inert UI.
        state.pendingTargets.append(PendingTarget(candidate: candidate, element: captured))
      }
    }

    // Descent pruning (native only). An element whose frame is valid and lies
    // wholly outside the visible clip cannot contain an on-screen target: a
    // native container lays its children out within its own bounds, and the
    // capture gate above already rejects anything outside `visible` — so
    // skipping the subtree changes no hint output, it only avoids the per-node
    // batch IPC for descendants that would all be discarded anyway.
    //
    // This is what makes Notes (and any long native list) usable: Notes exposes
    // its whole note list — ~300 rows, ~2500 AX nodes — and answers AX ~0.4ms a
    // node, so an unpruned walk pins Notes' AX main thread for 1–2s on every
    // focus change and every keystroke-driven re-walk. That saturation is felt
    // as system-wide input lag because Flash's key tap shares the main runloop.
    // Pruning the scrolled-off rows cuts the walk ~2500 → ~470 nodes.
    //
    // Restricted to `!insideWebArea`: CSS transforms / `overflow: visible` /
    // fixed positioning let a web node render outside its ancestor's reported
    // frame, so geometric containment isn't guaranteed there. Never prune the
    // root (`depth == 0`) or a frameless / zero-size container — its children
    // may carry the real geometry.
    if depth > 0, !insideWebArea,
      let posV = posValue, let sizeV = sizeValue,
      let elementFrame = frameFromAX(pos: posV, size: sizeV, screenH: screenH),
      !elementFrame.isEmpty, !visible.intersects(elementFrame)
    {
      return
    }

    // Always walk `kAXChildrenAttribute`. Native table/outline views sometimes
    // expose their virtualised rows only through `kAXVisibleRowsAttribute`, so
    // add that list as a supplement instead of replacing the child walk.
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
    children = Self.childrenIncludingVisibleRows(
      for: element,
      role: role,
      children: children)
    let nowInsideClickable =
      insideClickable || (role.map { Self.clickableContainerRoles.contains($0) } ?? false)
    let nowInsideWebArea = insideWebArea || role == "AXWebArea"
    let nowInsideExtensionDocument = currentOrAncestorInsideExtensionDocument

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
      let captureScreenH = screenH
      let captureVisible = visible
      let capturePid = pid
      let captureInsideClickable = nowInsideClickable
      let captureInsideWebArea = nowInsideWebArea
      let captureInsideExtensionDocument = nowInsideExtensionDocument
      let captureParentRole = role
      let captureDepth = depth
      let captureIdPrefix = idPrefix
      let captureNewBudget = fanoutBudget - 1
      let childrenSnapshot = children
      // Each worker writes only its own slot: the indices are disjoint so this
      // is lock-free (mirrors `resolvePendingActionChecks`), AND the merge below
      // runs in child order regardless of completion order. That determinism
      // matters — `TargetFinalizer`'s dedup tiebreak keys off this ordering, so
      // the old lock-based append (order = worker scheduling) could flip which
      // of two equal-area overlapping targets survived dedup run-to-run.
      var workerStates = [WalkState](repeating: WalkState(), count: childrenSnapshot.count)
      workerStates.withUnsafeMutableBufferPointer { buf in
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
            bundleIdentifier: bundleIdentifier,
            insideClickable: captureInsideClickable,
            insideWebArea: captureInsideWebArea,
            insideExtensionDocument: captureInsideExtensionDocument,
            parentRole: captureParentRole,
            idPrefix: childPrefix,
            fanoutBudget: captureNewBudget,
            state: &workerState
          )
          buf[i] = workerState
        }
      }
      for workerState in workerStates {
        state.confirmedTargets.append(contentsOf: workerState.confirmedTargets)
        state.pendingTargets.append(contentsOf: workerState.pendingTargets)
      }
      return
    }

    for child in children {
      walk(
        child,
        depth: depth + 1,
        screenH: screenH,
        visible: visible,
        pid: pid,
        bundleIdentifier: bundleIdentifier,
        insideClickable: nowInsideClickable,
        insideWebArea: nowInsideWebArea,
        insideExtensionDocument: nowInsideExtensionDocument,
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

  public static func isExtensionDocumentURL(_ value: String?) -> Bool {
    guard let value,
      let scheme = URL(string: value)?.scheme?.lowercased()
    else { return false }
    return extensionDocumentSchemes.contains(scheme)
  }

  private static let extensionDocumentSchemes: Set<String> = [
    "chrome-extension",
    "moz-extension",
    "safari-web-extension",
  ]

  private static func childrenIncludingVisibleRows(
    for element: AXUIElement,
    role: String?,
    children: [AXUIElement]
  ) -> [AXUIElement] {
    guard role == "AXTable" || role == "AXOutline" else { return children }
    var rawRows: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(element, kAXVisibleRowsAttribute as CFString, &rawRows)
        == .success,
      let rows = rawRows as? [AXUIElement],
      !rows.isEmpty
    else { return children }

    var seen = Set<CFHashCode>()
    var combined: [AXUIElement] = []
    combined.reserveCapacity(children.count + rows.count)
    for child in children + rows {
      guard seen.insert(CFHash(child)).inserted else { continue }
      combined.append(child)
    }
    return combined
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
