import AppKit
import ApplicationServices
import FlashCore

/// Single, universal AX walker. No per-app variants any more — every macOS app
/// is treated by the same rules: clickable controls, text inputs, and rows in
/// virtualised lists. Section-header rows are suppressed via `skipSubroles`.
///
/// Performance contract:
///   - Exactly one IPC per visited element (batched via
///     AXUIElementCopyMultipleAttributeValues).
///   - Prefer kAXVisibleChildrenAttribute over kAXChildrenAttribute so
///     scrolled-off content in NSOutlineView / NSTableView / NSCollectionView
///     is never walked. On Notes' 292-row sidebar this turns a ~300-element
///     walk into a ~30-element walk — only the visible rows are touched.
///   - No mid-walk deadline truncation: walks always complete (so the set of
///     returned targets is deterministic). The chain-level deadline in
///     AppMonitor is the only safety net.
open class AccessibilityProvider: JumpProvider {
    public let identifier: String
    public let priority: Int
    public let roles: Set<String>
    public let leafRoles: Set<String>
    public let skipSubroles: Set<String>
    public let maxDepth: Int
    public let maxTargets: Int
    public let supportedBundles: Set<String>?

    /// Every clickable / focusable role we recognise. Generic across apps —
    /// don't add app-specific roles here. If an app has a custom non-standard
    /// role you want to hint, expose it through config later.
    public static let defaultRoles: Set<String> = [
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
        // Icon-only buttons sometimes report as AXImage
        "AXImage",
    ]

    /// Roles where we add a target and *do not* descend further. Restricted
    /// to virtualised-list rows because those are the only elements where the
    /// fanout below the target is both huge (per-row icons, labels, dates)
    /// and uninteresting (no independent click targets). For everything
    /// else — buttons, popups, menu items — we descend, which means a
    /// button that has an open menu underneath it gets its menu items
    /// hinted alongside the button itself.
    public static let defaultLeafRoles: Set<String> = [
        "AXRow", "AXCell",
    ]

    /// AppKit's standard subroles for "section header" rows in
    /// NSOutlineView/NSTableView. We *don't* add these as targets, but we
    /// keep descending — so the disclosure triangle inside the header gets
    /// hinted on its own.
    public static let defaultSkipSubroles: Set<String> = [
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

    public init(
        identifier: String = "accessibility",
        priority: Int = 10,
        roles: Set<String> = AccessibilityProvider.defaultRoles,
        leafRoles: Set<String> = AccessibilityProvider.defaultLeafRoles,
        skipSubroles: Set<String> = AccessibilityProvider.defaultSkipSubroles,
        maxDepth: Int = 80,
        maxTargets: Int = 1500,
        supportedBundles: Set<String>? = nil
    ) {
        self.identifier = identifier
        self.priority = priority
        self.roles = roles
        self.leafRoles = leafRoles
        self.skipSubroles = skipSubroles
        self.maxDepth = maxDepth
        self.maxTargets = maxTargets
        self.supportedBundles = supportedBundles
    }

    open func supports(_ context: AppContext) -> Bool {
        if let s = supportedBundles { return s.contains(context.bundleIdentifier) }
        return true
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

    // The attribute array we pass to AXUIElementCopyMultipleAttributeValues.
    // Indices are hot-path constants — keep them in sync with `walk`.
    private static let batchAttrs: CFArray = [
        kAXRoleAttribute,          // 0
        kAXSubroleAttribute,       // 1
        kAXPositionAttribute,      // 2
        kAXSizeAttribute,          // 3
        kAXEnabledAttribute,       // 4
        "AXVisibleChildren",       // 5 — virtualised containers
        "AXVisibleRows",           // 6 — NSTableView / NSOutlineView specifically
        kAXChildrenAttribute,      // 7 — fallback
    ] as CFArray

    open func discover(in context: AppContext, deadline _: Date) throws -> [JumpTarget] {
        let app = AXUIElementCreateApplication(context.processID)
        let screenH = primaryScreenHeight()

        // The clip rect is the *actual on-screen union of the source app's
        // visible windows*, taken from the WindowServer's perspective via
        // CGWindowList. This is stricter than the screen frame:
        //   - AX can report frames for scrolled-off rows that happen to fall
        //     within the screen bounds (below the Notes window, on the
        //     wallpaper). Those rejected here.
        //   - But popover/menu windows owned by the same process *are* in
        //     CGWindowList, so they're included in the union. Hints on the
        //     share popover items pass through.
        let clip = visibleWindowsUnion(pid: context.processID)
        guard !clip.isNull else { return [] }

        var out: [JumpTarget] = []
        var idCounter = 0

        // Walk straight from the app element. The batched read inside `walk`
        // pulls kAXChildrenAttribute as one of its fields, so we don't need
        // a separate kAXChildrenAttribute IPC on the app first. The app's
        // role (AXApplication) doesn't match `roles`, so it doesn't become
        // a target itself — it just descends.
        walk(app, depth: 0, screenH: screenH,
             visible: clip, out: &out, idCounter: &idCounter)
        return out
    }

    /// Union, in NSScreen coordinates, of every window the WindowServer is
    /// currently rendering for `pid`. Off-screen / minimized windows aren't
    /// in CGWindowList with `.optionOnScreenOnly`, so they're excluded.
    private func visibleWindowsUnion(pid: pid_t) -> CGRect {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return .null
        }
        let screenH = primaryScreenHeight()
        var union: CGRect = .null
        for w in info {
            guard let wpid = w[kCGWindowOwnerPID as String] as? Int32, pid_t(wpid) == pid else { continue }
            guard let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            // CGWindowList reports bounds in top-left origin; flip to NSScreen
            // (bottom-left origin of primary screen).
            let ns = CGRect(
                x: cgBounds.minX,
                y: screenH - cgBounds.minY - cgBounds.height,
                width: cgBounds.width,
                height: cgBounds.height
            )
            union = union.union(ns)
        }
        return union
    }

    private func walk(
        _ element: AXUIElement,
        depth: Int,
        screenH: CGFloat,
        visible: CGRect,
        out: inout [JumpTarget],
        idCounter: inout Int
    ) {
        if depth > maxDepth { return }
        if out.count >= maxTargets { return }

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

        var addedAsTarget = false
        if enabled,
           let r = role, roles.contains(r),
           let posV = posValue, let sizeV = sizeValue,
           let frame = frameFromAX(pos: posV, size: sizeV, screenH: screenH) {
            // Skip subroles that mark non-target group containers (e.g. outline
            // section headers). We still descend, so their children can be
            // hinted individually.
            let suppressed = subrole.map { skipSubroles.contains($0) } ?? false
            if !suppressed {
                let center = CGPoint(x: frame.midX, y: frame.midY)
                if visible.contains(center) {
                    let clipped = frame.intersection(visible)
                    if !clipped.isNull, clipped.width >= 4, clipped.height >= 4 {
                        idCounter += 1
                        let captured = element
                        let capturedRole = r
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
                                if AXUIElementPerformAction(captured, kAXPressAction as CFString) == .success { return true }
                                if AXUIElementPerformAction(captured, "AXOpen" as CFString) == .success { return true }
                                if AXUIElementPerformAction(captured, "AXConfirm" as CFString) == .success { return true }
                                return false
                            case .rightClick:
                                return AXUIElementPerformAction(captured, kAXShowMenuAction as CFString) == .success
                            }
                        }
                        out.append(JumpTarget(
                            id: "ax-\(idCounter)",
                            frame: frame,
                            role: r,
                            accessibilityLabel: nil,
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
        if addedAsTarget, let r = role, leafRoles.contains(r) {
            return
        }

        // Prefer the narrowest "visible" view of children that the element
        // implements:
        //   1. kAXVisibleChildrenAttribute (NSCollectionView, generic scroll)
        //   2. kAXVisibleRowsAttribute (NSTableView / NSOutlineView)
        //   3. kAXChildrenAttribute (everything else, fallback)
        // For Notes' 292-row sidebar this drops the walk to the ~12 rows
        // actually rendered on screen.
        let children = visibleChildren ?? visibleRows ?? allChildren ?? []
        for child in children {
            walk(child, depth: depth + 1, screenH: screenH, visible: visible, out: &out, idCounter: &idCounter)
            if out.count >= maxTargets { return }
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
}
