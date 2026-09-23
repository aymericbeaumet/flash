import Foundation

/// A set of app bundle ids that plugin manifests declare, because no protocol
/// tells the host what they are. Each plugin snapshot replaces it whole; any
/// thread may read it.
public final class DeclaredApps: @unchecked Sendable {
  private let lock = NSLock()
  private var identifiers: Set<String> = []

  public init() {}

  public func contains(_ bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier else { return false }
    lock.lock()
    defer { lock.unlock() }
    return identifiers.contains(bundleIdentifier)
  }

  public var all: Set<String> {
    lock.lock()
    defer { lock.unlock() }
    return identifiers
  }

  public func declare(_ bundleIdentifiers: Set<String>) {
    lock.lock()
    identifiers = bundleIdentifiers
    lock.unlock()
  }
}

/// Apps that host terminal sessions (manifest `terminal_emulators`; the
/// bundled `terminals` plugin lists the common ones). The host applies its
/// terminal rules to exactly those apps: an unbound Command chord is refused
/// rather than typed, pixel wheels are refused, and `only_terminals` plugin
/// selectors match them.
public enum TerminalEmulators {
  public static let declared = DeclaredApps()

  public static func contains(_ bundleIdentifier: String?) -> Bool {
    declared.contains(bundleIdentifier)
  }
}

/// Apps whose accessibility tree costs too much to warm in the background
/// (manifest `on_demand_hints`): Flash walks them only when hints are asked
/// for and observes only the notifications that drive mode, border and focus.
public enum OnDemandHintApps {
  public static let declared = DeclaredApps()

  public static func contains(_ bundleIdentifier: String?) -> Bool {
    declared.contains(bundleIdentifier)
  }
}
