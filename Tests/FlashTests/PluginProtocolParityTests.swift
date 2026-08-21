import Foundation
import XCTest

@testable import flash

/// Asserts the host's wire constants equal the machine-readable contract in
/// `Plugins/_flash_plugin_specs/protocol.json` — the single source of truth.
/// A drift here means the host redefined the protocol without updating the
/// spec (or vice versa), which repo rule 9 forbids shipping.
final class PluginProtocolParityTests: XCTestCase {
  private func spec() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Plugins/_flash_plugin_specs/protocol.json")
    let data = try Data(contentsOf: url)
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func testProtocolVersionMatchesSpec() throws {
    XCTAssertEqual(try spec()["protocol_version"] as? Int, PluginProtocol.version)
  }

  func testDeadlineTableMatchesSpec() throws {
    let deadlines = try XCTUnwrap(try spec()["deadlines_ms"] as? [String: Any])
    XCTAssertEqual(deadlines["startup"] as? Int, PluginProtocol.startupDeadlineMs)
    XCTAssertEqual(deadlines["query"] as? Int, PluginProtocol.queryDeadlineMs)
    XCTAssertEqual(deadlines["live"] as? Int, PluginProtocol.liveDeadlineMs)
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
    XCTAssertEqual(
      errors["capability_denied"] as? String,
      PluginProtocol.capabilityDeniedError("<capability>"))
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
}
