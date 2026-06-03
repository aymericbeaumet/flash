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
///   - Exactly one batched IPC per visited element via
///     `AXUIElementCopyMultipleAttributeValues`.
///   - Prefer kAXVisibleChildrenAttribute over kAXChildrenAttribute so
///     scrolled-off content in NSOutlineView / NSTableView / NSCollectionView
///     is never walked. On Notes' 292-row sidebar this turns a ~300-element
///     walk into a ~30-element walk — only the visible rows are touched.
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
  ///
  /// Caveat under `concurrentWalk = true`: per-worker buffers are
  /// concatenated in worker-order at end of walk, so the file is no
  /// longer in strict tree-traversal order. Set
  /// `performance.concurrent_walk = false` if you need the legacy
  /// ordering for diff'ing two activations.
  public var dumpURL: URL?

  /// Millisecond wall-clock timestamp identifying the activation that
  /// produced this walk. Set by AppMonitor from the activation's
  /// profiler before each call to `discover` so dump lines can be
  /// correlated with the show_hints trigger they belong to.
  public var triggerMs: UInt64?

  /// Background queue used to flush AX dump buffers to disk so the
  /// activation hot path never blocks on file I/O. Serial so concurrent
  /// activations' dumps don't interleave on the same file.
  private static let dumpWriteQueue = DispatchQueue(label: "flash.ax-dump.write", qos: .utility)

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

  private func nonEmpty(_ arr: [AXUIElement]?) -> [AXUIElement]? {
    guard let arr, !arr.isEmpty else { return nil }
    return arr
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
      "AXHidden",  // 8 — Firefox/WebKit a11y-hidden subtrees
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
    var dumpBuffer: [String]? = nil
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
    var dump: [String] = []

    func absorb(_ state: WalkState) {
      lock.lock()
      confirmedTargets.append(contentsOf: state.confirmedTargets)
      pendingTargets.append(contentsOf: state.pendingTargets)
      if let d = state.dumpBuffer {
        dump.append(contentsOf: d)
      }
      lock.unlock()
    }
  }

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

    let dumpEnabled = dumpURL != nil
    var combinedDump: [String] = []
    if dumpEnabled {
      let trigger = triggerMs.map { "  trigger=\($0)" } ?? ""
      combinedDump.append(
        "# flash AX dump  bundle=\(context.bundleIdentifier)  pid=\(context.processID)  time=\(Date())\(trigger)\n"
      )
    }

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
    // during app launches, or for apps with no windows), there's
    // nothing to hint, so return empty rather than walking the whole
    // app and risk picking up menu-bar items.
    var focusedRaw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRaw)
        == .success,
      let focusedCF = focusedRaw,
      CFGetTypeID(focusedCF) == AXUIElementGetTypeID()
    else {
      if let url = dumpURL { flushDump(lines: combinedDump, to: url) }
      return []
    }
    let focusedWindow = focusedCF as! AXUIElement

    var state = WalkState()
    state.dumpBuffer = dumpEnabled ? [] : nil
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
      descendIntoWebAreas: descendIntoWebAreas,
      insideClickable: false,
      insideWebArea: false,
      parentRole: nil,
      idPrefix: "r",
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
    if let d = state.dumpBuffer {
      combinedDump.append(contentsOf: d)
    }
    if dumpEnabled, let url = dumpURL {
      flushDump(lines: combinedDump, to: url)
    }
    return state.confirmedTargets
  }

  /// Off-thread flush of accumulated dump lines. `FileHandle.write` is
  /// serialised through the shared `dumpWriteQueue`, so multiple back-
  /// to-back activations don't interleave their dumps and the
  /// activation that produced the data is already free.
  private func flushDump(lines: [String], to url: URL) {
    let joined = lines.joined()
    Self.dumpWriteQueue.async {
      let fm = FileManager.default
      try? fm.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      // Truncate per activation — matches the documented semantics
      // (file is rewritten on each show_hints).
      fm.createFile(atPath: url.path, contents: nil)
      guard let handle = try? FileHandle(forWritingTo: url) else { return }
      defer { try? handle.close() }
      if let data = joined.data(using: .utf8) {
        try? handle.write(contentsOf: data)
      }
    }
  }

  private func walk(
    _ element: AXUIElement,
    depth: Int,
    screenH: CGFloat,
    visible: CGRect,
    pid: pid_t,
    descendIntoWebAreas: Bool,
    insideClickable: Bool,
    insideWebArea: Bool,
    parentRole: String?,
    idPrefix: String,
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
    guard err == .success, let vals = valuesRef as? [Any], vals.count == 9 else { return }

    let role = vals[0] as? String
    let subrole = vals[1] as? String
    let posValue = Self.axValue(vals[2])
    let sizeValue = Self.axValue(vals[3])
    let enabled = (vals[4] as? Bool) ?? true
    let visibleChildren = vals[5] as? [AXUIElement]
    let visibleRows = vals[6] as? [AXUIElement]
    let allChildren = vals[7] as? [AXUIElement]
    let hidden = (vals[8] as? Bool) ?? false

    // AXHidden=true is the WAI-ARIA `aria-hidden`/`display:none`/
    // `visibility:hidden` signal coming through WebKit/Firefox. The
    // element still has valid pos/size (so our geometric filter would
    // happily accept it) but it isn't on screen and isn't user-
    // clickable. Skip the whole subtree — hidden ancestors imply
    // hidden descendants.
    if hidden { return }

    if !descendIntoWebAreas, role == "AXWebArea" {
      return
    }

    // When dumping, fetch the supported actions + label upfront so the
    // line includes enough signal to diagnose role mismatches. Skipped
    // in the normal hot path — those IPCs are not free.
    var dumpActions: [String]? = nil
    var dumpLabel: String? = nil
    if state.dumpBuffer != nil {
      dumpActions = actionNames(element)
      dumpLabel =
        stringAttr(element, kAXTitleAttribute as CFString)
        ?? stringAttr(element, kAXDescriptionAttribute as CFString)
        ?? stringAttr(element, kAXValueAttribute as CFString)
    }

    var addedAsTarget = false
    // Decide whether this element is a hint target. Three acceptance paths:
    //   1. Role is in the curated `roles` set (covers all native AX
    //      controls + the obvious web cases like AXButton/AXLink). No
    //      extra IPC.
    //   2. We're inside an AXWebArea descendant *and* the element has
    //      no recognised role — could be a `<div onclick>` widget
    //      masquerading as AXGroup. Buffered as a pending target; the
    //      action-name check runs in parallel after the walk.
    //   3. Standalone AXImage (no clickable ancestor). Same deferred
    //      treatment — most decorative images expose no actions.
    //
    // Buffering (2) and (3) instead of doing the action-name IPC
    // inline halves the IPC count on web-heavy apps like AWS Console
    // where virtually every AXGroup in the page tree advertises an
    // `AXPress` action.
    let roleRecognised = role.map { Self.roles.contains($0) } ?? false
    let acceptsViaWebActionCandidate =
      !roleRecognised
      && insideWebArea
      && !insideClickable
      && enabled
      && role != "AXStaticText"
      && role != "AXWebArea"
    if enabled,
      roleRecognised || acceptsViaWebActionCandidate,
      let r = role,
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
      //      action. Buffered as a pending target — the action-name
      //      check runs in parallel after the walk.
      //   See AccessibilityProvider.clickableContainerRoles.
      var imageDecorative = false
      var imageRequiresActionCheck = false
      if r == "AXImage" {
        if insideClickable {
          imageDecorative = true
        } else {
          imageRequiresActionCheck = true
        }
      }
      if !suppressed, !imageDecorative {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if visible.contains(center) {
          let clipped = frame.intersection(visible)
          if !clipped.isNull, clipped.width >= 4, clipped.height >= 4 {
            state.idCounter += 1
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
            let candidate = JumpTarget(
              id: "ax-\(pid)-\(idPrefix)-\(state.idCounter)",
              frame: frame,
              role: r,
              accessibilityLabel: nil,
              pid: pid,
              activate: activate,
              providerID: identifier
            )
            if acceptsViaWebActionCandidate || imageRequiresActionCheck {
              // Defer the action-name IPC: bookkeep the candidate now,
              // resolve in parallel after the walk.
              state.pendingTargets.append(
                PendingTarget(candidate: candidate, element: element))
              addedAsTarget = true
            } else {
              state.confirmedTargets.append(candidate)
              addedAsTarget = true
            }
          }
        }
      }
    }

    // Leaf-role pruning: stop descending once we've added a target whose
    // role we consider atomic.
    if addedAsTarget, let r = role, Self.leafRoles.contains(r) {
      // Emit dump line before bailing.
      if state.dumpBuffer != nil {
        appendDumpLine(
          into: &state.dumpBuffer,
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
      return
    }

    // Emit a dump line for this element (after the gating decision so
    // the dump reflects what the walker actually saw + did). We log
    // every visited node, not just the ones that become targets — the
    // false-negatives are exactly the lines without a `hint=1` tag.
    if state.dumpBuffer != nil {
      appendDumpLine(
        into: &state.dumpBuffer,
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
    //
    // Empty arrays are treated as "no signal", not "zero visible
    // children". Messages' chat list is the canonical example: its
    // table reports `AXVisibleChildren = []` when the container hasn't
    // been queried recently, even though `AXChildren` contains every
    // row. Without this fallback the whole chat list disappears from
    // the walk.
    //
    // Single-attribute children fallback: when the batched IPC drops
    // `kAXChildrenAttribute` (Firefox's a11y does this for `AXTabPanel`
    // under concurrent IPC contention — returns an error placeholder
    // in vals[7] instead of the real child list, and the entire
    // in-page DOM disappears from the walk), re-query that one
    // attribute on its own. The single-attribute IPC succeeds when the
    // batched one didn't — likely because Firefox has had time to
    // materialise the subtree by the time we issue the second call.
    // Cost is bounded: at most one extra IPC per element that returned
    // no children, and only ever fires on truly contested subtrees.
    var children =
      nonEmpty(visibleChildren) ?? nonEmpty(visibleRows) ?? allChildren ?? []
    if children.isEmpty {
      var raw: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) == .success,
        let fallback = raw as? [AXUIElement],
        !fallback.isEmpty
      {
        children = fallback
      }
    }
    let nowInsideClickable =
      insideClickable || (role.map { Self.clickableContainerRoles.contains($0) } ?? false)
    let nowInsideWebArea = insideWebArea || role == "AXWebArea"

    // Concurrent fan-out only fires once per activation, at the focused
    // window's direct children. Deeper recursion stays serial — the
    // bottleneck is the target app's main thread, so over-parallelising
    // doesn't help and over-allocates worker threads. Single-child
    // case falls through to the serial loop below.
    if depth == 0, children.count > 1 {
      let collector = WalkCollector()
      let dumpEnabled = state.dumpBuffer != nil
      // Capture-by-value-friendly copies of the descent params so the
      // worker closure doesn't need to reach back into `self`'s mutable
      // state.
      let captureScreenH = screenH
      let captureVisible = visible
      let capturePid = pid
      let captureDescend = descendIntoWebAreas
      let captureInsideClickable = nowInsideClickable
      let captureInsideWebArea = nowInsideWebArea
      let captureParentRole = role
      let childrenSnapshot = children
      DispatchQueue.concurrentPerform(iterations: childrenSnapshot.count) { i in
        var workerState = WalkState()
        workerState.dumpBuffer = dumpEnabled ? [] : nil
        self.walk(
          childrenSnapshot[i],
          depth: 1,
          screenH: captureScreenH,
          visible: captureVisible,
          pid: capturePid,
          descendIntoWebAreas: captureDescend,
          insideClickable: captureInsideClickable,
          insideWebArea: captureInsideWebArea,
          parentRole: captureParentRole,
          idPrefix: "w\(i)",
          state: &workerState
        )
        collector.absorb(workerState)
      }
      collector.lock.lock()
      state.confirmedTargets.append(contentsOf: collector.confirmedTargets)
      state.pendingTargets.append(contentsOf: collector.pendingTargets)
      if state.dumpBuffer != nil {
        state.dumpBuffer?.append(contentsOf: collector.dump)
      }
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
        descendIntoWebAreas: descendIntoWebAreas,
        insideClickable: nowInsideClickable,
        insideWebArea: nowInsideWebArea,
        parentRole: role,
        idPrefix: idPrefix,
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
        buf[i] = Self.elementHasPressAction(pending[i].element) ? 1 : 0
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

  private func stringAttr(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var raw: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, attribute, &raw)
    guard err == .success else { return nil }
    let s = raw as? String
    guard let s, !s.isEmpty else { return nil }
    return s
  }

  private func appendDumpLine(
    into buffer: inout [String]?,
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
    guard buffer != nil else { return }
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
    let triggerTag = triggerMs.map { "t=\($0) " } ?? ""
    let line = """
      \(indent)\(triggerTag)d=\(depth) role=\(role ?? "?") subrole=\(subrole ?? "-") parent=\(parentRole ?? "-") frame=\(f) enabled=\(enabled) actions=\(acts) label=\(lbl)\(hinted ? " hint=1" : "")
      """
    buffer?.append(line + "\n")
  }
}
