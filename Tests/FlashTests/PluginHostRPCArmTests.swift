import Carbon.HIToolbox
import Foundation
import XCTest

@testable import flash

/// Every arm of the plugin→host RPC surface, driven through
/// `handleHostRequest` with synthetic capability sets. Side-effecting arms
/// go through the closure/static seams (urlOpener, appOpener,
/// onSyntheticKeysRequested, onNormalModeTargetRequested, wifiInfoProvider) —
/// no test here ever opens a browser or posts a HID event.
final class PluginHostRPCArmTests: XCTestCase {

  // MARK: - Plumbing

  private func protocolSpec() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Plugins/_flash_plugin_rust/protocol.json")
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  /// Synchronously collect one `handleHostRequest` reply (replies may hop
  /// through main or the AX broker queue).
  private func hostReply(
    _ rpc: PluginHostRPC,
    _ method: String,
    _ params: [String: Any],
    pluginID: String = "rpctest",
    capabilities: Set<PluginCapability> = [],
    fetchURLs: [String] = [],
    appleEventsTargets: [String] = [],
    timeout: TimeInterval = 5,
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
      appleEventsTargets: appleEventsTargets,
      scope: PluginHostRequestScope(isCurrent: { true })
    ) { result in
      lock.lock()
      reply = result
      lock.unlock()
      replied.fulfill()
    }
    wait(for: [replied], timeout: timeout)
    lock.lock()
    defer { lock.unlock() }
    return reply
  }

  // MARK: - Capability gate, table-driven from protocol.json

  func testEveryCapabilityGatedArmRepliesTheExactCanonicalDenial() throws {
    let methods = try XCTUnwrap(
      (try protocolSpec()["methods"] as? [String: Any])?["plugin_to_host_rpcs"]
        as? [String: Any])
    XCTAssertEqual(methods.count, 12, "the RPC arm table changed — extend these suites")
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
    XCTAssertEqual(gated, 11, "11 gated + host.ping ungated")
    // The ungated arm answers without any capability at all.
    XCTAssertEqual(hostReply(rpc, "host.ping", [:])["ok"] as? Bool, true)
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

  // MARK: - host.wifi_info (host-owned Location/CoreWLAN seam)

  func testWiFiInfoReturnsPresentAndAbsentShapes() {
    final class Stub: WiFiInfoProviding {
      var ssid: String?
      var authorizationRequests: [Bool] = []

      init(ssid: String?) {
        self.ssid = ssid
      }

      func fetchSSID(
        requestAuthorization: Bool,
        completion: @escaping (String?) -> Void
      ) {
        authorizationRequests.append(requestAuthorization)
        completion(ssid)
      }
    }

    let rpc = PluginHostRPC()
    let provider = Stub(ssid: "Studio")
    rpc.wifiInfoProvider = provider

    let present = hostReply(
      rpc, "host.wifi_info", ["request_authorization": false], capabilities: [.wifiInfo])
    XCTAssertEqual(present["ok"] as? Bool, true)
    XCTAssertEqual(present["present"] as? Bool, true)
    XCTAssertEqual(present["ssid"] as? String, "Studio")
    XCTAssertEqual(Set(present.keys), ["ok", "present", "ssid"])

    provider.ssid = nil
    let absent = hostReply(
      rpc, "host.wifi_info", ["request_authorization": true], capabilities: [.wifiInfo])
    XCTAssertEqual(absent["ok"] as? Bool, true)
    XCTAssertEqual(absent["present"] as? Bool, false)
    XCTAssertNil(absent["ssid"])
    XCTAssertEqual(Set(absent.keys), ["ok", "present"])
    XCTAssertEqual(provider.authorizationRequests, [false, true])
  }

  func testWiFiInfoRequiresExplicitAuthorizationIntent() {
    for invalid in [nil, 0, 1, 1.0, "true", NSNull()] as [Any?] {
      let params = invalid.map { ["request_authorization": $0] } ?? [:]
      let reply = hostReply(PluginHostRPC(), "host.wifi_info", params, capabilities: [.wifiInfo])

      XCTAssertEqual(reply["ok"] as? Bool, false, "\(String(describing: invalid))")
      XCTAssertEqual(
        reply["error"] as? String,
        "host.wifi_info requires a boolean request_authorization param",
        "\(String(describing: invalid))")
    }
  }

  // MARK: - host.open (urlOpener / appOpener seams)

  func testHostOpenRoutesURLsAndBundleIDsThroughTheSeams() {
    let originalURLOpener = PluginHostRPC.urlOpener
    let originalURLHandler = PluginHostRPC.urlHandler
    let originalAppOpener = PluginHostRPC.appOpener
    defer {
      PluginHostRPC.urlOpener = originalURLOpener
      PluginHostRPC.urlHandler = originalURLHandler
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
    var handler: String? = "com.example.browser"
    PluginHostRPC.urlHandler = { _ in handler }
    PluginHostRPC.appOpener = { bundleID, done in
      openedBundles.append(bundleID)
      done(appOpenError)
    }
    let rpc = PluginHostRPC()

    let urlReply = hostReply(
      rpc, "host.open", ["url": "https://example.com/x"], capabilities: [.open])
    XCTAssertEqual(urlReply["ok"] as? Bool, true)
    XCTAssertEqual(urlReply["bundle_id"] as? String, "com.example.browser")
    XCTAssertEqual(openedURLs, [URL(string: "https://example.com/x")])
    handler = nil
    let unnamed = hostReply(
      rpc, "host.open", ["url": "https://example.com/x"], capabilities: [.open])
    XCTAssertEqual(unnamed["ok"] as? Bool, true)
    XCTAssertNil(unnamed["bundle_id"], "an unresolved handler is omitted, not empty")

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
    XCTAssertEqual(openedURLs.count, 3, "a rejected call must not reach the opener")
  }

  /// The regression: `host.open` handed any URL to LaunchServices, so a
  /// sandboxed plugin with `open` could write `x.command` (or an app, a
  /// script) into its own data directory and open it as a `file:` URL:
  /// Terminal or Finder then ran it outside the sandbox. Local files are
  /// never opened for a plugin; web and app URLs still are.
  func testHostOpenNeverOpensALocalFileForAPlugin() {
    let originalURLOpener = PluginHostRPC.urlOpener
    defer { PluginHostRPC.urlOpener = originalURLOpener }
    var opened: [URL] = []
    PluginHostRPC.urlOpener = { url in
      opened.append(url)
      return true
    }
    let rpc = PluginHostRPC()
    for url in [
      "file:///Users/me/Library/Application%20Support/Flash/Plugins/x/run.command",
      "FILE:///Applications/Terminal.app", "file://localhost/tmp/x.sh",
    ] {
      let reply = hostReply(rpc, "host.open", ["url": url], capabilities: [.open])
      XCTAssertEqual(reply["ok"] as? Bool, false, url)
      XCTAssertEqual(reply["error"] as? String, "host.open does not open local files", url)
    }
    XCTAssertEqual(opened, [], "no local file reaches LaunchServices")
    let web = hostReply(rpc, "host.open", ["url": "https://example.com"], capabilities: [.open])
    XCTAssertEqual(web["ok"] as? Bool, true)
    XCTAssertEqual(opened, [URL(string: "https://example.com")])
  }

  // MARK: - host.normal_mode_target (closure seam)

  func testNormalModeTargetReportsTheResolvedTargetOrAbsence() {
    let rpc = PluginHostRPC()
    rpc.onNormalModeTargetRequested = {
      (pid: 42, bundleID: "com.example.app", windowID: CGWindowID(9_001))
    }
    let reply = hostReply(rpc, "host.normal_mode_target", [:], capabilities: [.appControl])
    XCTAssertEqual(reply["ok"] as? Bool, true)
    XCTAssertEqual(reply["present"] as? Bool, true)
    XCTAssertEqual(reply["pid"] as? Int, 42)
    XCTAssertEqual(reply["bundle_id"] as? String, "com.example.app")
    // Window identity travels with the target so a plugin can name a window
    // without asking the user to pick one.
    XCTAssertEqual(reply["window_id"] as? Int, 9_001)

    // A target with no resolvable window simply omits the id.
    rpc.onNormalModeTargetRequested = {
      (pid: 42, bundleID: "com.example.app", windowID: nil)
    }
    let windowless = hostReply(rpc, "host.normal_mode_target", [:], capabilities: [.appControl])
    XCTAssertEqual(windowless["present"] as? Bool, true)
    XCTAssertNil(windowless["window_id"])

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

  // MARK: - host.applescript

  func testAppleScriptValidatesOperationsAndBoundsResults() {
    let rpc = PluginHostRPC()
    var executions = 0
    rpc.appleScriptRunner = { source, _ in
      executions += 1
      XCTAssertTrue(source.contains("com.apple.shortcuts.events"))
      return AppleScriptOutput(status: 0, stdout: "names\n", stderr: "")
    }
    let granted: Set<PluginCapability> = [.appleEvents]
    let targets = ["com.apple.shortcuts.events"]
    for params: [String: Any] in [
      [:], ["script": "return 1"], ["operation": "shortcuts_list", "script": "return 1"],
      ["operation": "shortcuts_list", "timeout_ms": true],
      ["operation": "shortcuts_list", "timeout_ms": 0],
    ] {
      XCTAssertEqual(
        hostReply(
          rpc, "host.applescript", params, capabilities: granted, appleEventsTargets: targets)["ok"]
          as? Bool, false)
    }
    XCTAssertEqual(executions, 0)
    let params: [String: Any] = ["operation": "shortcuts_list"]
    XCTAssertEqual(
      hostReply(
        rpc, "host.applescript", params, capabilities: granted, appleEventsTargets: targets)[
          "result"] as? String, "names")
    XCTAssertEqual(executions, 1)
    rpc.appleScriptRunner = { _, _ in
      AppleScriptOutput(
        status: 0,
        stdout: String(repeating: "x", count: PluginProtocol.maxAppleScriptResultBytes + 1),
        stderr: "")
    }
    XCTAssertEqual(
      hostReply(
        rpc, "host.applescript", params, capabilities: granted, appleEventsTargets: targets)[
          "status"] as? Int, Int(AppleScriptOutput.outputLimitStatus))
    rpc.appleScriptRunner = { _, _ in
      AppleScriptOutput(status: 1, stdout: "", stderr: "execution error: denied (-1743)")
    }
    XCTAssertEqual(
      hostReply(
        rpc, "host.applescript", params, capabilities: granted, appleEventsTargets: targets)[
          "status"] as? Int, 1)
  }

  func testStaleAppleScriptRequestDoesNotExecuteItsOperation() {
    let unexpected = expectation(description: "stale operation never executes or replies")
    unexpected.isInverted = true
    PluginHostAppleScript.handle(
      ["operation": "shortcuts_list"], targets: ["com.apple.shortcuts.events"],
      pluginID: "stale-operation", scope: PluginHostRequestScope(isCurrent: { false }),
      runner: { _, _ in
        unexpected.fulfill()
        return AppleScriptOutput(status: 0, stdout: "", stderr: "")
      }, reply: { _ in unexpected.fulfill() })
    wait(for: [unexpected], timeout: 0.1)
  }

  /// At most `concurrency` scripts of one plugin run at once; the next waits
  /// for a slot within its own timeout, and another plugin's scripts do not
  /// wait on them.
  func testAppleScriptConcurrencyIsPerPlugin() {
    let rpc = PluginHostRPC()
    rpc.appleScriptRunner = { source, _ in
      if source.contains("delay") { Thread.sleep(forTimeInterval: 1) }
      return AppleScriptOutput(
        status: 0, stdout: source.contains("delay") ? "busy\n" : "idle\n", stderr: "")
    }

    let granted: Set<PluginCapability> = [.appleEvents]
    let group = DispatchGroup()
    let lock = NSLock()
    var replies: [String: [String: Any]] = [:]
    func call(_ plugin: String, _ index: Int, _ script: String, timeoutMs: Int) {
      group.enter()
      rpc.handleHostRequest(
        method: "host.applescript",
        params: ["operation": "shortcut_run", "name": script, "timeout_ms": timeoutMs],
        pluginID: plugin, capabilities: granted, fetchURLs: [],
        appleEventsTargets: ["com.apple.shortcuts.events"],
        scope: PluginHostRequestScope(isCurrent: { true })
      ) { reply in
        lock.lock()
        replies["\(plugin)/\(index)"] = reply
        lock.unlock()
        group.leave()
      }
    }
    // Every slot of `busy` is held for a second; its fifth script must wait
    // for one, and a 300 ms timeout does not get it.
    for index in 0..<PluginProtocol.appleScriptConcurrency {
      call("busy", index, "delay 1\nreturn \(index)", timeoutMs: 10_000)
    }
    Thread.sleep(forTimeInterval: 0.2)
    call("busy", PluginProtocol.appleScriptConcurrency, "return 99", timeoutMs: 300)
    call("idle", 0, "return 7", timeoutMs: 10_000)
    XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
    lock.lock()
    defer { lock.unlock() }
    for index in 0..<PluginProtocol.appleScriptConcurrency {
      XCTAssertEqual(replies["busy/\(index)"]?["result"] as? String, "busy")
    }
    let waited = replies["busy/\(PluginProtocol.appleScriptConcurrency)"]
    XCTAssertEqual(waited?["ok"] as? Bool, false)
    XCTAssertEqual(waited?["error"] as? String, "applescript timed out timeout_ms=300")
    XCTAssertEqual(replies["idle/0"]?["result"] as? String, "idle", "another plugin's slots")
  }

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
