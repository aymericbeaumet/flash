import CryptoKit
import FlashCore
import Foundation

/// A release version, `MAJOR.MINOR.PATCH` with any number of numeric
/// components and an optional leading `v`. Anything else (a nightly tag, a
/// prerelease suffix) is no version the updater compares.
struct SemanticVersion: Comparable, CustomStringConvertible, Hashable {
  let components: [Int]

  init?(_ raw: String) {
    let text = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...4).contains(parts.count) else { return nil }
    var components: [Int] = []
    for part in parts {
      guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
        let value = Int(part)
      else { return nil }
      components.append(value)
    }
    self.components = components
  }

  var description: String { components.map(String.init).joined(separator: ".") }

  /// `1.2` equals `1.2.0`.
  static func == (lhs: Self, rhs: Self) -> Bool { compare(lhs, rhs) == 0 }
  static func < (lhs: Self, rhs: Self) -> Bool { compare(lhs, rhs) < 0 }

  func hash(into hasher: inout Hasher) {
    var trimmed = components
    while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
    hasher.combine(trimmed)
  }

  private static func compare(_ lhs: Self, _ rhs: Self) -> Int {
    for index in 0..<max(lhs.components.count, rhs.components.count) {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right { return left < right ? -1 : 1 }
    }
    return 0
  }
}

/// The newest stable release as GitHub's releases API describes it: the one
/// asset the updater installs, with the SHA-256 GitHub computed for it.
struct UpdateRelease: Codable, Equatable {
  static let repository = "aymericbeaumet/flash"
  static let latestURL = URL(
    string: "https://api.github.com/repos/\(repository)/releases/latest")!

  var version: String
  var assetName: String
  var downloadURL: URL
  /// Lowercase hex.
  var sha256: String
  var size: Int
  var pageURL: URL?

  var semanticVersion: SemanticVersion? { SemanticVersion(version) }

  /// The asset `Scripts/build.sh --release` publishes for `version`.
  static func assetName(for version: String) -> String { "Flash-\(version).zip" }

  enum ParseError: Error, Equatable, CustomStringConvertible {
    case malformed
    case notStable(String)
    case noVersion(String)
    case noAsset(String)
    case noDigest(String)

    var description: String {
      switch self {
      case .malformed: return "GitHub's answer is not a release"
      case .notStable(let tag): return "release \(tag) is a draft or a prerelease"
      case .noVersion(let tag): return "release tag \(tag) is not a version"
      case .noAsset(let name): return "the release has no \(name) asset"
      case .noDigest(let name): return "GitHub publishes no SHA-256 digest for \(name)"
      }
    }
  }

  /// `GET /repos/<repo>/releases/latest`. GitHub already skips drafts and
  /// prereleases there; both are refused again, as is a release without the
  /// expected asset or its `sha256:` digest, which the download must match.
  static func parse(latest data: Data) -> Result<UpdateRelease, ParseError> {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tag = object["tag_name"] as? String
    else { return .failure(.malformed) }
    if object["draft"] as? Bool == true || object["prerelease"] as? Bool == true {
      return .failure(.notStable(tag))
    }
    guard SemanticVersion(tag) != nil, !tag.hasPrefix("v") else {
      return .failure(.noVersion(tag))
    }
    let name = assetName(for: tag)
    let assets = object["assets"] as? [[String: Any]] ?? []
    guard let asset = assets.first(where: { $0["name"] as? String == name }),
      let rawURL = asset["browser_download_url"] as? String,
      let url = URLParsing.url(rawURL), url.scheme == "https"
    else { return .failure(.noAsset(name)) }
    guard let digest = asset["digest"] as? String, let sha256 = Self.sha256(digest: digest) else {
      return .failure(.noDigest(name))
    }
    return .success(
      UpdateRelease(
        version: tag, assetName: name,
        downloadURL: url, sha256: sha256, size: asset["size"] as? Int ?? 0,
        pageURL: (object["html_url"] as? String).flatMap(URL.init(string:))))
  }

  /// `sha256:<64 hex>` → the lowercase hex; nil for any other digest.
  static func sha256(digest: String) -> String? {
    let prefix = "sha256:"
    guard digest.hasPrefix(prefix) else { return nil }
    let hex = digest.dropFirst(prefix.count).lowercased()
    guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
    return String(hex)
  }

  /// The SHA-256 of the file at `url`, read in 1 MiB chunks; nil when it
  /// cannot be read.
  static func sha256(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var hasher = SHA256()
    do {
      // `read(upToCount:)` answers nil (or empty data) at the end of the file.
      while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
      }
    } catch {
      return nil
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// `[app] updates`: what Flash does about new releases on its own. The
/// `updates` commands and the About window work whatever it says.
enum UpdateMode: String, CaseIterable, Equatable {
  /// Check daily, download and verify a new release, and install it when
  /// that keeps Flash's permissions (a Developer ID build) at a moment that
  /// interrupts nothing; any other build is told the release is ready.
  case install
  /// Check daily and say when a release is out.
  case check
  /// Never look by itself.
  case off
}

/// Who signed the running Flash, which decides whether an update can be
/// installed and whether macOS keeps its permissions afterwards. TCC ties
/// Accessibility to the code signature: a Developer ID build keeps it across
/// releases signed by the same team, an ad-hoc build loses it with every
/// new binary.
enum BuildIdentity: Equatable {
  /// Signed with a Developer ID certificate of `team`.
  case developerID(team: String)
  /// Ad-hoc signed, as releases are until Developer ID signing is set up.
  case adHoc
  /// Signed with another certificate: the stable "Flash Dev" identity of
  /// `mise run install:dev`, or one of your own.
  case certificate(String)
  /// Not running from an app bundle (`swift run`, tests).
  case notBundled
  case unsigned

  enum Installability: Equatable {
    /// Installs on its own; macOS keeps Flash's permissions.
    case keepsPermissions
    /// Installs when you ask: macOS asks for Accessibility again.
    case resetsPermissions
    case never(String)
  }

  var installability: Installability {
    switch self {
    case .developerID: return .keepsPermissions
    case .adHoc: return .resetsPermissions
    case .certificate(let name):
      return .never(
        "this build is signed by \(name), not by a release: rebuild it the way it was installed "
          + "(mise run install:dev for a development build)")
    case .notBundled: return .never("Flash is not running from an app bundle")
    case .unsigned: return .never("this build is not signed")
    }
  }

  /// Whether Flash looks for releases by itself: a build no release can
  /// replace never checks.
  var checksAutomatically: Bool {
    if case .never = installability { return false }
    return true
  }
}

/// What a check found, for the CLI, the command line and the About window.
struct UpdateCheckReport: Equatable {
  enum Status: Equatable {
    case upToDate
    case available(UpdateRelease)
    /// Downloaded and verified, waiting to be installed.
    case ready(UpdateRelease)
    case failed(String)
  }

  var current: String
  var status: Status
  var identity: BuildIdentity
  var mode: UpdateMode

  var succeeded: Bool {
    if case .failed = status { return false }
    return true
  }

  /// The release `updates install` would install, when it can.
  var installable: UpdateRelease? {
    if case .never = identity.installability { return nil }
    switch status {
    case .available(let release), .ready(let release): return release
    case .upToDate, .failed: return nil
    }
  }

  var text: String {
    switch status {
    case .failed(let reason):
      return "Could not check for updates: \(reason)."
    case .upToDate:
      return "Flash \(current) is up to date."
    case .available(let release), .ready(let release):
      var lines = ["Flash \(release.version) is available (this is \(current))."]
      let ready: Bool = {
        if case .ready = status { return true }
        return false
      }()
      switch identity.installability {
      case .keepsPermissions:
        if ready, mode == .install {
          lines.append(
            "It is downloaded and installs when you quit Flash or lock the screen; "
              + "updates install installs it now.")
        } else {
          lines.append("updates install installs it now.")
        }
      case .resetsPermissions:
        lines.append(
          "updates install installs it. This build has no Developer ID signature, so macOS "
            + "asks you to allow Flash in Accessibility again afterwards.")
      case .never(let reason):
        lines.append("Flash cannot install it: \(reason).")
      }
      return lines.joined(separator: "\n")
    }
  }

  /// One line, for a banner and the About window.
  var summary: String { text.split(separator: "\n").first.map(String.init) ?? text }
}

/// When a downloaded update may replace the running Flash without asking:
/// only a build that keeps its permissions, with `[app] updates =
/// "install"`, and only while nothing is in the user's hands.
enum UpdateApplyPolicy {
  enum Trigger: Equatable {
    /// The screen locked or the displays went to sleep: nobody is typing.
    case away
    /// Flash is quitting; the next launch runs the new version.
    case quit
  }

  struct Activity: Equatable {
    var hintSession = false
    var popup = false
    var commandLine = false
    var holdingButton = false

    var isIdle: Bool { !hintSession && !popup && !commandLine && !holdingButton }
  }

  static func appliesAutomatically(
    _ trigger: Trigger, mode: UpdateMode, identity: BuildIdentity, activity: Activity
  ) -> Bool {
    guard mode == .install, identity.installability == .keepsPermissions else { return false }
    switch trigger {
    case .quit: return true
    case .away: return activity.isIdle
    }
  }

  /// The next check: a day after a completed one, an hour after a failure.
  static func nextCheckDelayMs(succeeded: Bool) -> Int {
    succeeded ? 24 * 3_600_000 : 3_600_000
  }
}

/// What the updater keeps between launches in `Updates/state.json`.
struct UpdateState: Codable, Equatable {
  /// GitHub's ETag for the last `releases/latest` answer, sent back as
  /// `If-None-Match` so an unchanged answer costs no rate limit.
  var etag: String?
  var latest: UpdateRelease?
  var checkedAt: Date?
  /// The version staged under `Updates/<version>/Flash.app`, verified.
  var staged: String?
  /// The last version announced, so each release is announced once.
  var announced: String?
  /// Set just before the swap; the new instance greets it once and clears it.
  var installed: String?
}
