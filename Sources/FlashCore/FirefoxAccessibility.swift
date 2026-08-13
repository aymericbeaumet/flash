import ApplicationServices
import Foundation

/// Keeps Firefox's lazily-created AX tree available only while Flash is
/// actively reading or acting on it.
///
/// Firefox enables accessibility when its application role is read, but that
/// mode also changes programmatic window moves into a slow, often incomplete
/// animation. The mode is process-wide, so every Flash AX client must share a
/// per-process lock: tree work wakes Firefox for the duration of the operation
/// and restores the prior state before a window move can begin.
public enum FirefoxAccessibility {
  public static let bundleIdentifiers: Set<String> = [
    "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition",
    "org.mozilla.nightly",
  ]

  public static func matches(bundleIdentifier: String?) -> Bool {
    bundleIdentifier.map { bundleIdentifiers.contains($0) } ?? false
  }

  /// Run synchronous AX tree work while Firefox accessibility is active.
  /// Apps outside the Firefox family pass through without locking or mutation.
  public static func withTree<T>(
    pid: pid_t,
    bundleIdentifier: String?,
    app suppliedApp: AXUIElement? = nil,
    _ operation: (AXUIElement) throws -> T
  ) rethrows -> T {
    let app = suppliedApp ?? AXApp.make(pid: pid)
    guard matches(bundleIdentifier: bundleIdentifier) else {
      return try operation(app)
    }

    let lock = locks.lock(for: pid)
    lock.lock()
    defer { lock.unlock() }

    let wasEnhanced = enhancedUserInterface(of: app)
    var role: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &role)
    defer {
      // Preserve accessibility that was already active before Flash entered
      // the scope (VoiceOver and other assistive clients may own it). Firefox
      // reports `.cannotComplete` for this setter even though it applies the
      // value, so the resulting state matters more than the return code.
      if wasEnhanced != true {
        setEnhancedUserInterface(false, on: app)
      }
    }
    return try operation(app)
  }

  /// Serialize a window operation against Firefox AX-tree work. Firefox's tree
  /// is woken long enough to resolve the target window and read its frame; the
  /// supplied callback then restores the fast geometry state immediately
  /// before the caller writes position or size.
  ///
  /// Pre-existing assistive-technology state is preserved: when accessibility
  /// was already active before Flash entered this scope, `prepareGeometry`
  /// leaves it active rather than disrupting another client.
  public static func withWindowManagement<T>(
    pid: pid_t,
    bundleIdentifier: String?,
    app suppliedApp: AXUIElement? = nil,
    _ operation: (AXUIElement, _ prepareGeometry: () -> Void) throws -> T
  ) rethrows -> T {
    guard matches(bundleIdentifier: bundleIdentifier) else {
      return try operation(suppliedApp ?? AXApp.make(pid: pid), {})
    }
    let lock = locks.lock(for: pid)
    lock.lock()
    defer { lock.unlock() }

    let app = suppliedApp ?? AXApp.make(pid: pid)
    let wasEnhanced = enhancedUserInterface(of: app)
    var role: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(app, kAXRoleAttribute as CFString, &role)
    var prepared = false
    let prepareGeometry = {
      guard !prepared else { return }
      prepared = true
      if wasEnhanced != true {
        setEnhancedUserInterface(false, on: app)
      }
    }
    defer { prepareGeometry() }
    return try operation(app, prepareGeometry)
  }

  private static func enhancedUserInterface(of app: AXUIElement) -> Bool? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        app, "AXEnhancedUserInterface" as CFString, &value) == .success,
      let value,
      CFGetTypeID(value) == CFBooleanGetTypeID()
    else { return nil }
    return CFBooleanGetValue((value as! CFBoolean))
  }

  private static func setEnhancedUserInterface(_ enabled: Bool, on app: AXUIElement) {
    _ = AXUIElementSetAttributeValue(
      app,
      "AXEnhancedUserInterface" as CFString,
      enabled ? kCFBooleanTrue : kCFBooleanFalse)
  }

  private static let locks = FirefoxAccessibilityLockStore()
}

private final class FirefoxAccessibilityLockStore: @unchecked Sendable {
  private let guardLock = NSLock()
  private var processLocks: [pid_t: NSRecursiveLock] = [:]

  func lock(for pid: pid_t) -> NSRecursiveLock {
    guardLock.lock()
    defer { guardLock.unlock() }
    if let existing = processLocks[pid] {
      return existing
    }
    let created = NSRecursiveLock()
    processLocks[pid] = created
    return created
  }
}
