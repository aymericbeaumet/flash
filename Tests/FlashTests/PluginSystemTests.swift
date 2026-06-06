import Foundation
import XCTest

@testable import flash

final class PluginSystemTests: XCTestCase {
  func testManifestLoadsRequiredFields() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "spotify",
          "name": "Spotify",
          "version": "0.1.0",
          "description": "Spotify controls",
          "install": "npm install",
          "start": "npm start",
          "events": [
            { "match": "apps.*", "bundle_ids": ["com.spotify.client"] },
            "config.*"
          ],
          "actions": [
            { "command": "spotify", "name": "pause", "description": "Pause playback" }
          ]
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    let manifest = try PluginManifest.load(from: root)
    XCTAssertEqual(manifest.id, "spotify")
    XCTAssertEqual(manifest.install, "npm install")
    XCTAssertEqual(manifest.start, "npm start")
    XCTAssertEqual(manifest.events.count, 2)
    XCTAssertEqual(manifest.actions.first?.command, "spotify")
    XCTAssertEqual(manifest.actions.first?.name, "pause")
  }

  func testManifestRejectsInvalidID() throws {
    let root = try temporaryPluginRoot(
      manifest:
        """
        {
          "id": "Spotify",
          "name": "Spotify",
          "version": "0.1.0",
          "description": "Spotify controls",
          "install": "true",
          "start": "true",
          "events": [],
          "actions": []
        }
        """)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertThrowsError(try PluginManifest.load(from: root))
  }

  func testEventSubscriptionFiltering() {
    let apps = PluginEventSubscription(
      match: "apps.*",
      bundleIDs: ["com.spotify.client"])
    XCTAssertTrue(
      apps.matches(
        PluginEvent(
          name: "apps.launched",
          payload: [:],
          bundleID: "com.spotify.client",
          configPath: nil,
          focused: false)))
    XCTAssertFalse(
      apps.matches(
        PluginEvent(
          name: "apps.launched",
          payload: [:],
          bundleID: "com.apple.Safari",
          configPath: nil,
          focused: false)))

    let config = PluginEventSubscription(match: "config.*", paths: ["plugins.*"])
    XCTAssertTrue(
      config.matches(
        PluginEvent(
          name: "config.changed",
          payload: [:],
          bundleID: nil,
          configPath: "plugins.third_party",
          focused: nil)))
    XCTAssertFalse(
      config.matches(
        PluginEvent(
          name: "config.changed",
          payload: [:],
          bundleID: nil,
          configPath: "debug.log_level",
          focused: nil)))
  }

  func testFlashLogIncludesSource() {
    var records: [FlashLog.Record] = []
    let sink = FlashLog.addSink { records.append($0) }
    defer { FlashLog.removeSink(sink) }

    FlashLog.debug("test message", source: "core:test")
    FlashLog.plugin(.info, pluginID: "spotify", message: "plugin message")

    XCTAssertEqual(records.first?.source, "core:test")
    XCTAssertEqual(records.last?.source, "plugin:spotify")
    XCTAssertTrue(FlashLog.jsonLine(records[0]).contains("\"source\":\"core:test\""))
  }

  private func temporaryPluginRoot(manifest: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-plugin-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try manifest.write(
      to: root.appendingPathComponent("manifest.json"),
      atomically: true,
      encoding: .utf8)
    return root
  }
}
