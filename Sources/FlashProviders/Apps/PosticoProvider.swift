import FlashCore

public final class PosticoProvider: AccessibilityProvider {
    public init() {
        super.init(
            identifier: "postico",
            priority: 20,
            roles: ["AXButton", "AXLink", "AXRow", "AXCell", "AXTextField", "AXSearchField", "AXMenuItem", "AXOutline", "AXTab", "AXPopUpButton"],
            maxDepth: 60,
            maxTargets: 500,
            supportedBundles: ["at.eggerapps.Postico2", "at.eggerapps.Postico"]
        )
    }
}
