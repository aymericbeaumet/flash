import FlashCore

/// Firefox doesn't expose `do JavaScript` via AppleScript like Safari/Chrome, so we
/// rely on its AX tree for both chrome (tabs, address bar, toolbar buttons) and the
/// rendered DOM. Firefox publishes the page DOM under `AXWebArea`; we traverse into
/// it and pull the standard clickable roles.
public final class FirefoxProvider: AccessibilityProvider {
    public init() {
        super.init(
            identifier: "firefox",
            priority: 25,
            roles: [
                // Chrome (Firefox UI)
                "AXButton", "AXMenuItem", "AXMenuButton", "AXPopUpButton",
                "AXTab", "AXTabGroup",
                "AXTextField", "AXSearchField", "AXComboBox",
                "AXCheckBox", "AXRadioButton",
                "AXToolbar",
                // In-page DOM (descendants of AXWebArea)
                "AXLink", "AXImage", "AXHeading",
            ],
            maxDepth: 120,
            maxTargets: 800,
            supportedBundles: [
                "org.mozilla.firefox",
                "org.mozilla.firefoxdeveloperedition",
                "org.mozilla.nightly",
            ]
        )
    }
}
