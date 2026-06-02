import FlashCore

public final class NotesProvider: AccessibilityProvider {
    public init() {
        super.init(
            identifier: "notes",
            priority: 20,
            roles: ["AXButton", "AXLink", "AXRow", "AXCell", "AXTextField", "AXSearchField", "AXMenuItem", "AXOutline"],
            maxDepth: 50,
            maxTargets: 300,
            supportedBundles: ["com.apple.Notes"]
        )
    }
}
