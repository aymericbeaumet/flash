import Foundation

/// The host's copy of the plugin wire-protocol constants. The single source
/// of truth is `Plugins/_flash_plugin_specs/protocol.json`;
/// `PluginProtocolParityTests` reads that file and asserts every value here
/// equals it, so a drift fails the build instead of shipping a skewed host.
enum PluginProtocol {
  /// The ONLY protocol version the host speaks, echoed exactly by every
  /// plugin at initialize. Features are manifest declarations — there is no
  /// per-feature wire negotiation.
  static let version = 1

  // MARK: - Deadlines (milliseconds)

  /// `initialize` reply budget. Config `[plugins] startup_timeout` tunes the
  /// live value (FlashTunables); this is the spec default it mirrors.
  static let startupDeadlineMs = 5_000
  /// Per-keystroke `evaluate`.
  static let queryDeadlineMs = 50
  /// `search` + `hints` (late replies dropped, non-fatal). Config
  /// `[flashlight] live_query_timeout_ms` tunes the live value.
  static let liveDeadlineMs = 1_000
  /// All four `perform` kinds; a manifest `commands[].timeout_ms` overrides
  /// per entry.
  static let performDeadlineMs = 10_000
  /// Reply budget for the idle-liveness `ping`; ONE miss tears down.
  static let pingDeadlineMs = 10_000
  /// Inbound silence (with nothing in flight) before the host pings.
  static let idleBeforePingMs = 60_000
  /// stdin-close → SIGTERM; +500 ms → SIGKILL.
  static let shutdownGraceMs = 1_000

  // MARK: - Quotas (atomic rejection: any violation rejects the whole payload)

  static let maxFrameBytes = 10 * 1024 * 1024
  static let maxCatalogRows = 10_000
  static let maxCatalogBytes = 4 * 1024 * 1024
  static let maxTitleBytes = 4 * 1024
  static let maxURLBytes = 16 * 1024
  static let maxMetadataEntries = 64
  static let maxMetadataKeyBytes = 256
  static let maxMetadataValueBytes = 64 * 1024
  static let maxEffectTextBytes = 64 * 1024
  static let maxAnswers = 16
  static let maxAnswersBytes = 256 * 1024
  static let maxAnswerFieldBytes = 16 * 1024
  static let maxClipboardWriteBytes = 1_048_576
  static let maxNotifyMessageBytes = 1_024
  static let maxStorageKeyBytes = 128
  static let maxStorageValueBytes = 65_536
  static let maxStorageEntries = 256
  static let maxFetchResponseBytes = 1_048_576
  static let fetchTimeoutMs = 8_000

  // MARK: - Perform

  /// The four `perform` kinds, the universal action vocabulary.
  static let performKinds = ["resolve", "command", "action", "navigate"]

  // MARK: - Canonical error strings (spec-pinned EXACT text)

  static func unknownMethodError(_ method: String) -> String {
    "unknown method: \(method)"
  }
  /// Emitted by the plugin, never the host; kept here for spec parity.
  static let protocolMismatchErrorTemplate =
    "protocol version mismatch: host v<H>, plugin v1"
  static let initializeRepeatedError = "initialize may only be called once"
  static let hostClosedError = "host closed stdin"
  static let hostCallTimeoutError = "host call timed out"
  static let frameOverflowError = "response exceeded outbound frame limit"
  static func capabilityDeniedError(_ capability: String) -> String {
    "missing \(capability) capability"
  }
}
