import AppKit
import FlashCore
import Foundation
import XCTest

@testable import flash

/// Asserts the host's wire constants equal the machine-readable contract in
/// `Plugins/_flash_plugin_rust/protocol.json` — the single source of truth.
/// A drift here means the host redefined the protocol without updating the
/// contract (or vice versa), which repo rule 7 forbids shipping.
final class PluginProtocolParityTests: XCTestCase {
  private func spec() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Plugins/_flash_plugin_rust/protocol.json")
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testProtocolVersionMatchesSpec() throws {
    XCTAssertEqual(try spec()["protocol_version"] as? Int, PluginProtocol.version)
  }

  /// The host mints trace ids and checks those plugins echo back against
  /// the pattern the contract pins.
  func testTraceIDsMatchSpec() throws {
    let trace = try XCTUnwrap(try spec()["trace"] as? [String: Any])
    let pattern = try XCTUnwrap(trace["pattern"] as? String)
    XCTAssertEqual(pattern, "^[0-9a-z]{1,16}$")
    let minted = Trace.ID(value: UInt64(Date().timeIntervalSince1970 * 1000) << 12).text
    XCTAssertNotNil(minted.range(of: pattern, options: .regularExpression), minted)
    XCTAssertNotNil(Trace.ID(value: .max).text.range(of: pattern, options: .regularExpression))
    for text in ["k3f9", "0", String(repeating: "z", count: 16)] {
      XCTAssertTrue(Trace.isValid(text), text)
    }
    for text in ["", "K3F9", "k3-f9", String(repeating: "z", count: 17)] {
      XCTAssertFalse(Trace.isValid(text), text)
    }
  }

  func testDeadlineTableMatchesSpec() throws {
    let deadlines = try XCTUnwrap(try spec()["deadlines_ms"] as? [String: Any])
    XCTAssertEqual(
      Set(deadlines.keys.filter { !$0.hasPrefix("$") }),
      [
        "startup", "query", "hints", "text_grid", "perform", "ping", "idle_before_ping",
        "shutdown_grace",
      ])
    XCTAssertEqual(deadlines["startup"] as? Int, PluginProtocol.startupDeadlineMs)
    XCTAssertEqual(deadlines["query"] as? Int, PluginProtocol.queryDeadlineMs)
    XCTAssertEqual(deadlines["hints"] as? Int, PluginProtocol.hintsDeadlineMs)
    XCTAssertEqual(deadlines["text_grid"] as? Int, PluginProtocol.textGridDeadlineMs)
    XCTAssertEqual(deadlines["perform"] as? Int, PluginProtocol.performDeadlineMs)
    XCTAssertEqual(deadlines["ping"] as? Int, PluginProtocol.pingDeadlineMs)
    XCTAssertEqual(deadlines["idle_before_ping"] as? Int, PluginProtocol.idleBeforePingMs)
    XCTAssertEqual(deadlines["shutdown_grace"] as? Int, PluginProtocol.shutdownGraceMs)
    // The config default mirrors the spec's startup entry.
    XCTAssertEqual(
      Config().plugins.startupTimeoutSeconds * 1_000, PluginProtocol.startupDeadlineMs)
  }

  /// The two `text_grid` line shapes the host decodes are the contract's.
  func testTextGridLineShapesMatchSpec() throws {
    let shapes = try XCTUnwrap(try spec()["text_grid_line"] as? [String: Any])
    XCTAssertEqual(
      Set(try XCTUnwrap(shapes["text"] as? [String])), PluginWireCodec.textGridTextLineKeys)
    XCTAssertEqual(
      Set(try XCTUnwrap(shapes["format"] as? [String])), PluginWireCodec.textGridFormatLineKeys)
    let methods = try XCTUnwrap(try spec()["methods"] as? [String: Any])
    let hostToPlugin = try XCTUnwrap(methods["host_to_plugin"] as? [String: Any])
    XCTAssertNotNil(hostToPlugin["text_grid"])
  }

  func testQuotaTableMatchesSpec() throws {
    let quotas = try XCTUnwrap(try spec()["quotas"] as? [String: Any])
    XCTAssertEqual(quotas["frame_bytes"] as? Int, PluginProtocol.maxFrameBytes)
    XCTAssertEqual(quotas["catalog_rows"] as? Int, PluginProtocol.maxCatalogRows)
    XCTAssertEqual(quotas["catalog_bytes"] as? Int, PluginProtocol.maxCatalogBytes)
    XCTAssertEqual(quotas["title_bytes"] as? Int, PluginProtocol.maxTitleBytes)
    XCTAssertEqual(quotas["url_bytes"] as? Int, PluginProtocol.maxURLBytes)
    XCTAssertEqual(quotas["metadata_entries"] as? Int, PluginProtocol.maxMetadataEntries)
    XCTAssertEqual(quotas["metadata_key_bytes"] as? Int, PluginProtocol.maxMetadataKeyBytes)
    XCTAssertEqual(quotas["metadata_value_bytes"] as? Int, PluginProtocol.maxMetadataValueBytes)
    XCTAssertEqual(quotas["effect_text_bytes"] as? Int, PluginProtocol.maxEffectTextBytes)
    XCTAssertEqual(quotas["answers"] as? Int, PluginProtocol.maxAnswers)
    XCTAssertEqual(quotas["answers_bytes"] as? Int, PluginProtocol.maxAnswersBytes)
    XCTAssertEqual(quotas["answer_field_bytes"] as? Int, PluginProtocol.maxAnswerFieldBytes)
    XCTAssertEqual(quotas["fetch_response_bytes"] as? Int, PluginProtocol.maxFetchResponseBytes)
    XCTAssertEqual(quotas["fetch_timeout_ms"] as? Int, PluginProtocol.fetchTimeoutMs)
    XCTAssertEqual(quotas["text_grid_dimension"] as? Int, PluginProtocol.maxTextGridDimension)
  }

  /// `host.applescript` runs under the contract's bounds: the host clamps a
  /// plugin's timeout, caps the source and the result, and runs at most
  /// `concurrency` scripts of one plugin at once.
  func testAppleScriptBoundsMatchSpec() throws {
    let bounds = try XCTUnwrap(try spec()["applescript"] as? [String: Any])
    XCTAssertEqual(
      Set(bounds.keys.filter { !$0.hasPrefix("$") }),
      [
        "script_bytes", "result_bytes", "default_timeout_ms", "max_timeout_ms", "concurrency",
        "operations",
      ])
    XCTAssertEqual(bounds["script_bytes"] as? Int, PluginProtocol.maxAppleScriptScriptBytes)
    XCTAssertEqual(bounds["result_bytes"] as? Int, PluginProtocol.maxAppleScriptResultBytes)
    XCTAssertEqual(
      bounds["default_timeout_ms"] as? Int, PluginProtocol.appleScriptDefaultTimeoutMs)
    XCTAssertEqual(bounds["max_timeout_ms"] as? Int, PluginProtocol.appleScriptMaxTimeoutMs)
    XCTAssertEqual(bounds["concurrency"] as? Int, PluginProtocol.appleScriptConcurrency)
    let methods = try XCTUnwrap(try spec()["methods"] as? [String: Any])
    let rpcs = try XCTUnwrap(methods["plugin_to_host_rpcs"] as? [String: Any])
    XCTAssertEqual(rpcs["host.applescript"] as? String, PluginCapability.appleEvents.rawValue)
  }

  func testCanonicalErrorStringsMatchSpec() throws {
    let errors = try XCTUnwrap(try spec()["errors"] as? [String: Any])
    XCTAssertEqual(
      errors["unknown_method"] as? String, PluginProtocol.unknownMethodError("<method>"))
    XCTAssertEqual(
      errors["protocol_mismatch"] as? String, PluginProtocol.protocolMismatchErrorTemplate)
    XCTAssertEqual(
      errors["initialize_repeated"] as? String, PluginProtocol.initializeRepeatedError)
    XCTAssertEqual(errors["host_closed"] as? String, PluginProtocol.hostClosedError)
    XCTAssertEqual(errors["host_call_timeout"] as? String, PluginProtocol.hostCallTimeoutError)
    XCTAssertEqual(errors["frame_overflow"] as? String, PluginProtocol.frameOverflowError)
    XCTAssertEqual(errors["request_capacity"] as? String, PluginProtocol.requestCapacityError)
    XCTAssertEqual(errors["host_call_capacity"] as? String, PluginProtocol.hostCallCapacityError)
    XCTAssertEqual(errors["deadline_exceeded"] as? String, PluginProtocol.deadlineExceededError)
    XCTAssertEqual(
      errors["capability_denied"] as? String,
      PluginProtocol.capabilityDeniedError("<capability>"))
  }

  func testHostTransportAdmissionMatchesSpec() throws {
    let limits = try XCTUnwrap(try spec()["transport_limits"] as? [String: Any])
    XCTAssertEqual(limits["host_pending_requests"] as? Int, PluginProtocol.maxPendingRequests)
    XCTAssertEqual(limits["host_host_rpcs"] as? Int, PluginProtocol.maxHostRPCs)
    XCTAssertEqual(limits["host_outbound_frames"] as? Int, PluginProtocol.maxOutboundFrames)
    XCTAssertEqual(limits["host_outbound_bytes"] as? Int, PluginProtocol.maxOutboundBytes)
    XCTAssertEqual(limits["host_inbound_frames"] as? Int, PluginProtocol.maxInboundFrames)
    XCTAssertEqual(limits["host_inbound_bytes"] as? Int, PluginProtocol.maxInboundBytes)
  }

  func testPollBoundsMatchSpec() throws {
    let poll = try XCTUnwrap(try spec()["poll"] as? [String: Any])
    XCTAssertEqual(
      poll["priorities"] as? [String], PluginProtocol.pollPriorities.map(\.name),
      "plugins get every priority but the core-only system one")
    XCTAssertFalse(PluginProtocol.pollPriorities.contains { $0.scheduler == .system })
    XCTAssertEqual(poll["min_every_ms"] as? Int, PollScheduler.minimumIntervalMs)
    XCTAssertEqual(poll["max_seconds"] as? Int, PluginProtocol.pollMaxSeconds)
    XCTAssertEqual(poll["max_registrations"] as? Int, PluginProtocol.pollMaxRegistrations)
    XCTAssertEqual(poll["max_name_bytes"] as? Int, PluginProtocol.pollMaxNameBytes)
  }

  func testCapabilityRegistryMatchesSpec() throws {
    let capabilities = try XCTUnwrap(try spec()["capabilities"] as? [String])
    XCTAssertEqual(
      Set(capabilities),
      Set(PluginCapability.allCases.map(\.rawValue)),
      "the capability registry is frozen: additions allowed, renames never")
  }

  /// The manifest `lifecycle` table: its one value, what a
  /// `publish_then_exit` plugin must and must not declare, what runs it
  /// again and the state it rests in.
  func testLifecycleDeclarationsMatchSpec() throws {
    let lifecycle = try XCTUnwrap(try spec()["lifecycle"] as? [String: Any])
    XCTAssertEqual(
      lifecycle["values"] as? [String], PluginLifecycleDeclaration.allCases.map(\.rawValue))
    let publishThenExit = try XCTUnwrap(lifecycle["publish_then_exit"] as? [String: Any])
    XCTAssertEqual(publishThenExit["requires"] as? [String], ["exec", "sources"])
    XCTAssertEqual(
      publishThenExit["forbids"] as? [String], PluginManifest.publishThenExitForbiddenSurfaces)
    XCTAssertEqual(
      publishThenExit["respawn"] as? [String],
      ["settings_changed", "watched_file_changed", "plugins_reload", "plugin_files_changed"])
    XCTAssertEqual(publishThenExit["state"] as? String, PluginRuntimeState.published.rawValue)
  }

  func testPerformKindsMatchSpec() throws {
    let kinds = try XCTUnwrap(try spec()["perform_kinds"] as? [String])
    XCTAssertEqual(kinds, PluginProtocol.performKinds)
    XCTAssertEqual(kinds, ["resolve", "command", "navigate"], "no dual reader for a retired kind")
  }

  /// A `perform {kind: "command"}` carries the command's two words, its
  /// argument words and, for a core command, the focused-app context.
  func testPerformCommandShapeMatchesSpec() throws {
    let shape = try XCTUnwrap(try spec()["perform_command"] as? [String: Any])
    XCTAssertEqual(shape["required"] as? [String], ["command", "subcommand", "args"])
    XCTAssertEqual(shape["optional"] as? [String], ["context"])
    XCTAssertEqual(
      Set(try XCTUnwrap(shape["context"] as? [String])),
      Set(PluginWireCodec.contextJSON(Self.sampleContext).keys))
  }

  private static let sampleContext = AppContext(
    bundleIdentifier: "com.example.app", processID: 1, runningApp: NSRunningApplication.current,
    frontWindowFrame: .zero, allScreensFrame: .zero)

  /// A hint target carries exactly the contract's keys: geometry and
  /// semantics, nothing about the mode a click leaves.
  func testHintTargetShapeMatchesSpec() throws {
    let shape = try XCTUnwrap(try spec()["hint_target"] as? [String: Any])
    let required = try XCTUnwrap(shape["required"] as? [String])
    XCTAssertEqual(required, ["id", "frame"])
    let optional = try XCTUnwrap(shape["optional"] as? [String])
    XCTAssertEqual(Set(required + optional), PluginWireCodec.targetKeys)
  }

  func testRowShapeMatchesSpec() throws {
    let row = try XCTUnwrap(try spec()["row"] as? [String: Any])
    XCTAssertEqual(row["required"] as? [String], ["source", "title"])
    XCTAssertEqual(row["optional"] as? [String], ["url", "metadata", "effect"])
  }

  func testHostEventsMatchSpec() throws {
    let events = try XCTUnwrap(try spec()["host_events"] as? [String: Any])
    XCTAssertEqual(events["names"] as? [String], PluginProtocol.hostEvents)
    let replacement = try XCTUnwrap(events["replacement"] as? [String])
    XCTAssertEqual(replacement, PluginProtocol.replacementEvents)
    XCTAssertTrue(
      Set(replacement).isSubset(of: PluginProtocol.hostEvents),
      "every replacement kind is a host event")
    // `core:ax.changed` names one of the notifications the host observes.
    XCTAssertEqual(events["ax_notifications"] as? [String], AppMonitor.observedNotifications)
    XCTAssertTrue(
      Set(AppMonitor.lightObservedNotifications + AppMonitor.focusedWindowObservedNotifications)
        .isSubset(of: AppMonitor.observedNotifications))
    for name in [HostEvent.networkChanged.rawValue, HostEvent.volumesChanged.rawValue] {
      XCTAssertTrue(PluginProtocol.hostEvents.contains(name), name)
      XCTAssertTrue(replacement.contains(name), "\(name) is a payload-free replacement signal")
    }
  }

  /// The contract lists exactly the methods the host sends a plugin: a method
  /// it no longer sends (once `search`) leaves the contract with it.
  func testHostToPluginMethodsMatchWhatTheHostSends() throws {
    let methods = try XCTUnwrap(try spec()["methods"] as? [String: Any])
    let contract = try XCTUnwrap(methods["host_to_plugin"] as? [String: Any])
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/flash/App/Plugins")
    let literal = try NSRegularExpression(pattern: #""?method"?: "([a-z_]+)""#)
    var sent = Set<String>()
    let files = try XCTUnwrap(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    for case let file as URL in files where file.pathExtension == "swift" {
      let text = try String(contentsOf: file, encoding: .utf8)
      for match in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        if let range = Range(match.range(at: 1), in: text) { sent.insert(String(text[range])) }
      }
    }
    XCTAssertEqual(sent, Set(contract.keys))
  }

  /// A `core:*` event the host emits but the contract does not name would
  /// reach plugins unpinned: every dotted `core:` literal in the host is one
  /// of the contract's events, and is spelled only in `HostEvent`, which
  /// every emitting site and listener check names by case.
  func testEveryEventTheHostEmitsIsPinned() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/flash")
    let literal = try NSRegularExpression(pattern: #""(core:[a-z]+(?:\.[a-z]+)+)""#)
    var emitted = Set<String>()
    let files = try XCTUnwrap(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    var spelledOutside: Set<String> = []
    for case let file as URL in files where file.pathExtension == "swift" {
      let text = try String(contentsOf: file, encoding: .utf8)
      for match in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let range = Range(match.range(at: 1), in: text) else { continue }
        emitted.insert(String(text[range]))
        if file.lastPathComponent != "PluginProtocol.swift" {
          spelledOutside.insert("\(file.lastPathComponent): \(text[range])")
        }
      }
    }
    XCTAssertEqual(spelledOutside, [], "name host events by HostEvent case")
    XCTAssertEqual(emitted, Set(HostEvent.allCases.map(\.rawValue)))
    XCTAssertFalse(emitted.isEmpty)
    XCTAssertTrue(
      emitted.isSubset(of: PluginProtocol.hostEvents),
      "unpinned: \(emitted.subtracting(PluginProtocol.hostEvents).sorted())")
  }
}

/// The typed host events: one case per contract name, the replacement subset
/// derived from the cases, and a `PluginEvent` built from a case.
final class HostEventTests: XCTestCase {
  func testTheCasesAreTheContractsEventsAndReplacementsInOrder() {
    XCTAssertEqual(HostEvent.allCases.map(\.rawValue), PluginProtocol.hostEvents)
    XCTAssertEqual(
      PluginProtocol.replacementEvents,
      [
        "core:apps.changed", "core:focus.changed", "core:window.focus.changed", "core:ax.changed",
        "core:config.changed", "core:power.changed", "core:network.changed",
        "core:volumes.changed", "core:status.observed", "core:space.changed",
        "core:workspace.changed", "core:mode.changed",
      ])
    let event = PluginEvent(.powerChanged)
    XCTAssertEqual(event.name, "core:power.changed")
    XCTAssertTrue(event.payload.isEmpty)
    XCTAssertNil(event.bundleID)
  }
}

/// The plugin protocol page speaks the contract: every quick-start line is a
/// frame `protocol.json` allows, in a consistent exchange, and the errors
/// table spells every canonical error string.
final class PluginProtocolDocsTests: XCTestCase {
  private let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private func spec() throws -> [String: Any] {
    let data = try Data(
      contentsOf: root.appendingPathComponent("Plugins/_flash_plugin_rust/protocol.json"))
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func page() throws -> String {
    try String(contentsOf: root.appendingPathComponent("docs/plugin-protocol.md"), encoding: .utf8)
  }

  private func keys(_ object: Any?) -> Set<String> {
    Set(((object as? [String: Any]) ?? [:]).keys.filter { !$0.hasPrefix("$") })
  }

  func testTheQuickStartIsAValidExchange() throws {
    let spec = try spec()
    let methods = try XCTUnwrap(spec["methods"] as? [String: Any])
    let hostMethods = keys(methods["host_to_plugin"])
    let pluginNotifications = keys(methods["plugin_to_host_notifications"])
    let pluginRPCs = keys(methods["plugin_to_host_rpcs"])
    let deadlines = try XCTUnwrap(spec["deadlines_ms"] as? [String: Any])
    let deadlineName = [
      "initialize": "startup", "evaluate": "query", "hints": "hints", "text_grid": "text_grid",
      "perform": "perform", "ping": "ping",
    ]
    let hostEvents = Set(
      try XCTUnwrap((spec["host_events"] as? [String: Any])?["names"] as? [String]))

    let page = try page()
    let section = try XCTUnwrap(page.range(of: "## Quick start\n"))
    let block = try XCTUnwrap(
      page[section.upperBound...].components(separatedBy: "```").dropFirst().first)
    var hostRequests = Set<Int>()
    var pluginRequests = Set<Int>()
    var frames = 0
    for line in block.split(separator: "\n") {
      let fromHost = line.hasPrefix("▶ ")
      guard fromHost || line.hasPrefix("◀ ") else { continue }
      frames += 1
      let json = Data(line.dropFirst(2).utf8)
      let frame = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: json) as? [String: Any], String(line))
      let method = frame["method"] as? String
      let id = frame["id"] as? Int
      switch (id, method) {
      case (let id?, let method?):
        XCTAssertGreaterThan(id, 0, String(line))
        if fromHost {
          XCTAssertTrue(hostMethods.contains(method), String(line))
          XCTAssertTrue(hostRequests.insert(id).inserted, "host id reused: \(line)")
          let budget = try XCTUnwrap(deadlines[deadlineName[method] ?? ""] as? Int, method)
          let left = try XCTUnwrap(frame["deadline_ms"] as? Int, String(line))
          XCTAssertTrue((1...budget).contains(left), String(line))
        } else {
          XCTAssertTrue(pluginRPCs.contains(method), String(line))
          XCTAssertTrue(pluginRequests.insert(id).inserted, "plugin id reused: \(line)")
        }
      case (let id?, nil):
        let result = try XCTUnwrap(frame["result"] as? [String: Any], String(line))
        XCTAssertNotNil(result["ok"] as? Bool, String(line))
        // A reply answers a request the other side made earlier.
        XCTAssertNotNil(
          fromHost ? pluginRequests.remove(id) : hostRequests.remove(id), "unasked: \(line)")
      case (nil, let method?):
        if fromHost {
          XCTAssertEqual(method, "event", String(line))
          let params = try XCTUnwrap(frame["params"] as? [String: Any])
          let name = try XCTUnwrap(params["name"] as? String)
          XCTAssertTrue(
            hostEvents.contains(name) || name.hasPrefix("core:poll:"), "unknown event \(name)")
        } else {
          XCTAssertTrue(pluginNotifications.contains(method), String(line))
        }
      case (nil, nil):
        XCTFail("neither a request, a reply nor a notification: \(line)")
      }
    }
    XCTAssertGreaterThan(frames, 8)
    XCTAssertEqual(hostRequests, [], "every host request is answered")
    XCTAssertEqual(pluginRequests, [], "every host RPC is answered")
  }

  func testTheErrorsTableSpellsEveryCanonicalError() throws {
    let errors = try XCTUnwrap(try spec()["errors"] as? [String: Any])
    let page = try page()
    for (name, value) in errors where !name.hasPrefix("$") {
      let text = try XCTUnwrap(value as? String)
      XCTAssertTrue(page.contains("| `\(name)` | `\(text)` |"), name)
    }
  }
}
