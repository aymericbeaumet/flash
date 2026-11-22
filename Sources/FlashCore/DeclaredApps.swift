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

/// The engine a browser is built on, which decides how the host addresses it:
/// its AppleScript dictionary, and how a stuck secure-input hold is released.
public enum BrowserEngine: String, CaseIterable, Sendable {
  case chromium, webkit, gecko
}

/// Browsers by bundle id, with their engine (manifest `browser_engines`).
public struct BrowserEngineTable: Equatable, Sendable {
  public private(set) var engines: [String: BrowserEngine]

  public init(_ engines: [String: BrowserEngine] = [:]) {
    self.engines = engines
  }

  public var isEmpty: Bool { engines.isEmpty }

  /// Nil for an app no plugin declares as a browser. Bundle ids are exact.
  public func engine(of bundleIdentifier: String?) -> BrowserEngine? {
    bundleIdentifier.flatMap { engines[$0] }
  }

  /// Adds the browsers `other` declares; one already declared keeps its engine.
  public mutating func merge(_ other: BrowserEngineTable) {
    engines.merge(other.engines) { declared, _ in declared }
  }
}

/// The browsers plugin manifests declare. Each plugin snapshot replaces the
/// table whole; any thread may read it.
public final class DeclaredBrowserEngines: @unchecked Sendable {
  private let lock = NSLock()
  private var current = BrowserEngineTable()

  public init() {}

  public var table: BrowserEngineTable {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  public func declare(_ table: BrowserEngineTable) {
    lock.lock()
    current = table
    lock.unlock()
  }
}

/// Which apps are browsers and what engine each runs (manifest
/// `browser_engines`; the bundled `defaults` plugin lists the common ones).
/// The host names no browser: `host.applescript` serves its browser
/// operations to exactly these apps, in the engine's dialect, and a stuck
/// secure-input hold is released the way the holder's engine allows.
public enum BrowserEngines {
  public static let declared = DeclaredBrowserEngines()
}
