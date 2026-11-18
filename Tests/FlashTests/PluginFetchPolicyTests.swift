import Foundation
import XCTest

@testable import flash

/// What a manifest lets `host.fetch` reach and within which bounds:
/// `fetch_urls`, `fetch_settings` and `fetch_limits`.
final class PluginFetchPolicyTests: XCTestCase {
  private static let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private func load(_ fields: String) throws -> PluginManifest {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-fetch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    try """
    {
      "id": "sample", "name": "Sample", "version": "1.0.0", "description": "fixture",
      "exec": ["/usr/bin/true"], "sandbox": false, "status": ["state"],
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

  private let feed =
    #""settings": {"url": {"type": "string", "description": "The feed."}, "#
    + #""n": {"type": "integer", "description": "A number."}}"#

  /// A URL the user chooses is a declared string setting the manifest names.
  func testFetchSettingsNameDeclaredStrings() throws {
    let manifest = try load(
      #""capabilities": ["network_fetch"], "fetch_settings": [" url ", "url"], "# + feed)
    XCTAssertEqual(manifest.fetchSettings, ["url"])
    XCTAssertEqual(manifest.fetchURLs, [], "the setting alone carries the capability")
    XCTAssertEqual(manifest.settings["url"]?.fetchURL, true)
    XCTAssertEqual(manifest.settings["n"]?.fetchURL, false)

    for (fields, message) in [
      (
        #""capabilities": ["network_fetch"], "fetch_settings": ["n"], "# + feed,
        "fetch_settings names n, which settings does not declare as a string"
      ),
      (
        #""capabilities": ["network_fetch"], "fetch_settings": ["missing"], "# + feed,
        "fetch_settings names missing, which settings does not declare as a string"
      ),
      (
        #""fetch_settings": ["url"], "# + feed,
        "network_fetch capability comes with fetch_urls or fetch_settings, and only with them"
      ),
      (
        #""capabilities": ["network_fetch"]"#,
        "network_fetch capability comes with fetch_urls or fetch_settings, and only with them"
      ),
    ] {
      let error = failure(fields)
      XCTAssertTrue(error.contains(message), "\(fields): \(error)")
    }
  }

  /// The allowlist is the manifest's prefixes and the URL each named setting
  /// holds; a value the host would not fetch adds nothing.
  func testTheAllowlistIsThePrefixesAndTheURLsTheSettingsHold() throws {
    let manifest = try load(
      #""capabilities": ["network_fetch"], "fetch_urls": ["https://api.example.com/"], "#
        + #""fetch_settings": ["url"], "# + feed)
    XCTAssertEqual(
      manifest.fetchAllowlist(settings: ["url": .string("https://news.example.org/feed.xml")]),
      ["https://api.example.com/", "https://news.example.org/feed.xml"])
    for value: PluginConfigValue in [
      .string(""), .string("http://news.example.org/feed.xml"),
      .string("https://user:secret@news.example.org/feed.xml"), .string("news.example.org"),
      .int(1),
    ] {
      XCTAssertEqual(
        manifest.fetchAllowlist(settings: ["url": value]), ["https://api.example.com/"],
        "\(value)")
    }
    XCTAssertEqual(manifest.fetchAllowlist(settings: [:]), ["https://api.example.com/"])
  }

  /// The loader says so when a setting the host fetches is not an HTTPS URL.
  func testASettingTheHostFetchesTakesAnHTTPSURL() throws {
    let declared = try load(
      #""capabilities": ["network_fetch"], "fetch_settings": ["url"], "# + feed
    ).settings
    for value in ["https://news.example.org/feed.xml", "https://example.org/a?b=c", ""] {
      XCTAssertNil(
        PluginSettings.problem(key: "url", value: .string(value), declared: declared), value)
    }
    for value in [
      "http://news.example.org/feed.xml", "https://user:secret@example.org/", "example.org",
      "file:///tmp/feed.xml",
    ] {
      XCTAssertEqual(
        PluginSettings.problem(key: "url", value: .string(value), declared: declared),
        .invalid(requirement: "must be an https:// URL without credentials"), value)
    }
    XCTAssertEqual(
      ConfigSchema.setting(try XCTUnwrap(declared["url"]))["pattern"] as? String,
      #"^(https://\S+)?$"#)
    XCTAssertNil(ConfigSchema.setting(try XCTUnwrap(declared["n"]))["pattern"])
  }

  /// The loader checks a bundled plugin's table against the same rule.
  func testTheLoaderChecksABundledPluginsFetchSetting() throws {
    let catalog = PluginSettingsCatalog.bundled(roots: [
      Self.repository.appendingPathComponent("Plugins/feed")
    ])
    XCTAssertEqual(catalog.declared["feed"]?["url"]?.fetchURL, true)
    XCTAssertEqual(catalog.declared["feed"]?["refresh_interval"]?.fetchURL, false)
  }

  /// A manifest raises or lowers the bounds of a response, under the host's
  /// ceilings.
  func testFetchLimitsStayUnderTheHostsCeilings() throws {
    let fetching = #""capabilities": ["network_fetch"], "fetch_urls": ["https://example.com/"]"#
    XCTAssertNil(try load(fetching).fetchLimits)
    XCTAssertEqual(
      try load(fetching).effectiveFetchLimits,
      PluginFetchLimits(
        maxBytes: PluginProtocol.maxFetchResponseBytes, timeoutMs: PluginProtocol.fetchTimeoutMs))
    XCTAssertEqual(
      try load(fetching + #", "fetch_limits": {"max_bytes": 4194304, "timeout_ms": 30000}"#)
        .effectiveFetchLimits,
      PluginFetchLimits(
        maxBytes: PluginProtocol.fetchResponseBytesCeiling,
        timeoutMs: PluginProtocol.fetchTimeoutMsCeiling))
    XCTAssertEqual(
      try load(fetching + #", "fetch_limits": {"max_bytes": 2048}"#).effectiveFetchLimits,
      PluginFetchLimits(maxBytes: 2048, timeoutMs: PluginProtocol.fetchTimeoutMs))

    for (limits, message) in [
      (#"{"max_bytes": 4194305}"#, "fetch_limits.max_bytes must be 1 to 4194304"),
      (#"{"max_bytes": 0}"#, "fetch_limits.max_bytes must be 1 to 4194304"),
      (#"{"timeout_ms": 30001}"#, "fetch_limits.timeout_ms must be 1 to 30000"),
      (#"{"timeout_ms": 0}"#, "fetch_limits.timeout_ms must be 1 to 30000"),
      (#"{"bytes": 1}"#, "manifest.json fetch_limits unknown field bytes"),
      (#"{}"#, "fetch_limits must set max_bytes or timeout_ms"),
    ] {
      let error = failure(fetching + #", "fetch_limits": \#(limits)"#)
      XCTAssertTrue(error.contains(message), "\(limits): \(error)")
    }
    XCTAssertTrue(
      failure(#""fetch_limits": {"max_bytes": 2048}"#)
        .contains("fetch_limits needs the network_fetch capability"))
  }

  /// No bundled plugin opens a socket of its own: what they fetch, the host
  /// fetches, from the destinations their manifests name.
  func testNoBundledPluginHoldsTheNetworkCapability() throws {
    let plugins = Self.repository.appendingPathComponent("Plugins")
    var fetching: [String: [String]] = [:]
    for root in try FileManager.default.contentsOfDirectory(
      at: plugins, includingPropertiesForKeys: nil)
    where FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path)
      && !root.lastPathComponent.hasPrefix("_")
    {
      let manifest = try PluginManifest.load(from: root)
      XCTAssertFalse(manifest.capabilities.contains(.network), manifest.id)
      if manifest.capabilities.contains(.networkFetch) {
        fetching[manifest.id] = manifest.fetchURLs + manifest.fetchSettings.map { "setting \($0)" }
      }
    }
    XCTAssertEqual(
      fetching,
      [
        "answers": ["https://www.ecb.europa.eu/"],
        "feed": ["setting url"],
        "searchproviders": ["https://duckduckgo.com/bang.js"],
      ])
  }
}
