import Foundation

/// Static identifiers for the Firefox browser used by parity tests. The
/// main browser integration corpus lives under `Tests/BrowserSnapshots`
/// and is loaded through `BrowserFixtureCatalog`.
public enum FirefoxFixture {
  public static let bundleID = "org.mozilla.firefox"
}
