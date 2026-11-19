import Carbon.HIToolbox
import FlashCore
import Foundation
import XCTest

@testable import flash

/// Every arm of the plugin→host RPC surface, driven through
/// `handleHostRequest` with synthetic capability sets. Side-effecting arms
/// go through the closure/static seams (urlOpener, appOpener,
/// onSyntheticKeysRequested, onNormalModeTargetRequested, wifiInfoProvider,
/// systemActions, processSignals) — no test here ever opens a browser, posts
/// a HID event or asks macOS for a system action, and the one that sends a
/// signal sends it to a child process it spawned.
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
    scope: PluginHostRequestScope = PluginHostRequestScope(isCurrent: { true }),
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
      scope: scope
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
    XCTAssertEqual(methods.count, 15, "the RPC arm table changed — extend these suites")
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
    XCTAssertEqual(gated, 14, "14 gated + host.ping ungated")
    // The ungated arm answers without any capability at all.
    XCTAssertEqual(hostReply(rpc, "host.ping", [:])["ok"] as? Bool, true)
  }

  func testUnknownHostMethodRepliesTheCanonicalError() {
    let reply = hostReply(PluginHostRPC(), "host.bogus", [:], capabilities: [.accessibility])
    XCTAssertEqual(reply["ok"] as? Bool, false)
    XCTAssertEqual(reply["error"] as? String, "unknown method: host.bogus")
  }

  /// A method the contract does not name is unknown whatever its prefix and
  /// whatever the plugin holds: `host.ax_bogus` is not an Accessibility call
  /// to deny.
  func testAnUnknownAXMethodIsUnknownWithAndWithoutTheCapability() {
    for capabilities in [[], [.accessibility]] as [Set<PluginCapability>] {
      let reply = hostReply(PluginHostRPC(), "host.ax_bogus", [:], capabilities: capabilities)
      XCTAssertEqual(
        reply as NSDictionary,
        ["ok": false, "error": "unknown method: host.ax_bogus"] as NSDictionary)
    }
  }

  /// The dispatcher's method table is the contract's: every
  /// `plugin_to_host_rpcs` method, under the capability the contract names.
  func testTheMethodTableIsTheContracts() throws {
    let methods = try XCTUnwrap(
      (try protocolSpec()["methods"] as? [String: Any])?["plugin_to_host_rpcs"]
        as? [String: Any])
    let contract = methods.mapValues { $0 as? String }
    let table = Dictionary(
      uniqueKeysWithValues: PluginHostRequest.Method.allCases.map {
        ($0.rawValue, $0.capability?.rawValue)
      })
    XCTAssertEqual(table, contract)
  }

  /// Params are closed: a key the method does not define refuses the call
  /// before any of it runs. The conformance corpus pins one line per method;
  /// this pins that nothing reached a seam.
  func testAnUndefinedParamRefusesTheCallBeforeItRuns() {
    let originalURLOpener = PluginHostRPC.urlOpener
    let originalAppOpener = PluginHostRPC.appOpener
    defer {
      PluginHostRPC.urlOpener = originalURLOpener
      PluginHostRPC.appOpener = originalAppOpener
    }
    var ran = 0
    PluginHostRPC.urlOpener = { _ in
      ran += 1
      return true
    }
    PluginHostRPC.appOpener = { _, done in
      ran += 1
      done(nil)
    }
    let rpc = PluginHostRPC()
    rpc.onSyntheticKeysRequested = { _, _, _ in ran += 1 }
    rpc.onNormalModeTargetRequested = {
      ran += 1
      return nil
    }
    let chord: [String: Any] = ["key_code": Int(kVK_ANSI_8), "modifiers": ["command"]]
    let calls: [(String, [String: Any], PluginCapability)] = [
      ("host.open", ["url": "https://example.com/", "background": true], .open),
      ("host.normal_mode_target", ["pid": 1], .appControl),
      ("host.post_keys", ["pid": 123, "keys": [chord], "repeat": 2], .accessibility),
    ]
    for (method, params, capability) in calls {
      XCTAssertEqual(
        hostReply(rpc, method, params, capabilities: [capability]) as NSDictionary,
        ["ok": false, "error": "invalid \(method) params"] as NSDictionary)
    }
    // Naming both is naming neither: `host.open` opens one thing.
    XCTAssertEqual(
      hostReply(
        rpc, "host.open", ["url": "https://example.com/", "bundle_id": "com.example.app"],
        capabilities: [.open])["error"] as? String,
      "host.open requires url or bundle_id")
    XCTAssertEqual(ran, 0)
  }

  // MARK: - host.ping

  func testHostPingAnswersOkAndNothingElse() {
    let reply = hostReply(PluginHostRPC(), "host.ping", [:])
    XCTAssertEqual(reply as NSDictionary, ["ok": true] as NSDictionary)
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

  // MARK: - host.audio_devices (CoreAudio seam)

  private func audioReply(
    _ rpc: PluginHostRPC, _ params: [String: Any]
  ) -> NSDictionary {
    hostReply(rpc, "host.audio_devices", params, capabilities: [.audioDevices]) as NSDictionary
  }

  func testAudioDevicesListsSelectsStepsMutesAndReads() {
    let rpc = PluginHostRPC()
    let devices = AudioDeviceStub()
    rpc.audioDevices = devices
    XCTAssertEqual(
      audioReply(rpc, ["operation": "list", "direction": "output"]),
      [
        "ok": true,
        "devices": [
          ["uid": "built-in", "name": "MacBook Pro Speakers", "default": true],
          ["uid": "usb-1", "name": "USB Audio", "default": false],
        ],
      ] as NSDictionary)
    XCTAssertEqual(
      audioReply(rpc, ["operation": "select", "direction": "input", "uid": "usb-1"]),
      ["ok": true] as NSDictionary)
    XCTAssertEqual(devices.devices[.input]?.first { $0.isDefault }?.uid, "usb-1")
    XCTAssertEqual(devices.devices[.output]?.first { $0.isDefault }?.uid, "built-in")
    // 38% is the sixth of sixteen ticks; three more is the ninth.
    XCTAssertEqual(
      audioReply(rpc, ["operation": "step_volume", "ticks": 3]),
      ["ok": true, "percent": 56] as NSDictionary)
    XCTAssertEqual(
      audioReply(rpc, ["operation": "step_volume", "ticks": -16]),
      ["ok": true, "percent": 0] as NSDictionary)
    XCTAssertEqual(
      audioReply(rpc, ["operation": "toggle_mute"]), ["ok": true, "muted": true] as NSDictionary)
    XCTAssertEqual(
      audioReply(rpc, ["operation": "volume"]),
      ["ok": true, "percent": 0, "muted": true] as NSDictionary)
    XCTAssertEqual(
      devices.calls,
      ["list output", "select input usb-1", "step 3", "step -16", "mute", "volume"])
  }

  func testAudioDevicesReportsACoreAudioFailureAsTheReplysError() {
    let rpc = PluginHostRPC()
    let devices = AudioDeviceStub()
    rpc.audioDevices = devices
    XCTAssertEqual(
      audioReply(rpc, ["operation": "select", "direction": "output", "uid": "gone"]),
      ["ok": false, "error": "audio device unavailable: gone"] as NSDictionary)
    devices.failure = AudioDeviceError.unsupported("output volume")
    for operation in ["step_volume", "volume"] {
      var params: [String: Any] = ["operation": operation]
      if operation == "step_volume" { params["ticks"] = 1 }
      XCTAssertEqual(
        audioReply(rpc, params),
        ["ok": false, "error": "audio device does not support output volume"] as NSDictionary)
    }
    devices.failure = AudioDeviceError.system(-50)
    XCTAssertEqual(
      audioReply(rpc, ["operation": "list", "direction": "input"]),
      ["ok": false, "error": "CoreAudio error -50"] as NSDictionary)
  }

  /// Each operation takes exactly its own params; a refused call reaches no
  /// device.
  func testAudioDevicesRefusesWhatItsOperationDoesNotTake() {
    let rpc = PluginHostRPC()
    let devices = AudioDeviceStub()
    rpc.audioDevices = devices
    let operation = "host.audio_devices requires a supported operation"
    let direction = "host.audio_devices requires an input or output direction"
    let uid = "host.audio_devices select requires a non-empty uid"
    let ticks = "host.audio_devices step_volume requires non-zero ticks from -16 to 16"
    let closed = "invalid host.audio_devices params"
    let refusals: [([String: Any], String)] = [
      ([:], operation),
      (["operation": "set_volume"], operation),
      (["operation": 3], operation),
      (["operation": "list"], direction),
      (["operation": "list", "direction": "both"], direction),
      (["operation": "select", "uid": "usb-1"], direction),
      (["operation": "select", "direction": "output"], uid),
      (["operation": "select", "direction": "output", "uid": ""], uid),
      (["operation": "select", "direction": "output", "uid": 7], uid),
      (["operation": "step_volume"], ticks),
      (["operation": "step_volume", "ticks": 0], ticks),
      (["operation": "step_volume", "ticks": 17], ticks),
      (["operation": "step_volume", "ticks": -17], ticks),
      (["operation": "step_volume", "ticks": 1.5], ticks),
      (["operation": "step_volume", "ticks": "2"], ticks),
      (["operation": "list", "direction": "output", "uid": "usb-1"], closed),
      (["operation": "volume", "direction": "output"], closed),
      (["operation": "toggle_mute", "ticks": 1], closed),
      (["operation": "step_volume", "ticks": 1, "direction": "output"], closed),
      (["operation": "volume", "percent": 50], closed),
    ]
    for (params, error) in refusals {
      XCTAssertEqual(
        audioReply(rpc, params), ["ok": false, "error": error] as NSDictionary, "\(params)")
    }
    XCTAssertEqual(devices.calls, [])
  }

  /// The operations, directions and tick bound are the contract's.
  func testAudioDevicesContractMatchesSpec() throws {
    let audio = try XCTUnwrap(try protocolSpec()["audio_devices"] as? [String: Any])
    XCTAssertEqual(
      audio["operations"] as? [String], PluginHostRequest.Audio.operations.map(\.name))
    XCTAssertEqual(
      audio["directions"] as? [String], AudioDeviceDirection.allCases.map(\.rawValue))
    XCTAssertEqual(audio["max_ticks"] as? Int, PluginHostRequest.maxVolumeTicks)
  }

  // MARK: - host.system_action (systemActions seam)

  private func systemReply(
    _ rpc: PluginHostRPC, _ params: [String: Any],
    scope: PluginHostRequestScope = PluginHostRequestScope(isCurrent: { true })
  ) -> NSDictionary {
    hostReply(rpc, "host.system_action", params, capabilities: [.systemActions], scope: scope)
      as NSDictionary
  }

  /// A scope inside `grants` performs the user confirmed: each hands its
  /// consent out once.
  private func scope(confirmedPerforms grants: Int) -> PluginHostRequestScope {
    let lock = NSLock()
    var left = grants
    return PluginHostRequestScope(
      isCurrent: { true },
      claimConfirmedPerform: {
        lock.lock()
        defer { lock.unlock() }
        guard left > 0 else { return false }
        left -= 1
        return true
      })
  }

  /// The five actions something undoes run at once, each through its own
  /// mechanism: the lock chord on main, the rest off it.
  func testSystemActionsThatCanBeUndoneRunWithoutAConfirmation() {
    let rpc = PluginHostRPC()
    let mechanisms = SystemActionStub()
    rpc.systemActions = mechanisms
    let expected: [(String, SystemActionExecution, onMain: Bool)] = [
      ("lock_screen", .lockScreenChord, true),
      ("sleep", .sleepSystem, false),
      ("display_sleep", .sleepDisplays, false),
      ("screensaver", .startScreensaver, false),
      (
        "toggle_appearance",
        .appleScript(
          "tell application \"System Events\" to tell appearance preferences to "
            + "set dark mode to not dark mode", timeout: 10), false
      ),
    ]
    for (action, _, _) in expected {
      XCTAssertEqual(systemReply(rpc, ["action": action]), ["ok": true] as NSDictionary, action)
    }
    XCTAssertEqual(mechanisms.executions, expected.map(\.1))
    XCTAssertEqual(mechanisms.onMainThread, expected.map(\.onMain))
  }

  /// The four actions nothing undoes are refused, with the fixed error and
  /// before any mechanism is reached, unless a perform the user confirmed
  /// is in flight; that perform covers exactly one of them.
  func testADestructiveSystemActionIsHonouredOnlyInsideAConfirmedPerform() throws {
    let rpc = PluginHostRPC()
    let mechanisms = SystemActionStub()
    rpc.systemActions = mechanisms
    let refused: NSDictionary = ["ok": false, "error": "requires a perform the user confirmed"]
    XCTAssertEqual(PluginProtocol.confirmationRequiredError, refused["error"] as? String)
    let destructive = ["restart", "shutdown", "logout", "empty_trash"]
    for action in destructive {
      XCTAssertEqual(systemReply(rpc, ["action": action]), refused, action)
    }
    XCTAssertEqual(mechanisms.executions, [], "nothing was asked of macOS")

    // The same request, inside one confirmed perform: honoured once.
    let confirmed = scope(confirmedPerforms: 1)
    XCTAssertEqual(
      systemReply(rpc, ["action": "restart"], scope: confirmed), ["ok": true] as NSDictionary)
    XCTAssertEqual(
      mechanisms.executions,
      [.appleScript("tell application \"System Events\" to restart", timeout: 10)])
    XCTAssertEqual(mechanisms.onMainThread, [false])
    XCTAssertEqual(
      systemReply(rpc, ["action": "shutdown"], scope: confirmed), refused,
      "the perform's consent is spent")
    XCTAssertEqual(mechanisms.executions.count, 1)

    // An action something undoes never spends a consent.
    let kept = scope(confirmedPerforms: 1)
    XCTAssertEqual(
      systemReply(rpc, ["action": "sleep"], scope: kept), ["ok": true] as NSDictionary)
    XCTAssertEqual(
      systemReply(rpc, ["action": "empty_trash"], scope: kept), ["ok": true] as NSDictionary)
    XCTAssertEqual(
      mechanisms.executions.last,
      .appleScript("tell application \"Finder\" to empty trash", timeout: 30))
  }

  /// A mechanism's failure is the reply's error; a host with no mechanisms
  /// wired refuses every action, and spends no consent on it.
  func testSystemActionFailuresAndAnUnwiredHostAnswerWhy() {
    let rpc = PluginHostRPC()
    XCTAssertNil(rpc.systemActions, "nothing is wired outside the resident's launch")
    let unwired: NSDictionary = ["ok": false, "error": "system actions unavailable"]
    XCTAssertEqual(systemReply(rpc, ["action": "sleep"]), unwired)
    let untouched = scope(confirmedPerforms: 1)
    XCTAssertEqual(systemReply(rpc, ["action": "restart"], scope: untouched), unwired)
    XCTAssertTrue(untouched.claimConfirmedPerform(), "the consent was not spent")

    let mechanisms = SystemActionStub()
    mechanisms.failure = "power management unavailable"
    rpc.systemActions = mechanisms
    XCTAssertEqual(
      systemReply(rpc, ["action": "sleep"]),
      ["ok": false, "error": "power management unavailable"] as NSDictionary)
    XCTAssertEqual(mechanisms.executions, [.sleepSystem])
  }

  func testSystemActionRefusesWhatItDoesNotDefine() {
    let rpc = PluginHostRPC()
    let mechanisms = SystemActionStub()
    rpc.systemActions = mechanisms
    let unsupported = "host.system_action requires a supported action"
    let malformed: [([String: Any], String)] = [
      ([:], unsupported),
      (["action": "hibernate"], unsupported),
      (["action": "Restart"], unsupported),
      (["action": ["sleep"]], unsupported),
      (["action": "sleep", "delay": 5], "invalid host.system_action params"),
      (["action": "restart", "confirmed": true], "invalid host.system_action params"),
    ]
    for (params, error) in malformed {
      XCTAssertEqual(
        systemReply(rpc, params, scope: scope(confirmedPerforms: 1)),
        ["ok": false, "error": error] as NSDictionary, "\(params)")
    }
    XCTAssertEqual(mechanisms.executions, [], "a plugin cannot confirm its own request")
  }

  /// The actions, the destructive ones and the refusal are the contract's.
  func testSystemActionsContractMatchesSpec() throws {
    let spec = try XCTUnwrap(try protocolSpec()["system_actions"] as? [String: Any])
    XCTAssertEqual(spec["actions"] as? [String], HostSystemAction.allCases.map(\.rawValue))
    XCTAssertEqual(
      spec["destructive"] as? [String],
      HostSystemAction.allCases.filter(\.isDestructive).map(\.rawValue))
    let errors = try XCTUnwrap(try protocolSpec()["errors"] as? [String: Any])
    XCTAssertEqual(
      errors["confirmation_required"] as? String, PluginProtocol.confirmationRequiredError)
  }

  /// The resident's mechanisms: the lock chord through the closure the app
  /// wires, each Apple Event as a fixed script through the runner. The
  /// power and screen-saver requests answer a refusal inside the test
  /// runner, which this suite never puts to the test.
  func testTheLiveMechanismsPostTheLockChordAndRunFixedScripts() throws {
    XCTAssertFalse(HostSystemActions.mechanismsAllowed, "inert inside the test runner")
    let chord = try XCTUnwrap(HotkeySyntax.parse(hotkey: SystemActionExecution.lockScreenShortcut))
    XCTAssertEqual(chord.virtualKey, UInt32(kVK_ANSI_Q))
    XCTAssertEqual(chord.eventFlags, [.maskControl, .maskCommand])

    var locks = 0
    var scripts: [String] = []
    var live = LiveSystemActions(lockScreen: {
      locks += 1
      return locks == 1
    })
    live.appleScript = { source, timeout in
      scripts.append("\(Int(timeout))s \(source)")
      return AppleScriptOutput(
        status: scripts.count == 1 ? 0 : 1, stdout: "",
        stderr: "execution error: Not authorized to send Apple events to Finder. (-1743)\n")
    }
    XCTAssertNil(live.perform(.lockScreenChord))
    XCTAssertEqual(live.perform(.lockScreenChord), "lock screen shortcut unavailable")
    XCTAssertEqual(locks, 2)
    XCTAssertNil(live.perform(HostSystemAction.logout.execution))
    XCTAssertEqual(
      live.perform(HostSystemAction.emptyTrash.execution),
      "applescript status=1 execution error: Not authorized to send Apple events to Finder. "
        + "(-1743)")
    XCTAssertEqual(
      scripts,
      [
        "10s tell application \"System Events\" to log out",
        "30s tell application \"Finder\" to empty trash",
      ])
    XCTAssertEqual(
      HostSystemAction.shutdown.execution,
      .appleScript("tell application \"System Events\" to shut down", timeout: 10))
    // Every action maps to a mechanism, and only the lock runs on main.
    XCTAssertEqual(
      HostSystemAction.allCases.filter {
        HostSystemActions.queue(for: $0.execution) === DispatchQueue.main
      },
      [.lockScreen])
  }

  // MARK: - host.process_signal (processSignals seam)

  private func signalReply(
    _ rpc: PluginHostRPC, _ params: [String: Any],
    scope: PluginHostRequestScope = PluginHostRequestScope(isCurrent: { true })
  ) -> NSDictionary {
    hostReply(rpc, "host.process_signal", params, capabilities: [.processSignal], scope: scope)
      as NSDictionary
  }

  /// A signal is refused, with the fixed error and before the mechanism is
  /// reached, unless a perform the user confirmed is in flight; that
  /// perform covers exactly one signal.
  func testAProcessSignalIsHonouredOnlyInsideAConfirmedPerform() {
    let rpc = PluginHostRPC()
    let mechanism = ProcessSignalStub()
    rpc.processSignals = mechanism
    let refused: NSDictionary = ["ok": false, "error": "requires a perform the user confirmed"]
    XCTAssertEqual(signalReply(rpc, ["pid": 4242, "signal": "term"]), refused)
    XCTAssertEqual(mechanism.sent, [], "the kernel was asked nothing")

    let confirmed = scope(confirmedPerforms: 1)
    XCTAssertEqual(
      signalReply(rpc, ["pid": 4242, "signal": "term"], scope: confirmed),
      ["ok": true] as NSDictionary)
    XCTAssertEqual(mechanism.sent, [.init(signal: .term, pid: 4242, onMainThread: false)])
    XCTAssertEqual(
      signalReply(rpc, ["pid": 4243, "signal": "term"], scope: confirmed), refused,
      "the perform's consent is spent")
    XCTAssertEqual(mechanism.sent.count, 1)
  }

  /// The pids no confirmation reaches: launchd, the caller's own process
  /// group, a group or every process, and the resident itself. Each is
  /// refused before the mechanism, and none spends the perform's consent.
  func testAProcessSignalNeverReachesLaunchdAGroupOrFlashItself() {
    let rpc = PluginHostRPC()
    let mechanism = ProcessSignalStub()
    rpc.processSignals = mechanism
    let confirmed = scope(confirmedPerforms: 1)
    let undecodable = "host.process_signal requires a pid above 1 and a supported signal"
    for pid in [1, 0, -1, -4242, Int(Int32.max) + 1] {
      XCTAssertEqual(
        signalReply(rpc, ["pid": pid, "signal": "term"], scope: confirmed),
        ["ok": false, "error": undecodable] as NSDictionary, "\(pid)")
    }
    XCTAssertEqual(
      signalReply(rpc, ["pid": Int(getpid()), "signal": "term"], scope: confirmed),
      ["ok": false, "error": "refusing to signal Flash itself"] as NSDictionary)
    XCTAssertEqual(mechanism.sent, [])
    XCTAssertTrue(confirmed.claimConfirmedPerform(), "no refusal spent the consent")

    XCTAssertEqual(HostProcessSignals.refusal(of: 1), "refusing pid 1")
    XCTAssertEqual(HostProcessSignals.refusal(of: 0), "refusing pid 0")
    XCTAssertEqual(HostProcessSignals.refusal(of: -7), "refusing pid -7")
    XCTAssertEqual(
      HostProcessSignals.refusal(of: 4242, own: 4242), "refusing to signal Flash itself")
    XCTAssertNil(HostProcessSignals.refusal(of: 4242, own: 99))
  }

  /// The kernel's reason is the reply's error; a host with no mechanism
  /// wired refuses every signal, and spends no consent on it.
  func testProcessSignalFailuresAndAnUnwiredHostAnswerWhy() {
    let rpc = PluginHostRPC()
    XCTAssertNil(rpc.processSignals, "nothing is wired outside the resident's launch")
    let untouched = scope(confirmedPerforms: 1)
    XCTAssertEqual(
      signalReply(rpc, ["pid": 4242, "signal": "term"], scope: untouched),
      ["ok": false, "error": "process signals unavailable"] as NSDictionary)
    XCTAssertTrue(untouched.claimConfirmedPerform(), "the consent was not spent")

    let mechanism = ProcessSignalStub()
    mechanism.failure = "No such process"
    rpc.processSignals = mechanism
    XCTAssertEqual(
      signalReply(rpc, ["pid": 4242, "signal": "term"], scope: scope(confirmedPerforms: 1)),
      ["ok": false, "error": "No such process"] as NSDictionary)
    XCTAssertEqual(mechanism.sent.map(\.pid), [4242])
  }

  func testProcessSignalRefusesWhatItDoesNotDefine() {
    let rpc = PluginHostRPC()
    let mechanism = ProcessSignalStub()
    rpc.processSignals = mechanism
    let undecodable = "host.process_signal requires a pid above 1 and a supported signal"
    let malformed: [([String: Any], String)] = [
      ([:], undecodable),
      (["signal": "term"], undecodable),
      (["pid": 4242], undecodable),
      (["pid": "4242", "signal": "term"], undecodable),
      (["pid": 4242.5, "signal": "term"], undecodable),
      (["pid": true, "signal": "term"], undecodable),
      (["pid": 4242, "signal": "kill"], undecodable),
      (["pid": 4242, "signal": "TERM"], undecodable),
      (["pid": 4242, "signal": 15], undecodable),
      (["pid": 4242, "signal": "term", "confirmed": true], "invalid host.process_signal params"),
      (["pid": 4242, "signal": "term", "group": true], "invalid host.process_signal params"),
    ]
    for (params, error) in malformed {
      XCTAssertEqual(
        signalReply(rpc, params, scope: scope(confirmedPerforms: 1)),
        ["ok": false, "error": error] as NSDictionary, "\(params)")
    }
    XCTAssertEqual(mechanism.sent, [], "a plugin cannot confirm its own request")
  }

  /// The signals are the contract's, and SIGTERM is the only one.
  func testProcessSignalsContractMatchesSpec() throws {
    let spec = try XCTUnwrap(try protocolSpec()["process_signals"] as? [String: Any])
    XCTAssertEqual(spec["signals"] as? [String], HostProcessSignal.allCases.map(\.rawValue))
    XCTAssertEqual(spec["min_pid"] as? Int, 2)
    XCTAssertEqual(HostProcessSignal.allCases.map(\.number), [SIGTERM])
  }

  /// The resident's own mechanism signals nothing inside the test runner,
  /// and never the pids the host refuses.
  func testTheLiveMechanismIsInertInsideTheTestRunner() {
    XCTAssertFalse(HostProcessSignals.mechanismsAllowed, "inert inside the test runner")
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["600"]
    XCTAssertNoThrow(try child.run())
    defer {
      child.terminate()
      child.waitUntilExit()
    }
    XCTAssertEqual(
      LiveProcessSignals().send(.term, to: child.processIdentifier),
      "process signals are inert inside the test runner")
    XCTAssertTrue(child.isRunning, "the child was not signalled")
  }

  /// End to end through the dispatcher, with a mechanism that really sends
  /// the signal: to the one child process this test spawned, and to nothing
  /// else. Unconfirmed, the child keeps running; confirmed, SIGTERM ends it.
  func testAConfirmedSignalTerminatesTheChildThisTestSpawned() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["600"]
    let exited = expectation(description: "the child exited")
    child.terminationHandler = { _ in exited.fulfill() }
    try child.run()
    defer { if child.isRunning { child.terminate() } }
    let rpc = PluginHostRPC()
    let mechanism = ChildProcessSignals(child: child)
    rpc.processSignals = mechanism
    let pid = Int(child.processIdentifier)

    XCTAssertEqual(
      signalReply(rpc, ["pid": pid, "signal": "term"]),
      ["ok": false, "error": "requires a perform the user confirmed"] as NSDictionary)
    XCTAssertTrue(child.isRunning, "an unconfirmed signal reaches nothing")

    XCTAssertEqual(
      signalReply(rpc, ["pid": pid, "signal": "term"], scope: scope(confirmedPerforms: 1)),
      ["ok": true] as NSDictionary)
    wait(for: [exited], timeout: 10)
    XCTAssertEqual(child.terminationReason, .uncaughtSignal)
    XCTAssertEqual(child.terminationStatus, SIGTERM)
    XCTAssertEqual(mechanism.refused, [], "only the child was ever signalled")
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
      "url not in the fetch allowlist")
    // Component boundary: the prefix "…/api" must NOT admit "…/apix".
    XCTAssertEqual(
      hostReply(
        rpc, "host.fetch", ["url": "https://example.com/apix"],
        capabilities: [.networkFetch], fetchURLs: allowlist)["error"] as? String,
      "url not in the fetch allowlist")

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
      browsers: BrowserEngineTable(), pluginID: "stale-operation",
      scope: PluginHostRequestScope(isCurrent: { false }),
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
    // Modifier names are the four the contract spells, lowercase.
    XCTAssertEqual(
      hostReply(
        rpc, "host.post_keys",
        ["pid": 123, "keys": [["key_code": Int(kVK_ANSI_8), "modifiers": ["Command"]]]],
        capabilities: [.accessibility])["error"] as? String,
      "unknown modifier: Command")
    XCTAssertEqual(captured.count, 2, "rejected payloads must never reach the poster")
  }

  // MARK: - host.ax_* routing (validation errors only; real trees are the
  // AX broker suite's business)

  /// The snapshot's roots, its node default and its budget are the
  /// contract's.
  func testAXSnapshotContractMatchesSpec() throws {
    let spec = try XCTUnwrap(try protocolSpec()["ax_snapshot"] as? [String: Any])
    XCTAssertEqual(spec["roots"] as? [String], PluginHostRequest.AX.SnapshotRoot.names)
    XCTAssertEqual(spec["default_max_nodes"] as? Int, AXBroker.defaultMaxNodes)
    XCTAssertEqual(spec["timeout_ms"] as? Int, AXBroker.snapshotTimeoutMs)
  }

  func testAXArmsRouteToTheBrokerAndSurfaceItsValidationErrors() {
    let rpc = PluginHostRPC()
    let caps: Set<PluginCapability> = [.accessibility]
    XCTAssertEqual(
      hostReply(rpc, "host.ax_snapshot", [:], capabilities: caps)["error"] as? String,
      "host.ax_snapshot requires pid")
    XCTAssertEqual(
      hostReply(rpc, "host.ax_snapshot", ["root": "menu_bar", "pid": 123], capabilities: caps)[
        "error"] as? String,
      "host.ax_snapshot takes no pid with root menu_bar")
    XCTAssertEqual(
      hostReply(rpc, "host.ax_snapshot", ["root": "menu_bar"], capabilities: [])["error"]
        as? String,
      "missing accessibility capability", "the menu bar is behind the same capability")
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
