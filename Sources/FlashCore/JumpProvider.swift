import Foundation

public enum JumpProviderReadinessPolicy: Sendable {
  /// Safe to keep prepared from AX/workspace invalidation while the app
  /// is focused.
  case continuous
  /// Run only when the user activates Flash.
  case activationOnly
  /// Results depend on external state Flash cannot observe reliably.
  case volatile
}

public protocol JumpProvider: AnyObject {
  var identifier: String { get }
  var priority: Int { get }
  /// How AppMonitor is allowed to prepare this provider's results.
  var readinessPolicy: JumpProviderReadinessPolicy { get }
  /// When true, this provider's results depend on state that isn't
  /// observable via `AXObserver` notifications, so caching them would
  /// silently serve stale hints. Activation skips prepared-model lookup
  /// and writes for any focused-app context where a volatile provider
  /// applies. Default: false.
  ///
  /// Set this on providers that read external state — e.g.,
  /// `TmuxProvider` shells out to `tmux capture-pane`, whose content
  /// changes from terminal output and async tmux activity that the
  /// host terminal doesn't expose to AX at all.
  var resultsAreVolatile: Bool { get }
  func supports(_ context: AppContext) -> Bool
  /// Return a complete deterministic target set for the current UI state.
  /// Providers must not deadline-truncate results; a slow complete walk is
  /// preferable to serving a partial, activation-dependent hint set.
  func discover(in context: AppContext) throws -> [JumpTarget]
}

extension JumpProvider {
  public var readinessPolicy: JumpProviderReadinessPolicy { .activationOnly }
  public var resultsAreVolatile: Bool { readinessPolicy == .volatile }
}
