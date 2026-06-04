import Foundation

/// The set of pages the Vimium oracle iterates over.
///
/// v1 ships only `.baselineSynthetic` — the same HTML the existing
/// `flash-firefox-e2e` runner uses. Add cases (and accompanying
/// allow-list sidecars under a `Snapshots/` resource) as the corpus
/// grows: shadowDom, iframeNested, cursorPointerDiv, svgButton,
/// ariaOnlyControls, scrolledViewport, snapshot-* real-site pages.
public enum OracleFixture: String, CaseIterable {
  case baselineSynthetic

  public var displayName: String {
    switch self {
    case .baselineSynthetic: return "baseline-synthetic"
    }
  }

  /// Raw HTML for this fixture. The runner serves it from a
  /// short-lived localhost HTTP server (`FixtureServer`) so the
  /// companion content script actually mounts — data: URLs don't run
  /// content scripts in Firefox MV2.
  public func html() -> String {
    switch self {
    case .baselineSynthetic: return FirefoxFixture.html
    }
  }

  /// Allow-list for this fixture. `nil` when no sidecar exists yet —
  /// new fixtures default to strict-ISO empty, and the runner's
  /// `--update-allow-list` flag prints suggested entries for review.
  public func allowListURL() -> URL? {
    switch self {
    case .baselineSynthetic: return nil
    }
  }

  public func loadAllowList() -> OracleAllowList {
    guard let url = allowListURL(),
      FileManager.default.fileExists(atPath: url.path)
    else { return .empty }
    return (try? OracleAllowList.load(from: url)) ?? .empty
  }
}
