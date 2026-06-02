import Foundation
import FlashCore

public final class AlacrittyProvider: JumpProvider {
    public let identifier = "alacritty"
    public let priority = 40
    private let vision: VisionProvider

    public init(visionEnabledBundles: [String]) {
        self.vision = VisionProvider(enabledBundles: visionEnabledBundles)
    }

    public func supports(_ context: AppContext) -> Bool {
        // Only participate if the user has opted-in to OCR for Alacritty —
        // otherwise we'd trigger the Screen Recording prompt for no payoff.
        context.bundleIdentifier == "org.alacritty" && vision.supports(context)
    }

    public func discover(in context: AppContext, deadline: Date) throws -> [JumpTarget] {
        try vision.discover(in: context, deadline: deadline)
    }
}
