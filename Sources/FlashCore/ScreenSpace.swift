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

  /// The one Y flip between AppKit's bottom-left and Quartz / Accessibility
  /// top-left coordinates, about `height`, the primary display's height. The
  /// flip is its own inverse, so one function converts both ways. The typed
  /// `toAX` / `toNS` conversions below are its callers: a `ScreenPoint` or
  /// `ScreenRect` can only be flipped out of the space its type says it is in.
  fileprivate static func flip(_ rect: CGRect, height: CGFloat) -> CGRect {
    CGRect(
      x: rect.minX, y: height - rect.minY - rect.height, width: rect.width, height: rect.height)
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

// MARK: - Typed coordinates

/// A global screen coordinate space: which corner of the primary display is
/// the origin and which way Y grows. A phantom type on `ScreenPoint` and
/// `ScreenRect`, never a value.
public protocol ScreenCoordinateSpace {}

/// Accessibility and CGEvent space: the primary display's top-left corner is
/// the origin and Y grows downward. `kAXPositionAttribute`, `AXFrame`,
/// `AXUIElementCopyElementAtPosition`, `CGEvent.location`,
/// `CGWindowListCopyWindowInfo` bounds and `CGWarpMouseCursorPosition` all
/// speak it.
public enum AXSpace: ScreenCoordinateSpace {}

/// NSScreen space: the primary display's bottom-left corner is the origin and
/// Y grows upward. `NSScreen.frame`, `NSEvent.mouseLocation`, every overlay
/// window, `JumpTarget.frame`, `AppContext.frontWindowFrame`, the mouse grid
/// and the plugin wire's frames all speak it.
public enum NSSpace: ScreenCoordinateSpace {}

/// A point in one global screen coordinate space. The raw `CGPoint` is for
/// the AppKit / CoreGraphics / Accessibility call that produces or consumes
/// it; between those calls a point carries its space in its type, so it can
/// only be converted out of the space it is in.
public struct ScreenPoint<Space: ScreenCoordinateSpace>: Hashable, Sendable {
  public var cgPoint: CGPoint

  public init(_ cgPoint: CGPoint) {
    self.cgPoint = cgPoint
  }

  public init(x: CGFloat, y: CGFloat) {
    self.cgPoint = CGPoint(x: x, y: y)
  }

  public var x: CGFloat {
    get { cgPoint.x }
    set { cgPoint.x = newValue }
  }

  public var y: CGFloat {
    get { cgPoint.y }
    set { cgPoint.y = newValue }
  }

  public static var zero: ScreenPoint<Space> { ScreenPoint(.zero) }
}

/// A rectangle in one global screen coordinate space; see `ScreenPoint`.
public struct ScreenRect<Space: ScreenCoordinateSpace>: Hashable, Sendable {
  public var cgRect: CGRect

  public init(_ cgRect: CGRect) {
    self.cgRect = cgRect
  }

  public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
    self.cgRect = CGRect(x: x, y: y, width: width, height: height)
  }

  public init(origin: ScreenPoint<Space>, size: CGSize) {
    self.cgRect = CGRect(origin: origin.cgPoint, size: size)
  }

  public var origin: ScreenPoint<Space> {
    get { ScreenPoint(cgRect.origin) }
    set { cgRect.origin = newValue.cgPoint }
  }

  public var size: CGSize {
    get { cgRect.size }
    set { cgRect.size = newValue }
  }

  public var minX: CGFloat { cgRect.minX }
  public var midX: CGFloat { cgRect.midX }
  public var maxX: CGFloat { cgRect.maxX }
  public var minY: CGFloat { cgRect.minY }
  public var midY: CGFloat { cgRect.midY }
  public var maxY: CGFloat { cgRect.maxY }
  public var width: CGFloat { cgRect.width }
  public var height: CGFloat { cgRect.height }
  /// The rect's centre, where a hint click lands.
  public var center: ScreenPoint<Space> { ScreenPoint(x: cgRect.midX, y: cgRect.midY) }

  public var isNull: Bool { cgRect.isNull }
  public var isEmpty: Bool { cgRect.isEmpty }
  public var isInfinite: Bool { cgRect.isInfinite }

  public static var zero: ScreenRect<Space> { ScreenRect(.zero) }
  /// The union seed: a union with `.null` is the other rect, so a display at
  /// a negative origin is kept rather than stretched from zero.
  public static var null: ScreenRect<Space> { ScreenRect(.null) }

  public func contains(_ point: ScreenPoint<Space>) -> Bool { cgRect.contains(point.cgPoint) }
  public func contains(_ rect: ScreenRect<Space>) -> Bool { cgRect.contains(rect.cgRect) }
  public func intersects(_ rect: ScreenRect<Space>) -> Bool { cgRect.intersects(rect.cgRect) }
  public func intersection(_ rect: ScreenRect<Space>) -> ScreenRect<Space> {
    ScreenRect(cgRect.intersection(rect.cgRect))
  }
  public func union(_ rect: ScreenRect<Space>) -> ScreenRect<Space> {
    ScreenRect(cgRect.union(rect.cgRect))
  }
  public func insetBy(dx: CGFloat, dy: CGFloat) -> ScreenRect<Space> {
    ScreenRect(cgRect.insetBy(dx: dx, dy: dy))
  }
}

extension ScreenPoint where Space == AXSpace {
  /// This Accessibility / CGEvent point in NSScreen space.
  public func toNS(primaryHeight: CGFloat) -> ScreenPoint<NSSpace> {
    ScreenPoint<NSSpace>(
      ScreenSpace.flip(CGRect(origin: cgPoint, size: .zero), height: primaryHeight).origin)
  }
}

extension ScreenPoint where Space == NSSpace {
  /// This NSScreen point in Accessibility / CGEvent space.
  public func toAX(primaryHeight: CGFloat) -> ScreenPoint<AXSpace> {
    ScreenPoint<AXSpace>(
      ScreenSpace.flip(CGRect(origin: cgPoint, size: .zero), height: primaryHeight).origin)
  }
}

extension ScreenRect where Space == AXSpace {
  /// This Accessibility / CGEvent rect in NSScreen space.
  public func toNS(primaryHeight: CGFloat) -> ScreenRect<NSSpace> {
    ScreenRect<NSSpace>(ScreenSpace.flip(cgRect, height: primaryHeight))
  }
}

extension ScreenRect where Space == NSSpace {
  /// This NSScreen rect in Accessibility / CGEvent space.
  public func toAX(primaryHeight: CGFloat) -> ScreenRect<AXSpace> {
    ScreenRect<AXSpace>(ScreenSpace.flip(cgRect, height: primaryHeight))
  }
}
