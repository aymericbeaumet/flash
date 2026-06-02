import FlashCore

public final class WhatsAppProvider: AccessibilityProvider {
    public init() {
        super.init(
            identifier: "whatsapp",
            priority: 30,
            roles: [
                "AXButton", "AXLink", "AXTextField", "AXSearchField",
                "AXRow", "AXCell", "AXMenuItem", "AXMenuButton",
                "AXImage", "AXTab", "AXList", "AXListItem",
            ],
            maxDepth: 100,
            maxTargets: 400,
            supportedBundles: ["net.whatsapp.WhatsApp", "WhatsApp", "desktop.WhatsApp"]
        )
    }
}
