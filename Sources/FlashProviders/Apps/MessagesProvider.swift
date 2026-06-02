import FlashCore

public final class MessagesProvider: AccessibilityProvider {
    public init() {
        super.init(
            identifier: "messages",
            priority: 20,
            roles: ["AXButton", "AXLink", "AXRow", "AXCell", "AXTextField", "AXTextArea", "AXMenuItem"],
            maxDepth: 50,
            maxTargets: 300,
            supportedBundles: ["com.apple.MobileSMS", "com.apple.iChat"]
        )
    }
}
