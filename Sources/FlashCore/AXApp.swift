import ApplicationServices

/// Factory for application-level accessibility elements with a bounded messaging
/// timeout applied.
///
/// The macOS default AX messaging timeout is **6 seconds**. Any synchronous AX
/// call (`AXUIElementCopyAttributeValue`, `…PerformAction`, …) issued against an
/// app that is busy or wedged — a browser lazily rebuilding its AX tree, an app
/// spinning on its own main thread — blocks the *caller* for that full 6s. When
/// the caller is Flash's main thread (hint commit, `tab select`, the AX broker),
/// that's a 6s beachball during which the keyboard tap (which shares the main
/// run loop) can't service input.
///
/// Capping the per-message timeout converts that hang into a bounded failure the
/// caller can fall through (to the next click strategy, an empty walk, etc.).
/// Every `AXUIElementCreateApplication` in production code should go through
/// `AXApp.make` so no AX call can silently inherit the 6s system default — a
/// guardrail enforces this (`Scripts/check-guardrails.sh`).
///
/// Elements read through an app element (its windows, children, the focused
/// element) do not inherit its timeout: they wait the process-wide one, which
/// only a timeout set on a system-wide element changes. The resident sets
/// that once at launch (`configureProcessMessagingTimeout`), and every other
/// system-wide element comes from `systemWide()`, which leaves it alone — a
/// probe that set its own short timeout there would rewrite the bound of
/// every AX call in the process, hint walks included (guardrail-enforced).
public enum AXApp {
  /// Per-message timeout (seconds) applied to app elements. 1.5s is generous
  /// enough for a healthy app's cold AX tree while still bounding a wedged one
  /// to a quarter of the 6s default.
  public static let defaultMessagingTimeout: Float = 1.5

  /// Create an application AX element for `pid` with a bounded messaging
  /// timeout. The timeout applies to this element only: an element read
  /// through it (a window, a child) waits the process-wide timeout instead
  /// (`configureProcessMessagingTimeout`). A caller that keeps such an
  /// element on a latency-sensitive path bounds it itself, as `WindowMover`
  /// does for the window it moves.
  public static func make(
    pid: pid_t,
    messagingTimeout: Float = defaultMessagingTimeout
  ) -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, messagingTimeout)
    return app
  }

  /// Bound every AX call in the process that has no timeout of its own to
  /// `timeout` instead of the 6 s system default. Once, at launch, before
  /// any AX work.
  public static func configureProcessMessagingTimeout(
    _ timeout: Float = defaultMessagingTimeout
  ) {
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout)
  }

  /// The system-wide element, for hit-testing and the focused element. Its
  /// calls wait the process-wide timeout; never set one on it.
  public static func systemWide() -> AXUIElement {
    AXUIElementCreateSystemWide()
  }
}
