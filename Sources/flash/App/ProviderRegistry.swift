import Foundation
import FlashCore
import FlashProviders

/// One generic AccessibilityProvider handles every app. No per-app special
/// cases — the rule set is universal: clickable controls, text inputs, list
/// rows in virtualised containers. App-specific tuning belongs in config
/// later, not in code.
final class ProviderRegistry {
    private(set) var providers: [JumpProvider]

    init(config: Config) {
        let generic = AccessibilityProvider()
        let disabled = Set(config.providers.disabled)
        providers = [generic].filter { !disabled.contains($0.identifier) }
    }

    func chain(for context: AppContext) -> [JumpProvider] {
        providers
            .filter { $0.supports(context) }
            .sorted { $0.priority > $1.priority }
    }
}
