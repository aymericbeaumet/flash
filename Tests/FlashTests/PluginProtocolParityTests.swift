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
    XCTAssertEqual(deadlines["startup"] as? Int, PluginProtocol.startupDeadlineMs)
    XCTAssertEqual(deadlines["query"] as? Int, PluginProtocol.queryDeadlineMs)
    XCTAssertEqual(deadlines["live"] as? Int, PluginProtocol.liveDeadlineMs)
    XCTAssertEqual(deadlines["hints"] as? Int, PluginProtocol.hintsDeadlineMs)
    XCTAssertEqual(deadlines["perform"] as? Int, PluginProtocol.performDeadlineMs)
    XCTAssertEqual(deadlines["ping"] as? Int, PluginProtocol.pingDeadlineMs)
    XCTAssertEqual(deadlines["idle_before_ping"] as? Int, PluginProtocol.idleBeforePingMs)
    XCTAssertEqual(deadlines["shutdown_grace"] as? Int, PluginProtocol.shutdownGraceMs)
    // The config defaults mirror the spec's startup/live entries.
    XCTAssertEqual(
      Config().plugins.startupTimeoutSeconds * 1_000, PluginProtocol.startupDeadlineMs)
    XCTAssertEqual(Config().flashlight.liveQueryTimeoutMs, PluginProtocol.liveDeadlineMs)
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
    XCTAssertEqual(
      quotas["clipboard_write_bytes"] as? Int, PluginProtocol.maxClipboardWriteBytes)
    XCTAssertEqual(quotas["notify_message_bytes"] as? Int, PluginProtocol.maxNotifyMessageBytes)
    XCTAssertEqual(quotas["storage_key_bytes"] as? Int, PluginProtocol.maxStorageKeyBytes)
    XCTAssertEqual(quotas["storage_value_bytes"] as? Int, PluginProtocol.maxStorageValueBytes)
    XCTAssertEqual(quotas["storage_entries"] as? Int, PluginProtocol.maxStorageEntries)
    XCTAssertEqual(quotas["fetch_response_bytes"] as? Int, PluginProtocol.maxFetchResponseBytes)
    XCTAssertEqual(quotas["fetch_timeout_ms"] as? Int, PluginProtocol.fetchTimeoutMs)
    // The host RPC layer enforces the same numbers.
    XCTAssertEqual(PluginHostRPC.maxClipboardWriteBytes, PluginProtocol.maxClipboardWriteBytes)
    XCTAssertEqual(PluginHostRPC.maxNotifyMessageBytes, PluginProtocol.maxNotifyMessageBytes)
    XCTAssertEqual(PluginHostRPC.maxStorageKeyBytes, PluginProtocol.maxStorageKeyBytes)
    XCTAssertEqual(PluginHostRPC.maxStorageValueBytes, PluginProtocol.maxStorageValueBytes)
    XCTAssertEqual(PluginHostRPC.maxStorageEntries, PluginProtocol.maxStorageEntries)
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

  func testPerformKindsMatchSpec() throws {
    let kinds = try XCTUnwrap(try spec()["perform_kinds"] as? [String])
    XCTAssertEqual(kinds, PluginProtocol.performKinds)
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
    for name in [PluginProtocol.networkChangedEvent, PluginProtocol.volumesChangedEvent] {
      XCTAssertTrue(PluginProtocol.hostEvents.contains(name), name)
      XCTAssertTrue(replacement.contains(name), "\(name) is a payload-free replacement signal")
    }
  }

  /// A `core:*` event the host emits but the contract does not name would
  /// reach plugins unpinned: every dotted `core:` literal in the host is one
  /// of the contract's events.
  func testEveryEventTheHostEmitsIsPinned() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/flash")
    let literal = try NSRegularExpression(pattern: #""(core:[a-z]+(?:\.[a-z]+)+)""#)
    var emitted = Set<String>()
    let files = try XCTUnwrap(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    for case let file as URL in files where file.pathExtension == "swift" {
      let text = try String(contentsOf: file, encoding: .utf8)
      for match in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        if let range = Range(match.range(at: 1), in: text) { emitted.insert(String(text[range])) }
      }
    }
    XCTAssertFalse(emitted.isEmpty)
    XCTAssertTrue(
      emitted.isSubset(of: PluginProtocol.hostEvents),
      "unpinned: \(emitted.subtracting(PluginProtocol.hostEvents).sorted())")
  }
}
