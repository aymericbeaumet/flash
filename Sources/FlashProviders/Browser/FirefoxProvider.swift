import FlashCore

public final class FirefoxProvider: AccessibilityProvider {
    public init() {
        super.init(
            identifier: "firefox",
            priority: 25,
            roles: ["AXLink", "AXButton", "AXTextField", "AXSearchField", "AXTab", "AXMenuItem"],
            maxDepth: 80,
            maxTargets: 500,
            supportedBundles: ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]
        )
    }
}
