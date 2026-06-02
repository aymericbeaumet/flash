import FlashCore

/// Slack is Electron. Its AX tree is partial — Slack ships with Chromium AX
/// enabled, so buttons, sidebar entries, the message input, and toolbar
/// controls are reachable. Channel-list rows and message-row hover affordances
/// (reactions, threads) may not always expose AX nodes; if a channel doesn't
/// render hints, that's an upstream limitation, not Flash's.
public final class SlackProvider: AccessibilityProvider {
    public init() {
        super.init(
            identifier: "slack",
            priority: 30,
            roles: [
                "AXButton", "AXLink", "AXTextField", "AXSearchField",
                "AXRow", "AXCell", "AXMenuItem", "AXMenuButton",
                "AXImage", "AXTab", "AXList", "AXListItem", "AXGroup",
                "AXCheckBox", "AXPopUpButton", "AXToolbar",
                // Slack sometimes only exposes static text for message-list rows.
                "AXStaticText",
            ],
            maxDepth: 120,
            maxTargets: 600,
            supportedBundles: ["com.tinyspeck.slackmacgap"]
        )
    }
}
