import Foundation

/// The surfaces a plugin can drive through the unified provider system.
/// Each is registered the same way — a `providers[]` entry in the manifest —
/// gated by the same optional ``ProviderConditions`` and ordered by priority.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
  case hints
  case candidates
  case commands
  case mappings
  /// Status-bar template segments. Plugins declare stable segment names in
  /// `providers[]`, then publish values at runtime over the plugin protocol.
  case status
  /// Flashlight `!`-prefix bangs (DuckDuckGo-style): a submission beginning
  /// with `!<token>` routes its remainder to the owning plugin instead of
  /// resolving a candidate.
  case shebang
  /// Discrete source actions such as `tab_new`, `app_reload`, or
  /// `resource_archive`. These are declared separately from candidates so a
  /// generic candidate plugin is not consulted for browser/tmux key actions.
  case sourceActions = "source_actions"
  /// Movement-history route restoration. A provider declares URL schemes in
  /// `schemes[]`; plugins can emit matching `navigation_url` values from
  /// candidates, commands, or source actions.
  case navigation
  /// Top-level verbs the plugin owns. Each entry registers a `flash <verb>`
  /// callable from CLI and from `[mode.*.mappings]`. The owning plugin handles
  /// the dispatch via `command.invoke`; an entry may also declare an
  /// `inline_keystrokes` per-bundle table that the host translates into an
  /// `input.send_key` directly, avoiding the RPC round-trip on hot-path
  /// keystroke verbs (`app_save`, `app_print`, …).
  case verbs
}

/// Editor mode a provider can be gated to. The empty set (no `modes` declared)
/// means "every mode" — `all` is expressed as the absence of constraints, not
/// a member here. Mirrors the runtime modes the host exposes.
public enum ProviderMode: String, Codable, Sendable, CaseIterable {
  case normal
  case insert
}

/// Optional activation gates shared by every provider kind. Both axes are
/// "empty = unconditional": an empty `bundleIDs` matches any focused app, an
/// empty `modes` matches any mode. A provider is active for a (focused app,
/// mode) pair only when both axes admit it. This is the single, symmetric
/// conditions vocabulary the core evaluates regardless of ``ProviderKind``.
public struct ProviderConditions: Equatable, Sendable {
  public var bundleIDs: Set<String>
  public var modes: Set<ProviderMode>

  public init(bundleIDs: Set<String> = [], modes: Set<ProviderMode> = []) {
    self.bundleIDs = bundleIDs
    self.modes = modes
  }

  /// True when no gate is set, so the provider runs everywhere.
  public var isUnconditional: Bool { bundleIDs.isEmpty && modes.isEmpty }

  /// Whether this provider should run for the given focused app / mode. A
  /// `nil` argument means the caller can't constrain that axis: when a gate is
  /// set on an axis the caller can't supply, the provider is excluded (a gated
  /// provider never runs in an unknown context).
  public func matches(bundleID: String?, mode: ProviderMode? = nil) -> Bool {
    if !bundleIDs.isEmpty {
      guard let bundleID, bundleIDs.contains(bundleID) else { return false }
    }
    if !modes.isEmpty {
      guard let mode, modes.contains(mode) else { return false }
    }
    return true
  }
}
