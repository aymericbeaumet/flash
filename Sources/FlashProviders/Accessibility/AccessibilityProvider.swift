import AppKit
import ApplicationServices
import FlashCore

open class AccessibilityProvider: JumpProvider {
    public let identifier: String
    public let priority: Int
    public let roles: Set<String>
    public let maxDepth: Int
    public let maxTargets: Int
    public let supportedBundles: Set<String>?

    public static let defaultRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuButton",
        "AXTextField", "AXSearchField", "AXTextArea",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXTab", "AXCell", "AXRow", "AXOutline",
        "AXImage", "AXStaticText",
    ]

    public init(
        identifier: String = "accessibility",
        priority: Int = 10,
        roles: Set<String> = AccessibilityProvider.defaultRoles,
        maxDepth: Int = 60,
        maxTargets: Int = 500,
        supportedBundles: Set<String>? = nil
    ) {
        self.identifier = identifier
        self.priority = priority
        self.roles = roles
        self.maxDepth = maxDepth
        self.maxTargets = maxTargets
        self.supportedBundles = supportedBundles
    }

    open func supports(_ context: AppContext) -> Bool {
        if let s = supportedBundles { return s.contains(context.bundleIdentifier) }
        return true
    }

    open func discover(in context: AppContext, deadline: Date) throws -> [JumpTarget] {
        let app = AXUIElementCreateApplication(context.processID)
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused)
        let root: AXUIElement
        if err == .success, let f = focused {
            root = (f as! AXUIElement)
        } else {
            root = app
        }

        let screenH = primaryScreenHeight()

        var out: [JumpTarget] = []
        var idCounter = 0
        let visible = context.frontWindowFrame
        walk(root, depth: 0, deadline: deadline, screenH: screenH, visible: visible, out: &out, idCounter: &idCounter)
        return out
    }

    private func walk(
        _ element: AXUIElement,
        depth: Int,
        deadline: Date,
        screenH: CGFloat,
        visible: CGRect,
        out: inout [JumpTarget],
        idCounter: inout Int
    ) {
        if depth > maxDepth { return }
        if out.count >= maxTargets { return }
        if Date() > deadline { return }

        let role = stringAttr(element, kAXRoleAttribute)
        if let r = role, roles.contains(r) {
            if let frame = elementFrame(element, screenH: screenH) {
                let clipped = frame.intersection(visible)
                if !clipped.isNull && clipped.width >= 4 && clipped.height >= 4 {
                    idCounter += 1
                    let label = stringAttr(element, kAXTitleAttribute)
                        ?? stringAttr(element, kAXDescriptionAttribute)
                        ?? stringAttr(element, kAXValueAttribute)
                    let captured = element
                    let activate: ((JumpAction) -> Bool) = { action in
                        switch action {
                        case .leftClick:
                            return AXUIElementPerformAction(captured, kAXPressAction as CFString) == .success
                        case .rightClick:
                            return AXUIElementPerformAction(captured, kAXShowMenuAction as CFString) == .success
                        }
                    }
                    out.append(JumpTarget(
                        id: "ax-\(idCounter)",
                        frame: frame,
                        role: r,
                        accessibilityLabel: label,
                        activate: activate,
                        providerID: identifier
                    ))
                }
            }
        }

        var childrenRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                walk(child, depth: depth + 1, deadline: deadline, screenH: screenH, visible: visible, out: &out, idCounter: &idCounter)
                if out.count >= maxTargets { return }
                if Date() > deadline { return }
            }
        }
    }

    private func primaryScreenHeight() -> CGFloat {
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return primary.frame.height
        }
        return NSScreen.main?.frame.height ?? 1080
    }

    private func stringAttr(_ element: AXUIElement, _ name: String) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        if let s = ref as? String { return s.isEmpty ? nil : s }
        return nil
    }

    private func elementFrame(_ element: AXUIElement, screenH: CGFloat) -> CGRect? {
        var posRef: AnyObject?
        var sizeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        let posValue = posRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        guard AXValueGetType(posValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
        AXValueGetValue(posValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue, .cgSize, &size)
        if size.width <= 0 || size.height <= 0 { return nil }

        let flippedY = screenH - origin.y - size.height
        return CGRect(x: origin.x, y: flippedY, width: size.width, height: size.height)
    }
}
