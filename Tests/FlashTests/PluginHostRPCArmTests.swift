import Carbon.HIToolbox
import Foundation
import XCTest

@testable import flash

/// Every arm of the plugin→host RPC surface, driven through
/// `handleHostRequest` with synthetic capability sets. Side-effecting arms
/// go through the closure/static seams (urlOpener, appOpener,
/// mediaKeyPoster, signalSender, onNotifyRequested, onSyntheticKeysRequested,
/// onGlobalSyntheticKeyRequested, onNormalModeTargetRequested) — no test
/// here ever opens a browser, posts a HID event, signals a process, or
/// touches the clipboard.
final class PluginHostRPCArmTests: XCTestCase {

  // MARK: - Plumbing

  private func protocolSpec() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Plugins/_flash_plugin_specs/protocol.json")
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  /// Synchronously collect one `handleHostRequest` reply (replies may hop
  /// through main, the storage queue, or the AX broker queue).
  private func hostReply(
    _ rpc: PluginHostRPC,
    _ method: String,
    _ params: [String: Any],
    pluginID: String = "rpctest",
    capabilities: Set<PluginCapability> = [],
    fetchURLs: [String] = [],
    dataDir: URL? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> [String: Any] {
    let lock = NSLock()
    var reply: [String: Any] = [:]
    let replied = expectation(description: method)
    rpc.handleHostRequest(
      method: method,
      params: params,
      pluginID: pluginID,
      capabilities: capabilities,
      fetchURLs: fetchURLs,
      dataDir: dataDir
    ) { result in
      lock.lock()
      reply = result
      lock.unlock()
      replied.fulfill()
    }
    wait(for: [replied], timeout: 5)
    lock.lock()
    defer { lock.unlock() }
    return reply
  }

  private func temporaryDataDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-rpc-data-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  // MARK: - Capability gate, table-driven from protocol.json

  func testEveryCapabilityGatedArmRepliesTheExactCanonicalDenial() throws {
    let methods = try XCTUnwrap(
      (try protocolSpec()["methods"] as? [String: Any])?["plugin_to_host_rpcs"]
        as? [String: Any])
    XCTAssertEqual(methods.count, 18, "the RPC arm table changed — extend these suites")
    let rpc = PluginHostRPC()
    var gated = 0
    for (method, rawCapability) in methods {
      guard let capability = rawCapability as? String else { continue }  // null = ungated
      gated += 1
      // The capability guard runs before any param decoding, so empty
      // params must still produce the canonical denial.
      let reply = hostReply(rpc, method, [:])
      XCTAssertEqual(reply["ok"] as? Bool, false, method)
      XCTAssertEqual(
        reply["error"] as? String, "missing \(capability) capability",
        "\(method) must reply the spec-pinned EXACT denial string")
    }
    XCTAssertEqual(gated, 15, "15 gated + host.ping + host.storage_get/set ungated")
    // The ungated arms answer without any capability at all.
    XCTAssertEqual(hostReply(rpc, "host.ping", [:])["ok"] as? Bool, true)
    XCTAssertEqual(
      hostReply(rpc, "host.storage_get", ["key": "k"])["error"] as? String,
      "storage unavailable", "storage is data-dir-scoped, never capability-gated")
  }

  func testUnknownHostMethodRepliesTheCanonicalError() {
    let reply = hostReply(PluginHostRPC(), "host.bogus", [:], capabilities: [.accessibility])
    XCTAssertEqual(reply["ok"] as? Bool, false)
    XCTAssertEqual(reply["error"] as? String, "unknown method: host.bogus")
  }

  // MARK: - host.ping

  func testHostPingEchoesParams() {
    let params: [String: Any] = ["a": 1, "nested": ["b": "c"]]
    let reply = hostReply(PluginHostRPC(), "host.ping", params)
    XCTAssertEqual(reply["ok"] as? Bool, true)
    XCTAssertEqual(reply["echo"] as? NSDictionary, params as NSDictionary)
  }

  // MARK: - host.open (urlOpener / appOpener seams)

  func testHostOpenRoutesURLsAndBundleIDsThroughTheSeams() {
    let originalURLOpener = PluginHostRPC.urlOpener
    let originalAppOpener = PluginHostRPC.appOpener
    defer {
      PluginHostRPC.urlOpener = originalURLOpener
      PluginHostRPC.appOpener = originalAppOpener
    }
    var openedURLs: [URL] = []
    var openedBundles: [String] = []
    var urlOpenSucceeds = true
    var appOpenError: String?
    PluginHostRPC.urlOpener = { url in
      openedURLs.append(url)
      return urlOpenSucceeds
    }
    PluginHostRPC.appOpener = { bundleID, done in
      openedBundles.append(bundleID)
      done(appOpenError)
    }
    let rpc = PluginHostRPC()

    let urlReply = hostReply(
      rpc, "host.open", ["url": "https://example.com/x"], capabilities: [.open])
    XCTAssertEqual(urlReply["ok"] as? Bool, true)
    XCTAssertEqual(openedURLs, [URL(string: "https://example.com/x")])

    // Response law: an opener failure carries a non-empty error, never a
    // bare {"ok": false}.
    urlOpenSucceeds = false
    let failed = hostReply(
      rpc, "host.open", ["url": "https://example.com/y"], capabilities: [.open])
    XCTAssertEqual(failed["ok"] as? Bool, false)
    XCTAssertEqual(failed["error"] as? String, "open failed")

    let appReply = hostReply(
      rpc, "host.open", ["bundle_id": "com.example.app"], capabilities: [.open])
    XCTAssertEqual(appReply["ok"] as? Bool, true)
    XCTAssertEqual(openedBundles, ["com.example.app"])

    appOpenError = "boom"
    let appFailed = hostReply(
      rpc, "host.open", ["bundle_id": "com.example.app"], capabilities: [.open])
    XCTAssertEqual(appFailed["ok"] as? Bool, false)
    XCTAssertEqual(appFailed["error"] as? String, "boom")

    let neither = hostReply(rpc, "host.open", [:], capabilities: [.open])
    XCTAssertEqual(neither["error"] as? String, "host.open requires url or bundle_id")
    XCTAssertEqual(openedURLs.count, 2, "a rejected call must not reach the opener")
  }

  // MARK: - host.post_media_key (mediaKeyPoster seam)

  func testMediaKeyPostsDownUpPairThroughTheSeamAndValidatesRange() {
    let original = PluginHostRPC.mediaKeyPoster
    defer { PluginHostRPC.mediaKeyPoster = original }
    var posted: [CGEvent] = []
    PluginHostRPC.mediaKeyPoster = { posted.append($0) }
    let rpc = PluginHostRPC()

    let reply = hostReply(rpc, "host.post_media_key", ["key_code": 16], capabilities: [.mediaKeys])
    XCTAssertEqual(reply["ok"] as? Bool, true)
    XCTAssertEqual(posted.count, 2, "one NX_KEYDOWN + one NX_KEYUP")

    let outOfRange = hostReply(
      rpc, "host.post_media_key", ["key_code": 32], capabilities: [.mediaKeys])
    XCTAssertEqual(outOfRange["error"] as? String, "host.post_media_key requires key_code 0-31")
    XCTAssertEqual(posted.count, 2, "a rejected key_code must not post")
  }

  // MARK: - host.signal (signalSender seam)

  func testSignalRoutesThroughTheSeamAndRefusesLowPids() {
    let original = PluginHostRPC.signalSender
    defer { PluginHostRPC.signalSender = original }
    var signaled: [pid_t] = []
    PluginHostRPC.signalSender = { pid in
      signaled.append(pid)
      return 0
    }
    let rpc = PluginHostRPC()

    let reply = hostReply(rpc, "host.signal", ["pid": 4321], capabilities: [.processControl])
    XCTAssertEqual(reply["ok"] as? Bool, true)
    XCTAssertEqual(signaled, [4321])

    for params in [["pid": 1], ["pid": 0], [:]] {
      let refused = hostReply(rpc, "host.signal", params, capabilities: [.processControl])
      XCTAssertEqual(refused["error"] as? String, "host.signal requires pid > 1")
    }
    XCTAssertEqual(signaled, [4321], "refused pids must never reach kill()")
  }

  // MARK: - host.process_table (read-only, no seam needed)

  func testProcessTableReturnsRowsWithABoundedSampleWindow() {
    let reply = hostReply(
      PluginHostRPC(), "host.process_table", ["sample_window_ms": 10],
      capabilities: [.processControl])
    XCTAssertEqual(reply["ok"] as? Bool, true)
    let rows = reply["processes"] as? [[String: Any]] ?? []
    XCTAssertFalse(rows.isEmpty)
    let mine = rows.first { ($0["pid"] as? Int) == Int(getpid()) }
    XCTAssertNotNil(mine, "the test process itself must appear in the table")
    XCTAssertNotNil(mine?["comm"] as? String)
  }

  func testProcessTableCanReturnDetailedMetricsForOnePID() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["2"]
    try child.run()
    defer {
      if child.isRunning { child.terminate() }
      child.waitUntilExit()
    }
    let pid = Int(getpid())
    let reply = hostReply(
      PluginHostRPC(), "host.process_table",
      ["sample_window_ms": 10, "pid": pid], capabilities: [.processControl])
    XCTAssertEqual(reply["ok"] as? Bool, true)
    let rows = reply["processes"] as? [[String: Any]] ?? []
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?["pid"] as? Int, pid)
    XCTAssertNotNil(rows.first?["memory_bytes"] as? Int)
    XCTAssertNotNil(rows.first?["disk_read_bytes"] as? Int)
    XCTAssertNotNil(rows.first?["disk_write_bytes"] as? Int)
    XCTAssertNotNil(rows.first?["uptime_seconds"] as? Int)
    XCTAssertNotNil(rows.first?["thread_count"] as? Int)
    XCTAssertNotNil(rows.first?["network_socket_count"] as? Int)
    XCTAssertGreaterThanOrEqual(rows.first?["process_count"] as? Int ?? 0, 2)
  }

  func testProcessTableRejectsAnInvalidPidFilter() {
    let reply = hostReply(
      PluginHostRPC(), "host.process_table", ["pid": 0], capabilities: [.processControl])
    XCTAssertEqual(reply["ok"] as? Bool, false)
    XCTAssertEqual(reply["error"] as? String, "host.process_table pid must be positive")
  }

  // MARK: - host.normal_mode_target (closure seam)

  func testNormalModeTargetReportsTheResolvedTargetOrAbsence() {
    let rpc = PluginHostRPC()
    rpc.onNormalModeTargetRequested = { (pid: 42, bundleID: "com.example.app") }
    let reply = hostReply(rpc, "host.normal_mode_target", [:], capabilities: [.appControl])
    XCTAssertEqual(reply["ok"] as? Bool, true)
    XCTAssertEqual(reply["present"] as? Bool, true)
    XCTAssertEqual(reply["pid"] as? Int, 42)
    XCTAssertEqual(reply["bundle_id"] as? String, "com.example.app")

    rpc.onNormalModeTargetRequested = { nil }
    let absent = hostReply(rpc, "host.normal_mode_target", [:], capabilities: [.appControl])
    XCTAssertEqual(absent["ok"] as? Bool, true)
    XCTAssertEqual(absent["present"] as? Bool, false)
  }

  // MARK: - host.activate (validation only; activation itself needs a real app)

  func testActivateValidatesPidAndRequiresARunningApp() {
    let rpc = PluginHostRPC()
    let missing = hostReply(rpc, "host.activate", [:], capabilities: [.appControl])
    XCTAssertEqual(missing["error"] as? String, "host.activate requires pid")
    // launchd is alive but is not an NSRunningApplication: the decode and
    // capability gate passed, the lookup failed — no app is ever activated.
    let notAnApp = hostReply(rpc, "host.activate", ["pid": 1], capabilities: [.appControl])
    XCTAssertEqual(notAnApp["ok"] as? Bool, false)
    XCTAssertEqual(notAnApp["error"] as? String, "no running app for pid")
  }

  // MARK: - host.clipboard_write (quota only; the production body has no seam
  // and would clobber the real clipboard, so the success path stays untested)

  func testClipboardWriteRejectsOversizedAndMissingText() {
    let rpc = PluginHostRPC()
    let oversized = String(
      repeating: "x", count: PluginProtocol.maxClipboardWriteBytes + 1)
    let tooBig = hostReply(
      rpc, "host.clipboard_write", ["text": oversized], capabilities: [.clipboard])
    XCTAssertEqual(tooBig["ok"] as? Bool, false)
    XCTAssertEqual(
      tooBig["error"] as? String, "host.clipboard_write requires text under 1 MiB")
    let missing = hostReply(rpc, "host.clipboard_write", [:], capabilities: [.clipboard])
    XCTAssertEqual(missing["ok"] as? Bool, false)
  }

  // MARK: - host.notify (onNotifyRequested seam)

  func testNotifyClampsDurationRejectsOversizeAndRateLimitsPerPlugin() {
    let rpc = PluginHostRPC()
    var banners: [(message: String, durationMs: Int)] = []
    rpc.onNotifyRequested = { banners.append(($0, $1)) }

    // Duration clamps: 100 → 500 (floor).
    let low = hostReply(
      rpc, "host.notify", ["message": "hi", "duration_ms": 100], capabilities: [.notify])
    XCTAssertEqual(low["ok"] as? Bool, true)
    XCTAssertEqual(banners.last?.durationMs, 500)

    // 1/s rate limit per plugin: a second call within the same second is
    // rejected with the exact error, and the banner seam is not called.
    let limited = hostReply(rpc, "host.notify", ["message": "again"], capabilities: [.notify])
    XCTAssertEqual(limited["ok"] as? Bool, false)
    XCTAssertEqual(limited["error"] as? String, "host.notify rate limit: 1 per second")
    XCTAssertEqual(banners.count, 1)

    // The limit is per plugin id, not global.
    let other = hostReply(
      rpc, "host.notify", ["message": "other"], pluginID: "otherplugin",
      capabilities: [.notify])
    XCTAssertEqual(other["ok"] as? Bool, true)
    XCTAssertEqual(banners.count, 2)

    // Ceiling clamp and default on a fresh instance (fresh rate-limit table).
    let rpc2 = PluginHostRPC()
    var banners2: [(message: String, durationMs: Int)] = []
    rpc2.onNotifyRequested = { banners2.append(($0, $1)) }
    XCTAssertEqual(
      hostReply(
        rpc2, "host.notify", ["message": "hi", "duration_ms": 60_000],
        capabilities: [.notify])["ok"] as? Bool,
      true)
    XCTAssertEqual(banners2.last?.durationMs, 10_000)
    XCTAssertEqual(
      hostReply(
        rpc2, "host.notify", ["message": "hi"], pluginID: "p2",
        capabilities: [.notify])["ok"] as? Bool,
      true)
    XCTAssertEqual(banners2.last?.durationMs, 3_000, "default duration is 3 s")

    // >1 KiB and empty messages are rejected before any main-thread hop.
    let oversized = String(repeating: "m", count: PluginProtocol.maxNotifyMessageBytes + 1)
    XCTAssertEqual(
      hostReply(rpc2, "host.notify", ["message": oversized], capabilities: [.notify])["error"]
        as? String,
      "host.notify requires a message under 1 KiB")
    XCTAssertEqual(
      hostReply(rpc2, "host.notify", ["message": ""], capabilities: [.notify])["ok"] as? Bool,
      false)
  }

  // MARK: - host.storage_get / host.storage_set

  func testStorageRoundTripNullDeleteAndQuotas() throws {
    let dataDir = try temporaryDataDir()
    let rpc = PluginHostRPC()

    XCTAssertEqual(
      hostReply(rpc, "host.storage_set", ["key": "k", "value": "v"], dataDir: dataDir)["ok"]
        as? Bool,
      true)
    let got = hostReply(rpc, "host.storage_get", ["key": "k"], dataDir: dataDir)
    XCTAssertEqual(got["present"] as? Bool, true)
    XCTAssertEqual(got["value"] as? String, "v")
    XCTAssertEqual(
      hostReply(rpc, "host.storage_get", ["key": "absent"], dataDir: dataDir)["present"] as? Bool,
      false)

    // null deletes; deleting an absent key stays ok.
    XCTAssertEqual(
      hostReply(rpc, "host.storage_set", ["key": "k", "value": NSNull()], dataDir: dataDir)["ok"]
        as? Bool,
      true)
    XCTAssertEqual(
      hostReply(rpc, "host.storage_get", ["key": "k"], dataDir: dataDir)["present"] as? Bool,
      false)

    // Key bound: >128 B (and empty) rejected on both arms.
    let longKey = String(repeating: "k", count: PluginProtocol.maxStorageKeyBytes + 1)
    XCTAssertEqual(
      hostReply(rpc, "host.storage_set", ["key": longKey, "value": "v"], dataDir: dataDir)[
        "error"] as? String,
      "host.storage_set requires a key under 128 bytes")
    XCTAssertEqual(
      hostReply(rpc, "host.storage_get", ["key": longKey], dataDir: dataDir)["error"] as? String,
      "host.storage_get requires a key under 128 bytes")
    XCTAssertEqual(
      hostReply(rpc, "host.storage_set", ["key": "", "value": "v"], dataDir: dataDir)["ok"]
        as? Bool,
      false)

    // Value bound: >64 KiB rejected atomically.
    let bigValue = String(repeating: "v", count: PluginProtocol.maxStorageValueBytes + 1)
    XCTAssertTrue(
      (hostReply(rpc, "host.storage_set", ["key": "big", "value": bigValue], dataDir: dataDir)[
        "error"] as? String ?? "")
        .contains("storage bound exceeded"))

    // Non-string, non-null values are a type error, not a coercion.
    XCTAssertEqual(
      hostReply(rpc, "host.storage_set", ["key": "n", "value": 42], dataDir: dataDir)["error"]
        as? String,
      "host.storage_set value must be a string or null")

    // Missing dataDir (no plugin identity): storage unavailable.
    XCTAssertEqual(
      hostReply(rpc, "host.storage_set", ["key": "k", "value": "v"])["error"] as? String,
      "storage unavailable")
  }

  func testStorageEntryCapAndPersistenceAcrossHandlerInstances() throws {
    let dataDir = try temporaryDataDir()
    // Pre-fill exactly maxStorageEntries entries on disk.
    var full: [String: String] = [:]
    for index in 0..<PluginProtocol.maxStorageEntries { full["k\(index)"] = "v" }
    let data = try JSONSerialization.data(withJSONObject: full)
    try data.write(to: dataDir.appendingPathComponent("storage.json"))

    let rpc = PluginHostRPC()
    // The 257th key is rejected; updating and deleting existing keys still work.
    XCTAssertTrue(
      (hostReply(rpc, "host.storage_set", ["key": "overflow", "value": "v"], dataDir: dataDir)[
        "error"] as? String ?? "")
        .contains("storage bound exceeded"))
    XCTAssertEqual(
      hostReply(rpc, "host.storage_set", ["key": "k0", "value": "updated"], dataDir: dataDir)[
        "ok"] as? Bool,
      true)
    XCTAssertEqual(
      hostReply(rpc, "host.storage_set", ["key": "k1", "value": NSNull()], dataDir: dataDir)[
        "ok"] as? Bool,
      true)

    // storage.json persists: a brand-new handler instance reads the same store.
    let fresh = PluginHostRPC()
    let reread = hostReply(fresh, "host.storage_get", ["key": "k0"], dataDir: dataDir)
    XCTAssertEqual(reread["present"] as? Bool, true)
    XCTAssertEqual(reread["value"] as? String, "updated")
    XCTAssertEqual(
      hostReply(fresh, "host.storage_get", ["key": "k1"], dataDir: dataDir)["present"] as? Bool,
      false)
  }

  // MARK: - host.fetch (validation paths only; an allowlisted https URL would
  // hit the real network)

  func testFetchRequiresHTTPSAndHonorsTheAllowlistAtComponentBoundaries() {
    let rpc = PluginHostRPC()
    let allowlist = ["https://example.com/api"]

    XCTAssertEqual(
      hostReply(
        rpc, "host.fetch", ["url": "http://example.com/api/x"],
        capabilities: [.networkFetch], fetchURLs: allowlist)["error"] as? String,
      "host.fetch requires a valid https url param")
    XCTAssertEqual(
      hostReply(rpc, "host.fetch", [:], capabilities: [.networkFetch], fetchURLs: allowlist)[
        "error"] as? String,
      "host.fetch requires a valid https url param")
    XCTAssertEqual(
      hostReply(
        rpc, "host.fetch", ["url": "https://evil.example/x"],
        capabilities: [.networkFetch], fetchURLs: allowlist)["error"] as? String,
      "url not in fetch_urls allowlist")
    // Component boundary: the prefix "…/api" must NOT admit "…/apix".
    XCTAssertEqual(
      hostReply(
        rpc, "host.fetch", ["url": "https://example.com/apix"],
        capabilities: [.networkFetch], fetchURLs: allowlist)["error"] as? String,
      "url not in fetch_urls allowlist")

    // The boundary rule itself, on the pure function (no network).
    XCTAssertTrue(
      PluginHostRPC.urlIsAllowed("https://example.com/api", byPrefix: "https://example.com/api"))
    XCTAssertTrue(
      PluginHostRPC.urlIsAllowed("https://example.com/api/x", byPrefix: "https://example.com/api"))
    XCTAssertTrue(
      PluginHostRPC.urlIsAllowed("https://example.com/api?q=1", byPrefix: "https://example.com/api")
    )
    XCTAssertTrue(
      PluginHostRPC.urlIsAllowed("https://example.com/api#f", byPrefix: "https://example.com/api"))
    XCTAssertFalse(
      PluginHostRPC.urlIsAllowed("https://example.com/apix", byPrefix: "https://example.com/api"))
  }

  // MARK: - host.post_keys (onSyntheticKeysRequested seam)

  func testPostKeysValidatesChordsBoundsCountAndClampsInterval() {
    let rpc = PluginHostRPC()
    var captured: [(pid: pid_t, chords: [(key: CGKeyCode, flags: CGEventFlags)], interval: Int)] =
      []
    rpc.onSyntheticKeysRequested = { pid, chords, interval in
      captured.append((pid, chords, interval))
    }
    let chord: [String: Any] = ["key_code": Int(kVK_ANSI_8), "modifiers": ["command"]]

    let posted = hostReply(
      rpc, "host.post_keys",
      [
        "pid": 123,
        "keys": [chord, ["key_code": 0x79, "modifiers": ["control", "shift"]]],
        "interval_ms": 1,
      ],
      capabilities: [.accessibility])
    XCTAssertEqual(posted["ok"] as? Bool, true)
    XCTAssertEqual(captured.count, 1)
    XCTAssertEqual(captured.first?.pid, 123)
    XCTAssertEqual(captured.first?.chords.count, 2)
    XCTAssertEqual(captured.first?.chords.first?.key, CGKeyCode(kVK_ANSI_8))
    XCTAssertEqual(captured.first?.chords.last?.flags, [.maskControl, .maskShift])
    XCTAssertEqual(captured.first?.interval, 8, "interval clamps to the 8 ms floor")

    XCTAssertEqual(
      hostReply(
        rpc, "host.post_keys", ["pid": 123, "keys": [chord], "interval_ms": 500],
        capabilities: [.accessibility])["ok"] as? Bool,
      true)
    XCTAssertEqual(captured.last?.interval, 100, "interval clamps to the 100 ms ceiling")

    // >32 chords, zero chords, and a missing pid are all rejected whole.
    let tooMany = Array(repeating: chord, count: 33)
    for params in [
      ["pid": 123, "keys": tooMany],
      ["pid": 123, "keys": [] as [[String: Any]]],
      ["keys": [chord]],
    ] as [[String: Any]] {
      XCTAssertEqual(
        hostReply(rpc, "host.post_keys", params, capabilities: [.accessibility])["error"]
          as? String,
        "host.post_keys requires pid and 1-32 keys")
    }

    // Chord validation: unmodified chords and key_code >= 0x80 are refused —
    // this surface can never be used to type plain text into the target.
    for badChord in [
      ["key_code": Int(kVK_ANSI_8), "modifiers": [] as [String]],
      ["key_code": 0x80, "modifiers": ["command"]],
      ["modifiers": ["command"]],
    ] as [[String: Any]] {
      XCTAssertEqual(
        hostReply(
          rpc, "host.post_keys", ["pid": 123, "keys": [badChord]],
          capabilities: [.accessibility])["error"] as? String,
        "each key needs key_code and non-empty modifiers")
    }
    XCTAssertEqual(
      hostReply(
        rpc, "host.post_keys",
        ["pid": 123, "keys": [["key_code": Int(kVK_ANSI_8), "modifiers": ["hyper"]]]],
        capabilities: [.accessibility])["error"] as? String,
      "unknown modifier: hyper")
    XCTAssertEqual(captured.count, 2, "rejected payloads must never reach the poster")
  }

  // MARK: - host.post_global_key

  func testPostGlobalKeyRejectsUnmodifiedChordsAndHighKeyCodes() {
    let rpc = PluginHostRPC()
    var posted = 0
    rpc.onGlobalSyntheticKeyRequested = { _, _ in
      posted += 1
      return true
    }
    for params in [
      ["key_code": Int(kVK_ANSI_Q), "modifiers": [] as [String]],
      ["key_code": 0x80, "modifiers": ["command"]],
      ["key_code": Int(kVK_ANSI_Q)],
    ] as [[String: Any]] {
      let reply = hostReply(rpc, "host.post_global_key", params, capabilities: [.accessibility])
      XCTAssertEqual(
        reply["error"] as? String,
        "host.post_global_key requires key_code and valid non-empty modifiers")
    }
    XCTAssertEqual(posted, 0)
  }

  // MARK: - host.ax_* routing (validation errors only; real trees are the
  // AX broker suite's business)

  func testAXArmsRouteToTheBrokerAndSurfaceItsValidationErrors() {
    let rpc = PluginHostRPC()
    let caps: Set<PluginCapability> = [.accessibility]
    XCTAssertEqual(
      hostReply(rpc, "host.ax_snapshot", [:], capabilities: caps)["error"] as? String,
      "host.ax_snapshot requires pid")
    XCTAssertEqual(
      hostReply(rpc, "host.ax_perform", [:], capabilities: caps)["error"] as? String,
      "host.ax_perform requires handle")
    XCTAssertEqual(
      hostReply(rpc, "host.ax_perform", ["handle": 424_242], capabilities: caps)["error"]
        as? String,
      "stale ax handle")
    XCTAssertEqual(
      hostReply(rpc, "host.ax_set", ["handle": 1], capabilities: caps)["error"] as? String,
      "host.ax_set requires handle and attribute")
    XCTAssertEqual(
      hostReply(rpc, "host.ax_select_child", [:], capabilities: caps)["error"] as? String,
      "host.ax_select_child requires parent and child")
  }
}
