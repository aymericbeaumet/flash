import Foundation

/// Static path helpers for the Firefox profile that hosts the Vimium
/// parity oracle.
///
/// The profile itself is provisioned by `Scripts/vimium-oracle.sh`
/// (downloads pinned Vimium-FF .xpi, zips + drops companion extension,
/// writes user.js, builds + signs the runner, then runs it). This
/// type only resolves paths and verifies the result is usable.
///
/// Why Firefox Developer Edition (and not release Firefox):
///   - Vimium-FF on AMO is signed (loads fine in any Firefox).
///   - The companion extension here is unsigned (would need an AMO
///     account + sign cycle for every code change — way too much
///     friction for a test harness).
///   - Release Firefox enforces signed extensions: setting
///     `xpinstall.signatures.required = false` in `user.js` is silently
///     ignored on release builds. Dev Edition and Nightly are the only
///     channels that honor the pref.
public enum OracleProfile {
  public static let appPath = "/Applications/Firefox Developer Edition.app"
  public static let bundleID = "org.mozilla.firefoxdeveloperedition"

  /// Companion extension ID — matches `browser_specific_settings.gecko.id`
  /// in `Resources/oracle-extension/manifest.json`. Firefox installs
  /// profile extensions into a file named after this ID.
  public static let companionExtensionID = "flash-oracle@flash.local"

  /// Profile directory under Application Support so it can never be
  /// confused with the user's default Firefox profile.
  public static var profileDirectory: URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    return base.appendingPathComponent(
      "Flash/firefox-oracle-profile", isDirectory: true)
  }

  public static var extensionsDirectory: URL {
    profileDirectory.appendingPathComponent("extensions", isDirectory: true)
  }

  public static var companionXPIPath: URL {
    extensionsDirectory.appendingPathComponent("\(companionExtensionID).xpi")
  }

  /// Errors surfaced when the profile is missing or misconfigured.
  public enum SetupError: Error, CustomStringConvertible {
    case browserNotInstalled(String)
    case profileMissing(URL)
    case companionMissing(URL)

    public var description: String {
      switch self {
      case .browserNotInstalled(let p):
        return """
          Firefox Developer Edition not found at \(p).
          Install from https://www.mozilla.org/en-US/firefox/developer/ — the oracle
          requires Dev Edition (or Nightly) so the unsigned companion extension can load.
          """
      case .profileMissing(let url):
        return """
          Oracle profile not found at \(url.path).
          Run ./Scripts/vimium-oracle.sh to provision it.
          """
      case .companionMissing(let url):
        return """
          Companion extension not installed at \(url.path).
          Run ./Scripts/vimium-oracle.sh to provision it.
          """
      }
    }
  }

  /// Pre-flight: verify Dev Edition is installed and the profile has
  /// been bootstrapped. Throws a `SetupError` with a remediation
  /// message when any required piece is missing.
  public static func verifyReady() throws {
    guard FileManager.default.fileExists(atPath: appPath) else {
      throw SetupError.browserNotInstalled(appPath)
    }
    let profile = profileDirectory
    guard FileManager.default.fileExists(atPath: profile.path) else {
      throw SetupError.profileMissing(profile)
    }
    let companion = companionXPIPath
    guard FileManager.default.fileExists(atPath: companion.path) else {
      throw SetupError.companionMissing(companion)
    }
  }
}
