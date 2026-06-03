import Foundation

public protocol JumpProvider: AnyObject {
  var identifier: String { get }
  var priority: Int { get }
  /// When true, this provider's results depend on state that isn't
  /// observable via `AXObserver` notifications, so caching them would
  /// silently serve stale hints. Activation skips the cache (lookup
  /// and write) and the AX-event-driven pre-walk for any focused-app
  /// context where a volatile provider applies. Default: false.
  ///
  /// Set this on providers that read external state — e.g.,
  /// `TmuxProvider` shells out to `tmux capture-pane`, whose content
  /// changes from terminal output and async tmux activity that the
  /// host terminal doesn't expose to AX at all.
  var resultsAreVolatile: Bool { get }
  func supports(_ context: AppContext) -> Bool
  func discover(in context: AppContext, deadline: Date) throws -> [JumpTarget]
}

extension JumpProvider {
  public var resultsAreVolatile: Bool { false }
}
