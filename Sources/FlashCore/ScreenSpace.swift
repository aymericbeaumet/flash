import AppKit

/// The primary display's height: the pivot between AppKit's bottom-left and
/// Quartz / Accessibility top-left coordinates. `NSScreen` is main-affine, so
/// the height is read on main — at first use there, and again whenever the
/// screen parameters change (`startObserving`) — and every thread reads the
/// cached value.
public enum ScreenSpace {
  private static let lock = NSLock()
  private static var cachedPrimaryHeight: CGFloat?
  private static var observer: NSObjectProtocol?

  public static var primaryHeight: CGFloat {
    lock.lock()
    let cached = cachedPrimaryHeight
    lock.unlock()
    if let cached { return cached }
    return refresh()
  }

  /// Keep the cached height current. Call once, on main, at launch.
  public static func startObserving() {
    guard observer == nil else { return }
    refresh()
    observer = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { _ in refresh() }
  }

  @discardableResult
  private static func refresh() -> CGFloat {
    let height =
      NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
      ?? NSScreen.main?.frame.height ?? 1080
    lock.lock()
    cachedPrimaryHeight = height
    lock.unlock()
    return height
  }
}
