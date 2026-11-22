import FlashCore
import Foundation
import XCTest

@testable import flash

extension BrowserEngineTable {
  /// One browser or more of each engine, for tests that decide by engine
  /// without loading the bundled manifests.
  static let sample = BrowserEngineTable([
    "com.google.Chrome": .chromium, "com.brave.Browser": .chromium,
    "com.apple.Safari": .webkit,
    "org.mozilla.firefox": .gecko, "org.mozilla.firefoxdeveloperedition": .gecko,
    "org.mozilla.nightly": .gecko,
  ])
}

/// Which apps are browsers, and of which engine, is manifest data
/// (`browser_engines`): the host names no browser.
final class BrowserEnginesTests: XCTestCase {
  private static let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private func load(_ fields: String) throws -> PluginManifest {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-browser-engines-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    try """
    {
      "id": "sample",
      "name": "Sample",
      "version": "1.0.0",
      "description": "fixture",
      \(fields)
    }
    """.write(to: root.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    return try PluginManifest.load(from: root)
  }

  private func failure(_ fields: String) -> String {
    do {
      _ = try load(fields)
      return ""
    } catch {
      return String(describing: error)
    }
  }

  func testAManifestDeclaresBrowsersByEngine() throws {
    let manifest = try load(
      """
      "browser_engines": {
        "chromium": ["com.example.Chromium", "com.example.Fork"],
        "webkit": ["com.example.WebKit"],
        "gecko": ["com.example.Gecko"]
      }
      """)
    XCTAssertEqual(
      manifest.browserEngines,
      BrowserEngineTable([
        "com.example.Chromium": .chromium, "com.example.Fork": .chromium,
        "com.example.WebKit": .webkit, "com.example.Gecko": .gecko,
      ]))
    XCTAssertEqual(manifest.browserEngines.engine(of: "com.example.Fork"), .chromium)
    XCTAssertNil(manifest.browserEngines.engine(of: "com.example.fork"), "bundle ids are exact")
    XCTAssertNil(manifest.browserEngines.engine(of: nil))
    XCTAssertEqual(try load(#""mappings": []"#).browserEngines, BrowserEngineTable())
  }

  func testAMalformedDeclarationFailsTheLoad() {
    XCTAssertTrue(
      failure(#""browser_engines": {"blink": ["com.example.App"]}"#)
        .contains("browser_engines: blink is not an engine (chromium, webkit, gecko)"))
    XCTAssertTrue(
      failure(#""browser_engines": {"chromium": ["com.example.App\" & say"]}"#)
        .contains("browser_engines.chromium: not a bundle id"))
    XCTAssertTrue(
      failure(
        #""browser_engines": {"chromium": ["com.example.App"], "gecko": ["com.example.App"]}"#
      )
      .contains("browser_engines: com.example.App is declared twice"))
    XCTAssertTrue(
      failure(#""browser_engines": {"chromium": ["com.example.App", "com.example.App"]}"#)
        .contains("browser_engines: com.example.App is declared twice"))
    XCTAssertFalse(failure(#""browser_engines": ["com.example.App"]"#).isEmpty)
  }

  /// Every browser a bundled plugin drives through AppleScript, or scopes
  /// itself to, has its engine in the bundled declarations.
  func testTheBundledManifestsDeclareEveryBrowserTheyDrive() throws {
    let plugins = Self.repository.appendingPathComponent("Plugins")
    let defaults = try PluginManifest.load(from: plugins.appendingPathComponent("defaults"))
    let browsers = try PluginManifest.load(from: plugins.appendingPathComponent("browsers"))
    let table = defaults.browserEngines
    XCTAssertFalse(browsers.appleEventsTargets.isEmpty)
    for bundleID in browsers.appleEventsTargets {
      let engine = table.engine(of: bundleID)
      XCTAssertTrue(engine == .chromium || engine == .webkit, bundleID)
    }
    for bundleID in browsers.selector.onlyBundleIDs {
      XCTAssertNotNil(table.engine(of: bundleID), bundleID)
    }
    XCTAssertEqual(table.engine(of: "com.apple.Safari"), .webkit)
    XCTAssertEqual(table.engine(of: "org.mozilla.firefox"), .gecko)
    XCTAssertEqual(table.engine(of: "com.operasoftware.OperaGX"), .chromium)
    for other in try FileManager.default.contentsOfDirectory(atPath: plugins.path).sorted()
    where other != "defaults" {
      let root = plugins.appendingPathComponent(other)
      guard
        FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path)
      else { continue }
      XCTAssertEqual(
        try PluginManifest.load(from: root).browserEngines, BrowserEngineTable(),
        "\(other): the defaults plugin holds the one bundled table")
    }
  }

  func testTheDeclaredTableIsReplacedWhole() {
    let previous = BrowserEngines.declared.table
    defer { BrowserEngines.declared.declare(previous) }
    BrowserEngines.declared.declare(BrowserEngineTable(["com.example.One": .gecko]))
    XCTAssertEqual(BrowserEngines.declared.table.engine(of: "com.example.One"), .gecko)
    BrowserEngines.declared.declare(BrowserEngineTable(["com.example.Two": .webkit]))
    XCTAssertNil(BrowserEngines.declared.table.engine(of: "com.example.One"))
  }
}
