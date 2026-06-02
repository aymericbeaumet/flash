import AppKit
import FlashCore

public final class ChromeProvider: BrowserScriptProvider {
    public init() {
        super.init(identifier: "chrome", bundleID: "com.google.Chrome", appName: "Google Chrome", priority: 30)
    }
}
