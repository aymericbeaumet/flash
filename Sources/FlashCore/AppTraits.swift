import AppKit

/// What an app is, read once from its bundle — the URL schemes it handles and
/// the UI runtime it embeds — never from its name. The core decides by these
/// traits; knowledge of particular apps lives in plugin data.
public struct AppTraits: Equatable, Sendable {
  /// UI runtimes that run their own accessibility lifecycle.
  public enum Engine: Equatable, Sendable {
    /// Gecko turns its accessibility on when read and, while it is on,
    /// animates programmatic window moves, so Flash scopes it to each
    /// operation (`GeckoAccessibility`).
    case gecko
    /// Chromium (Electron and CEF apps included) builds its accessibility
    /// tree only once an assistive client sets the enhanced-UI flags.
    case chromium
    /// Flutter builds its semantics tree only on the enhanced-UI flag.
    case flutter
  }

  /// Handles http and https URLs: a web browser, whose web areas are pages
  /// rather than the app's own interface.
  public var isWebBrowser: Bool
  public var engine: Engine?

  public init(isWebBrowser: Bool = false, engine: Engine? = nil) {
    self.isWebBrowser = isWebBrowser
    self.engine = engine
  }

  /// The runtime answers Accessibility only after an assistive client sets
  /// `AXEnhancedUserInterface` / `AXManualAccessibility`. Every other app —
  /// AppKit, SwiftUI, UIKit — builds its tree on demand and never gets the
  /// flags, which make window moves animate and SwiftUI apps do eager
  /// accessibility bookkeeping.
  public var needsAccessibilityWake: Bool {
    engine == .chromium || engine == .flutter
  }

  /// Traits of the app `bundleIdentifier`, cached per bundle id. The bundle is
  /// located through `pid` when the app runs, else through Launch Services.
  /// The first read of an app touches its Info.plist and bundle layout.
  public static func of(bundleIdentifier: String?, pid: pid_t? = nil) -> AppTraits {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return AppTraits() }
    cacheLock.lock()
    let cached = cache[bundleIdentifier]
    cacheLock.unlock()
    if let cached { return cached }
    let bundleURL =
      pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleURL }
      ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    let traits = bundleURL.map(Self.read(bundleURL:)) ?? AppTraits()
    cacheLock.lock()
    cache[bundleIdentifier] = traits
    cacheLock.unlock()
    return traits
  }

  /// The traits `of(bundleIdentifier:)` already read, without touching the
  /// bundle; nil when nothing has read them yet.
  public static func cached(bundleIdentifier: String?) -> AppTraits? {
    guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
    cacheLock.lock()
    defer { cacheLock.unlock() }
    return cache[bundleIdentifier]
  }

  public static func read(bundleURL: URL) -> AppTraits {
    let contents = bundleURL.appendingPathComponent("Contents")
    let frameworks = contents.appendingPathComponent("Frameworks")
    let fileManager = FileManager.default
    return AppTraits(
      isWebBrowser: handlesWebURLs(
        infoDictionary: Bundle(url: bundleURL)?.infoDictionary ?? [:]),
      engine: engine(
        hasXUL: fileManager.fileExists(atPath: contents.appendingPathComponent("MacOS/XUL").path),
        frameworks: (try? fileManager.contentsOfDirectory(atPath: frameworks.path)) ?? [],
        frameworkHelpers: { framework in
          (try? fileManager.contentsOfDirectory(
            atPath: frameworks.appendingPathComponent(framework)
              .appendingPathComponent("Helpers").path)) ?? []
        }))
  }

  /// A browser declares both web URL schemes; an app that merely links to
  /// the web declares its own scheme, if any.
  public static func handlesWebURLs(infoDictionary: [String: Any]) -> Bool {
    let types = infoDictionary["CFBundleURLTypes"] as? [[String: Any]] ?? []
    let schemes = Set(
      types.flatMap { ($0["CFBundleURLSchemes"] as? [String] ?? []).map { $0.lowercased() } })
    return schemes.isSuperset(of: ["http", "https"])
  }

  /// Gecko ships `Contents/MacOS/XUL`; Flutter its `FlutterMacOS` framework;
  /// Chromium renderer helper apps, beside its framework in an Electron app
  /// and inside the framework's `Helpers` in a browser.
  public static func engine(
    hasXUL: Bool, frameworks: [String], frameworkHelpers: (String) -> [String]
  ) -> Engine? {
    if hasXUL { return .gecko }
    if frameworks.contains("FlutterMacOS.framework") { return .flutter }
    if frameworks.contains(where: isRendererHelper) { return .chromium }
    for framework in frameworks where framework.hasSuffix(".framework") {
      if frameworkHelpers(framework).contains(where: isRendererHelper) { return .chromium }
    }
    return nil
  }

  private static func isRendererHelper(_ name: String) -> Bool {
    name.hasSuffix(" Helper (Renderer).app")
  }

  private static let cacheLock = NSLock()
  private static var cache: [String: AppTraits] = [:]
}
