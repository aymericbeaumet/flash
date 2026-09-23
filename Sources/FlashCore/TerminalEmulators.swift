import Foundation

/// Apps that host terminal sessions. No protocol identifies a terminal
/// emulator, so plugin manifests declare them (`terminal_emulators`; the
/// bundled `terminals` plugin lists the common ones) and the host applies its
/// terminal rules to exactly those apps: an unbound Command chord is refused
/// rather than typed, pixel wheels are refused, and `only_terminals` plugin
/// selectors match them.
public enum TerminalEmulators {
  private static let lock = NSLock()
  private static var identifiers: Set<String> = []

  public static func contains(_ bundleIdentifier: String?) -> Bool {
    guard let bundleIdentifier else { return false }
    lock.lock()
    defer { lock.unlock() }
    return identifiers.contains(bundleIdentifier)
  }

  public static var all: Set<String> {
    lock.lock()
    defer { lock.unlock() }
    return identifiers
  }

  /// Replaces the declared set, as each plugin snapshot publishes.
  public static func declare(_ bundleIdentifiers: Set<String>) {
    lock.lock()
    identifiers = bundleIdentifiers
    lock.unlock()
  }
}
