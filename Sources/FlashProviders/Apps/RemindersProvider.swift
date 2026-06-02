import FlashCore

public final class RemindersProvider: AccessibilityProvider {
    public init() {
        super.init(
            identifier: "reminders",
            priority: 20,
            roles: ["AXButton", "AXLink", "AXRow", "AXCell", "AXCheckBox", "AXTextField", "AXSearchField", "AXMenuItem"],
            maxDepth: 50,
            maxTargets: 300,
            supportedBundles: ["com.apple.reminders"]
        )
    }
}
