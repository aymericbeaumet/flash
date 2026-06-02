import FlashCore

public final class LinearProvider: AccessibilityProvider {
    public init() {
        super.init(
            identifier: "linear",
            priority: 30,
            roles: [
                "AXButton", "AXLink", "AXTextField", "AXSearchField",
                "AXRow", "AXCell", "AXMenuItem", "AXMenuButton",
                "AXImage", "AXTab", "AXList", "AXListItem", "AXGroup",
                "AXCheckBox", "AXPopUpButton",
            ],
            maxDepth: 100,
            maxTargets: 500,
            supportedBundles: ["com.linear", "com.linear.LinearDesktop"]
        )
    }
}
