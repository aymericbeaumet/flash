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
  case example
  case hackerNews
  case wikipedia
  case mdn
  case githubExplore
  case stackoverflow
  case reddit
  case ahrefsBlog
  case yCombinatorAbout

  public var displayName: String {
    switch self {
    case .baselineSynthetic: return "baseline-synthetic"
    case .example: return "example"
    case .hackerNews: return "hacker-news"
    case .wikipedia: return "wikipedia"
    case .mdn: return "mdn"
    case .githubExplore: return "github-explore"
    case .stackoverflow: return "stackoverflow"
    case .reddit: return "reddit"
    case .ahrefsBlog: return "ahrefs-blog"
    case .yCombinatorAbout: return "ycombinator-about"
    }
  }

  /// Raw HTML for this fixture. Synthetic fixtures are inlined as
  /// Swift strings; real-page snapshots are loaded from
  /// `Sources/FlashE2EKit/Snapshots/` via `Bundle.module`. The runner
  /// serves whichever HTML this returns from a short-lived localhost
  /// HTTP server (data: and file: URLs don't run content scripts
  /// reliably in Firefox MV2).
  public func html() -> String {
    switch self {
    case .baselineSynthetic: return FirefoxFixture.html
    case .example: return Self.loadSnapshot("example")
    case .hackerNews: return Self.loadSnapshot("hn")
    case .wikipedia: return Self.loadSnapshot("wikipedia")
    case .mdn: return Self.loadSnapshot("mdn")
    case .githubExplore: return Self.loadSnapshot("github-explore")
    case .stackoverflow: return Self.loadSnapshot("stackoverflow")
    case .reddit: return Self.loadSnapshot("reddit")
    case .ahrefsBlog: return Self.loadSnapshot("ahrefs-blog")
    case .yCombinatorAbout: return Self.loadSnapshot("ycombinator-about")
    }
  }

  /// Allow-list for this fixture. `nil` when no sidecar exists yet —
  /// new fixtures default to strict-ISO empty, and the runner's
  /// `--update-allow-list` flag prints suggested entries for review.
  public func allowListURL() -> URL? {
    nil
  }

  public func loadAllowList() -> OracleAllowList {
    guard let url = allowListURL(),
      FileManager.default.fileExists(atPath: url.path)
    else { return .empty }
    return (try? OracleAllowList.load(from: url)) ?? .empty
  }

  private static func loadSnapshot(_ name: String) -> String {
    guard
      let url = Bundle.module.url(
        forResource: name, withExtension: "html", subdirectory: "Snapshots"),
      let data = try? Data(contentsOf: url),
      let s = String(data: data, encoding: .utf8)
    else {
      return "<html><body>missing snapshot: \(name).html</body></html>"
    }
    return s
  }
}
