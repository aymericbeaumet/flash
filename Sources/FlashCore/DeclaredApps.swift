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
/// rather than typed, pixel wheels are refused, and NORMAL's moves, motions
/// and VISUAL send no cursor keys there. `only_terminals` plugin selectors
/// match them.
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

/// Apps with their own modal editing or partial Accessibility text (manifest
/// `own_text_editing`; the bundled `defaults` plugin lists VS Code and its
/// forks, the JetBrains IDEs, Zed and Sublime Text). NORMAL never engages a
/// field there (`TextScope`): its keys keep their page meaning, `v` / `V` do
/// nothing and the text table never applies, unless
/// `[mode.apps."<bundle>".text] enabled = true` forces the app.
public enum OwnTextEditingApps {
  public static let declared = DeclaredApps()

  public static func contains(_ bundleIdentifier: String?) -> Bool {
    declared.contains(bundleIdentifier)
  }
}
