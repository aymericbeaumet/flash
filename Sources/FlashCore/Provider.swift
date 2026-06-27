import Foundation

/// Editor mode a provider can be gated to. The empty set (no `modes` declared)
/// means "every mode" — `all` is expressed as the absence of constraints, not
/// a member here. Mirrors the runtime modes the host exposes.
public enum ProviderMode: String, Codable, Sendable, CaseIterable {
  case normal
  case insert
}

/// Optional activation gates shared by plugin manifest provider sections. Both
/// axes are "empty = unconditional": an empty `bundleIDs` matches any focused
/// app, an empty `modes` matches any mode. A provider section is active for a
/// (focused app, mode) pair only when both axes admit it.
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
