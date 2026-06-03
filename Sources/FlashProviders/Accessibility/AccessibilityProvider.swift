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
  public let priority: Int = 10
  public let readinessPolicy: JumpProviderReadinessPolicy = .continuous

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
    "AXTextField", "AXSearchField", "AXTextArea",
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
    "AXTextField", "AXSearchField", "AXTextArea",
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

  // The attribute array we pass to AXUIElementCopyMultipleAttributeValues.
  // Indices are hot-path constants — keep them in sync with `walk`.
  private static let batchAttrs: CFArray =
    [
      kAXRoleAttribute,  // 0
      kAXSubroleAttribute,  // 1
      kAXPositionAttribute,  // 2
      kAXSizeAttribute,  // 3
      kAXEnabledAttribute,  // 4
      kAXChildrenAttribute,  // 5
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

  public func discover(in context: AppContext, deadline _: Date) throws -> [JumpTarget] {
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
    guard err == .success, let vals = valuesRef as? [Any], vals.count == 6 else { return }

    let role = vals[0] as? String
    let subrole = vals[1] as? String
    let posValue = Self.axValue(vals[2])
    let sizeValue = Self.axValue(vals[3])
    let enabled = (vals[4] as? Bool) ?? true
    let allChildren = vals[5] as? [AXUIElement]

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
    // Firehose mode: every element with a valid frame becomes a hint
    // target. No role allowlist, no enabled check, no visibility filter,
    // no AXImage refinement, no insideClickable gate. This is intentionally
    // overwhelming — used to diagnose which elements AX exposes at all.
    if let posV = posValue, let sizeV = sizeValue,
      let frame = frameFromAX(pos: posV, size: sizeV, screenH: screenH)
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
        }
      }
      let candidate = JumpTarget(
        id: "ax-\(pid)-\(idPrefix)-\(state.idCounter)",
        frame: frame,
        role: capturedRole,
        accessibilityLabel: nil,
        pid: pid,
        activate: activate,
        providerID: identifier
      )
      state.confirmedTargets.append(candidate)
      addedAsTarget = true
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

    // Always walk `kAXChildrenAttribute`. We deliberately do NOT prefer
    // `kAXVisibleChildren` / `kAXVisibleRows` even though that would skip
    // scrolled-off rows in NSTableView / NSOutlineView / NSCollectionView:
    // the dump exists to answer "is this element in the AX tree?", and
    // hiding scrolled-off rows from the dump makes the question
    // unanswerable.
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
      let dumpEnabled = state.dumpBuffer != nil
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
        workerState.dumpBuffer = dumpEnabled ? [] : nil
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
    if sz.width <= 0 || sz.height <= 0 { return nil }
    let flippedY = screenH - origin.y - sz.height
    return CGRect(x: origin.x, y: flippedY, width: sz.width, height: sz.height)
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
