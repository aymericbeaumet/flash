import Foundation
import FlashCore
import FlashProviders

/// The provider chain for a given app:
///   - Browser script bridge for Safari / Chrome (priority 30) — Vimium-style
///     DOM discovery via AppleScript `do JavaScript`. Falls back silently to
///     AX if Automation is denied.
///   - Generic AX walker (priority 10) — universal, handles every native app
///     and Firefox's in-page DOM via AXWebArea descendants.
///
/// Within a chain, higher priority runs first. On overlapping rects the
/// higher-priority provider wins via spatial dedup in AppMonitor — so for
/// Safari/Chrome the script bridge's precise DOM rects suppress AX-derived
/// web-area targets.
///
/// There is no per-app configuration here on purpose. The project's working
/// assumption is to converge on universal rules before reintroducing
/// per-bundle knobs. See AGENTS.md → "Adding a new provider" for the policy.
final class ProviderRegistry {
    private(set) var providers: [JumpProvider]

    init() {
        providers = [
            SafariProvider(),
            ChromeProvider(),
            AccessibilityProvider(),
        ]
    }

    func chain(for context: AppContext) -> [JumpProvider] {
        providers
            .filter { $0.supports(context) }
            .sorted { $0.priority > $1.priority }
    }
}
