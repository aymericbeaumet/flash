import FlashCore
import Foundation

public final class WhatsAppProvider: JumpProvider {
    public let identifier = "whatsapp"
    public let priority = 30
    private let ax: AccessibilityProvider
    private let vision: VisionProvider

    public init(visionEnabledBundles: [String]) {
        self.ax = AccessibilityProvider(
            identifier: "whatsapp-ax",
            priority: 30,
            roles: ["AXButton", "AXLink", "AXTextField", "AXRow", "AXCell", "AXMenuItem", "AXImage"],
            maxDepth: 80,
            maxTargets: 300,
            supportedBundles: ["net.whatsapp.WhatsApp", "WhatsApp"]
        )
        self.vision = VisionProvider(enabledBundles: visionEnabledBundles)
    }

    public func supports(_ context: AppContext) -> Bool {
        let id = context.bundleIdentifier
        return id == "net.whatsapp.WhatsApp" || id == "WhatsApp"
    }

    public func discover(in context: AppContext, deadline: Date) throws -> [JumpTarget] {
        let axResults = (try? ax.discover(in: context, deadline: deadline)) ?? []
        if axResults.count >= 5 { return axResults }
        // Only fall back to OCR if the user has opted-in for this bundle.
        guard vision.supports(context) else { return axResults }
        let visionResults = (try? vision.discover(in: context, deadline: deadline)) ?? []
        return axResults + visionResults
    }
}
