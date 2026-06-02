import Foundation
import FlashCore
import FlashProviders

final class ProviderRegistry {
    private(set) var providers: [JumpProvider]

    init(config: Config) {
        let visionBundles = config.providers.visionEnabledBundles
        var list: [JumpProvider] = [
            SafariProvider(),
            ChromeProvider(),
            FirefoxProvider(),
            MessagesProvider(),
            NotesProvider(),
            RemindersProvider(),
            PosticoProvider(),
            WhatsAppProvider(visionEnabledBundles: visionBundles),
            LinearProvider(visionEnabledBundles: visionBundles),
            AlacrittyProvider(visionEnabledBundles: visionBundles),
        ]
        list.append(VisionProvider(enabledBundles: visionBundles))

        let perAppAX = AccessibilityProvider(
            identifier: "accessibility",
            priority: 10,
            roles: AccessibilityProvider.defaultRoles,
            maxDepth: 60,
            maxTargets: 500,
            supportedBundles: nil
        )
        list.append(perAppAX)

        let disabled = Set(config.providers.disabled)
        providers = list.filter { !disabled.contains($0.identifier) }
    }

    /// Resolve providers that apply for the given context, ordered by descending priority.
    func chain(for context: AppContext) -> [JumpProvider] {
        providers
            .filter { $0.supports(context) }
            .sorted { $0.priority > $1.priority }
    }
}
