import ApplicationServices

/// Factory for application-level accessibility elements with a bounded messaging
/// timeout applied.
///
/// The macOS default AX messaging timeout is **6 seconds**. Any synchronous AX
/// call (`AXUIElementCopyAttributeValue`, `…PerformAction`, …) issued against an
/// app that is busy or wedged — a browser lazily rebuilding its AX tree, an app
/// spinning on its own main thread — blocks the *caller* for that full 6s. When
/// the caller is Flash's main thread (hint commit, `tab_select`, the AX broker),
/// that's a 6s beachball during which the keyboard tap (which shares the main
/// run loop) can't service input.
///
/// Capping the per-message timeout converts that hang into a bounded failure the
/// caller can fall through (to the next click strategy, an empty walk, etc.).
/// Every `AXUIElementCreateApplication` in production code should go through
/// `AXApp.make` so no AX call can silently inherit the 6s system default — a
/// guardrail enforces this (`Scripts/check-guardrails.sh`).
public enum AXApp {
  /// Per-message timeout (seconds) applied to app elements. 1.5s is generous
  /// enough for a healthy app's cold AX tree while still bounding a wedged one
  /// to a quarter of the 6s default.
  public static let defaultMessagingTimeout: Float = 1.5

  /// Create an application AX element for `pid` with a bounded messaging
  /// timeout. The timeout applies to this element and the elements obtained
  /// through it, so a single call here bounds an entire tree walk.
  public static func make(
    pid: pid_t,
    messagingTimeout: Float = defaultMessagingTimeout
  ) -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, messagingTimeout)
    return app
  }
}
