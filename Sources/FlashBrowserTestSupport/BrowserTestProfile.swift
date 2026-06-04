import Foundation

/// Static path helpers for the Firefox profile used by browser parity
/// tests. The profile template is provisioned by
/// `Scripts/test-integration-browser.sh`; each parallel worker copies it
/// into an isolated profile directory before launching Firefox.
public enum BrowserTestProfile {
  public static let releaseAppPath = "/Applications/Firefox.app"
  public static let developerEditionAppPath = "/Applications/Firefox Developer Edition.app"
  public static let releaseBundleID = "org.mozilla.firefox"
  public static let developerEditionBundleID = "org.mozilla.firefoxdeveloperedition"

  public static func defaultAppPath(
    environment: [String: String] = ProcessInfo.processInfo.environment
  )
    -> String
  {
    if let override = environment["FLASH_BROWSER_FIREFOX_APP"], !override.isEmpty {
      return override
    }
    if FileManager.default.fileExists(atPath: releaseAppPath) {
      return releaseAppPath
    }
    return developerEditionAppPath
  }

  /// Profile template under Application Support so it can never be
  /// confused with the user's default Firefox profile.
  public static var templateDirectory: URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    return base.appendingPathComponent(
      "Flash/firefox-browser-test-profile", isDirectory: true)
  }

  public static var workerRootDirectory: URL {
    let base = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    return base.appendingPathComponent(
      "Flash/firefox-browser-test-workers", isDirectory: true)
  }

  public static var extensionsDirectory: URL {
    templateDirectory.appendingPathComponent("extensions", isDirectory: true)
  }

  public static let vimiumExtensionID = "{d7742d87-e61d-4b78-b8a1-b469842139fa}"

  public static var vimiumXPIPath: URL {
    extensionsDirectory.appendingPathComponent("\(vimiumExtensionID).xpi")
  }

  public static func workerProfileDirectory(workerID: Int) -> URL {
    workerRootDirectory.appendingPathComponent("worker-\(workerID)", isDirectory: true)
  }

  public static func prepareWorkerProfile(workerID: Int) throws -> URL {
    let fm = FileManager.default
    let profile = workerProfileDirectory(workerID: workerID)
    try? fm.removeItem(at: profile)
    try fm.createDirectory(
      at: profile.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try fm.copyItem(at: templateDirectory, to: profile)
    for name in [".parentlock", "lock", "parent.lock", "MarionetteActivePort"] {
      try? fm.removeItem(at: profile.appendingPathComponent(name))
    }
    return profile
  }

  public enum SetupError: Error, CustomStringConvertible {
    case browserNotInstalled(String)
    case profileMissing(URL)
    case vimiumMissing(URL)

    public var description: String {
      switch self {
      case .browserNotInstalled(let p):
        return """
          Firefox not found at \(p).
          Install Firefox, or set FLASH_BROWSER_FIREFOX_APP to a Firefox-family .app path.
          """
      case .profileMissing(let url):
        return """
          Browser test profile template not found at \(url.path).
          Run ./Scripts/test-integration-browser.sh to provision it.
          """
      case .vimiumMissing(let url):
        return """
          Vimium-FF XPI not installed at \(url.path).
          Run ./Scripts/test-integration-browser.sh to provision it.
          """
      }
    }
  }

  public static func verifyReady(
    appPath: String = defaultAppPath()
  ) throws {
    guard FileManager.default.fileExists(atPath: appPath) else {
      throw SetupError.browserNotInstalled(appPath)
    }
    let profile = templateDirectory
    guard FileManager.default.fileExists(atPath: profile.path) else {
      throw SetupError.profileMissing(profile)
    }
    let vimium = vimiumXPIPath
    guard FileManager.default.fileExists(atPath: vimium.path) else {
      throw SetupError.vimiumMissing(vimium)
    }
  }
}
