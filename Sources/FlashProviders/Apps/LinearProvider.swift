import FlashCore
import Foundation

public final class LinearProvider: JumpProvider {
    public let identifier = "linear"
    public let priority = 30
    private let ax: AccessibilityProvider
    private let vision: VisionProvider

    public init(visionEnabledBundles: [String]) {
        self.ax = AccessibilityProvider(
            identifier: "linear-ax",
            priority: 30,
            roles: ["AXButton", "AXLink", "AXTextField", "AXRow", "AXCell", "AXMenuItem", "AXTab"],
            maxDepth: 80,
            maxTargets: 400,
            supportedBundles: ["com.linear", "com.linear.LinearDesktop"]
        )
        self.vision = VisionProvider(enabledBundles: visionEnabledBundles)
    }

    public func supports(_ context: AppContext) -> Bool {
        context.bundleIdentifier.hasPrefix("com.linear")
    }

    public func discover(in context: AppContext, deadline: Date) throws -> [JumpTarget] {
        let axResults = (try? ax.discover(in: context, deadline: deadline)) ?? []
        if axResults.count >= 5 { return axResults }
        guard vision.supports(context) else { return axResults }
        let visionResults = (try? vision.discover(in: context, deadline: deadline)) ?? []
        return axResults + visionResults
    }
}
