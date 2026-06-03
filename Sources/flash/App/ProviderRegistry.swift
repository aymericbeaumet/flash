import FlashCore
import FlashProviders
import Foundation

/// The provider chain for a given app:
///   - Browser script bridge for Safari / Chrome (priority 30) — Vimium-style
///     DOM discovery via AppleScript `do JavaScript`. Falls back silently to
///     AX if Automation is denied.
///   - Tmux pane walker (priority 20) — applies only when the focused
///     app is a known terminal bundle AND a tmux client lives in the
///     terminal's process subtree. Hints each alphanumeric word in the
///     visible pane; clipboard-copies on commit. Marks results
///     volatile so AppMonitor skips prepared-model lookup for
///     this context (tmux content changes aren't observable via AX).
///   - Generic AX walker (priority 10) — universal, handles every native app
///     and Firefox's in-page DOM via AXWebArea descendants.
///
/// Within a chain, higher priority runs first. On overlapping rects the
/// higher-priority provider wins via spatial dedup in AppMonitor — so for
/// Safari/Chrome the script bridge's precise DOM rects suppress AX-derived
/// web-area targets, and tmux per-word rects suppress the AX text-area
/// rect for terminals that expose one (Terminal.app, iTerm2).
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
      TmuxProvider(),
      AccessibilityProvider(),
    ]
  }

  func chain(for context: AppContext) -> [JumpProvider] {
    providers
      .filter { $0.supports(context) }
      .sorted { $0.priority > $1.priority }
  }
}
