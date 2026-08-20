import CoreGraphics
import FlashCore
import Foundation

/// Wire-payload validation and (de)serialization for the plugin protocol:
/// the protocol version handshake checks, the catalog/query/hint-target
/// quota constants, and the strict decoders that reject a whole payload on
/// the first malformed row. Pure functions over `[String: Any]` frames —
/// no process state.
enum PluginWireCodec {

  /// Wire-protocol version the host speaks — the ONLY version it speaks.
  /// The required echo in the initialize reply is the stale-binary
  /// diagnostic: a plugin built against another protocol fails the
  /// handshake with a version message instead of decoding oddly.
  // v1: the protocol counter restarted at the NDJSON reset — one JSON
  // object per newline-terminated line, no jsonrpc envelope, tri-state
  // `outcome` on action replies, readiness by first-snapshot proof.
  static let protocolVersion = 1
  static let maxCatalogCandidates = 10_000
  static let maxCatalogEncodedBytes = 4 * 1024 * 1024
  static let maxQueryAnswersPerEvaluator = 16
  static let maxQueryEncodedBytes = 256 * 1024
  static let maxCandidateTitleBytes = 4 * 1024
  static let maxCandidateURLBytes = 16 * 1024
  static let maxCandidateMetadataEntries = 64
  static let maxCandidateMetadataKeyBytes = 256
  static let maxCandidateMetadataValueBytes = 64 * 1024
  static let maxCandidateEffectBytes = 64 * 1024
  static let maxQueryFieldBytes = 16 * 1024

  static func acceptsProtocolVersion(_ response: [String: Any]?) -> Bool {
    protocolVersionValue(response) == protocolVersion
  }

  static func protocolVersionValue(_ response: [String: Any]?) -> Int? {
    if let value = response?["protocol_version"] as? Int { return value }
    return (response?["protocol_version"] as? NSNumber)?.intValue
  }

  /// Serialize one frame as a newline-terminated JSON line.
  /// JSONSerialization never emits raw newlines without .prettyPrinted, so
  /// the delimiter is unambiguous.
  static func encodeFrame(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(0x0A)
    return data
  }

  static func decodeFrame(_ line: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
      throw PluginError.invalidReference("non-object IPC frame")
    }
    return object
  }

  static func responsePayloadLimit(for method: String) -> Int? {
    // Allow a small fixed envelope overhead above the SDK's encoded
    // `{ candidates: ... }` / `{ answers: ... }` boundary. The response also
    // carries JSON-RPC id/result keys that are outside those SDK-owned values.
    switch method {
    case "sources.snapshot":
      return maxCatalogEncodedBytes + 1_024
    case "query.evaluate":
      return maxQueryEncodedBytes + 1_024
    default:
      return nil
    }
  }

  static func target(from raw: [String: Any], sourceID: String) -> PluginWireTarget? {
    guard let id = raw["id"] as? String else { return nil }
    let frameRaw = raw["frame"] as? [String: Any] ?? raw
    guard
      let x = number(frameRaw["x"]),
      let y = number(frameRaw["y"]),
      let width = number(frameRaw["width"]),
      let height = number(frameRaw["height"]),
      width > 0, height > 0
    else { return nil }
    let role = raw["role"] as? String
    // A plugin can state explicitly whether committing this target should
    // enter insert mode. When it doesn't, fall back to the same AX-role
    // heuristic the core walk uses so text-field hints still type.
    let entersInsertMode =
      raw["enters_insert_mode"] as? Bool
      ?? JumpTarget.textInputRoles.contains(role ?? "")
    let priority: FlashPriority
    if let rawPriority = raw["priority"] as? String {
      guard let parsed = FlashPriority(rawValue: rawPriority) else { return nil }
      priority = parsed
    } else {
      priority = .normal
    }
    return PluginWireTarget(
      id: id,
      frame: CGRect(x: x, y: y, width: width, height: height),
      role: role,
      label: raw["label"] as? String,
      url: raw["url"] as? String,
      pid: (raw["pid"] as? Int).map(pid_t.init),
      entersInsertMode: entersInsertMode,
      sourceID: sourceID,
      priority: priority)
  }

  static func catalogCandidates(
    from raw: [[String: Any]],
    sourceID: String,
    allowedSources: Set<String>
  ) -> [Candidate]? {
    guard raw.count <= maxCatalogCandidates else { return nil }
    var aggregateBytes = 0
    var candidates: [Candidate] = []
    candidates.reserveCapacity(raw.count)
    for item in raw {
      guard
        let decoded = decodedCatalogCandidate(
          from: item,
          sourceID: sourceID,
          allowedSources: allowedSources),
        let nextBytes = addingBytes(
          aggregateBytes,
          decoded.stringBytes,
          limit: maxCatalogEncodedBytes)
      else {
        // A source snapshot is atomic. Keeping the valid prefix would expose a
        // deterministic but incomplete catalog and hide the plugin defect.
        return nil
      }
      aggregateBytes = nextBytes
      candidates.append(decoded.candidate)
    }
    return candidates
  }

  private static func decodedCatalogCandidate(
    from raw: [String: Any],
    sourceID: String,
    allowedSources: Set<String>
  ) -> (candidate: Candidate, stringBytes: Int)? {
    let allowedKeys: Set<String> = ["title", "url", "metadata", "effect"]
    guard Set(raw.keys).isSubset(of: allowedKeys),
      let title = raw["title"] as? String,
      !title.isEmpty,
      title.utf8.count <= maxCandidateTitleBytes
    else { return nil }

    var stringBytes = title.utf8.count
    let url: URL?
    if let rawURL = present(raw["url"]) {
      guard
        let value = rawURL as? String,
        value.utf8.count <= maxCandidateURLBytes,
        let parsed = URL(string: value),
        parsed.scheme != nil,
        let nextBytes = addingBytes(
          stringBytes,
          value.utf8.count,
          limit: maxCatalogEncodedBytes)
      else { return nil }
      url = parsed
      stringBytes = nextBytes
    } else {
      url = nil
    }

    var metadata: [String: String] = [:]
    if let rawMetadata = present(raw["metadata"]) {
      guard
        let dict = rawMetadata as? [String: Any],
        dict.count <= maxCandidateMetadataEntries
      else { return nil }
      metadata.reserveCapacity(dict.count + 2)
      for (key, rawValue) in dict {
        guard
          key.utf8.count <= maxCandidateMetadataKeyBytes,
          let value = rawValue as? String,
          value.utf8.count <= maxCandidateMetadataValueBytes,
          let withKey = addingBytes(
            stringBytes,
            key.utf8.count,
            limit: maxCatalogEncodedBytes),
          let withValue = addingBytes(
            withKey,
            value.utf8.count,
            limit: maxCatalogEncodedBytes)
        else { return nil }
        stringBytes = withValue
        metadata[key] = value
      }
    }

    let effect: CandidateEffect?
    if let rawEffect = present(raw["effect"]) {
      guard
        let decoded = candidateEffect(
          from: rawEffect,
          maxTextBytes: maxCandidateEffectBytes,
          allowOpen: true),
        let nextBytes = addingBytes(
          stringBytes,
          decoded.textBytes,
          limit: maxCatalogEncodedBytes)
      else { return nil }
      effect = decoded.effect
      stringBytes = nextBytes
    } else {
      effect = nil
    }

    guard let source = metadata[CandidateMetadataKey.source],
      allowedSources.contains(source)
    else { return nil }
    // Routing ownership is always host-stamped too.
    metadata[CandidateMetadataKey.sourceID] = sourceID
    if metadata[CandidateMetadataKey.kind] == nil {
      metadata[CandidateMetadataKey.kind] = "plugin"
    }
    if let rawPriority = metadata[CandidateMetadataKey.priority],
      FlashPriority(rawValue: rawPriority) == nil
    {
      return nil
    }
    return (
      Candidate(title: title, url: url, metadata: metadata, effect: effect),
      stringBytes
    )
  }

  static func queryAnswers(
    from raw: [[String: Any]],
    sourceID: String,
    source: String
  ) -> [Candidate]? {
    guard raw.count <= maxQueryAnswersPerEvaluator else { return nil }
    var aggregateBytes = 0
    var candidates: [Candidate] = []
    candidates.reserveCapacity(raw.count)
    for item in raw {
      guard
        let decoded = decodedQueryAnswer(
          from: item,
          sourceID: sourceID,
          source: source),
        let nextBytes = addingBytes(
          aggregateBytes,
          decoded.stringBytes,
          limit: maxQueryEncodedBytes)
      else { return nil }
      aggregateBytes = nextBytes
      candidates.append(decoded.candidate)
    }
    return candidates
  }

  private static func decodedQueryAnswer(
    from raw: [String: Any],
    sourceID: String,
    source: String
  ) -> (candidate: Candidate, stringBytes: Int)? {
    let allowedKeys: Set<String> = ["title", "subtitle", "effect"]
    guard Set(raw.keys).isSubset(of: allowedKeys),
      let title = raw["title"] as? String,
      !title.isEmpty,
      title.utf8.count <= maxQueryFieldBytes,
      let rawEffect = present(raw["effect"]),
      let decodedEffect = candidateEffect(
        from: rawEffect,
        maxTextBytes: maxQueryFieldBytes,
        allowOpen: false)
    else { return nil }
    var stringBytes = title.utf8.count
    guard
      let withEffect = addingBytes(
        stringBytes,
        decodedEffect.textBytes,
        limit: maxQueryEncodedBytes)
    else { return nil }
    stringBytes = withEffect
    let subtitle: String?
    if let rawSubtitle = present(raw["subtitle"]) {
      guard
        let value = rawSubtitle as? String,
        value.utf8.count <= maxQueryFieldBytes,
        let nextBytes = addingBytes(
          stringBytes,
          value.utf8.count,
          limit: maxQueryEncodedBytes)
      else { return nil }
      subtitle = value
      stringBytes = nextBytes
    } else {
      subtitle = nil
    }
    var metadata: [String: String] = [
      CandidateMetadataKey.source: source,
      CandidateMetadataKey.sourceID: sourceID,
      CandidateMetadataKey.kind: "query_answer",
      CandidateMetadataKey.priority: FlashPriority.urgent.rawValue,
      CandidateMetadataKey.finishesCommand: "1",
    ]
    if let subtitle, !subtitle.isEmpty {
      metadata[CandidateMetadataKey.subtitle] = subtitle
    }
    return (
      Candidate(title: title, metadata: metadata, effect: decodedEffect.effect),
      stringBytes
    )
  }

  /// `allowOpen` gates the `open` effect to catalog rows: query evaluators
  /// are deliberately unable to manufacture navigation (the same reason they
  /// can't return URLs), so an `open` effect in a query answer rejects it.
  private static func candidateEffect(
    from raw: Any,
    maxTextBytes: Int,
    allowOpen: Bool
  ) -> (effect: CandidateEffect, textBytes: Int)? {
    guard let effect = raw as? [String: Any],
      let type = effect["type"] as? String
    else {
      return nil
    }
    switch type {
    case "copy_text", "insert_text":
      guard
        Set(effect.keys) == Set(["type", "text"]),
        let text = effect["text"] as? String,
        !text.isEmpty,
        text.utf8.count <= maxTextBytes
      else { return nil }
      return (type == "copy_text" ? .copyText(text) : .insertText(text), text.utf8.count)
    case "open" where allowOpen:
      if Set(effect.keys) == Set(["type", "url"]) {
        guard
          let value = effect["url"] as? String,
          value.utf8.count <= maxTextBytes,
          let parsed = URL(string: value),
          parsed.scheme != nil
        else { return nil }
        return (.openURL(value), value.utf8.count)
      }
      if Set(effect.keys) == Set(["type", "bundle_id"]) {
        guard
          let value = effect["bundle_id"] as? String,
          !value.isEmpty,
          value.utf8.count <= maxTextBytes
        else { return nil }
        return (.openApplication(value), value.utf8.count)
      }
      return nil
    default:
      return nil
    }
  }

  /// JSON null decodes to NSNull, and `{"url": null}` is the natural
  /// serialization of an absent optional in most languages. Treat it exactly
  /// like a missing key — punishing it used to atomically discard whole
  /// 10,000-row snapshots.
  private static func present(_ value: Any?) -> Any? {
    value is NSNull ? nil : value
  }

  private static func addingBytes(_ lhs: Int, _ rhs: Int, limit: Int) -> Int? {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow, sum <= limit else { return nil }
    return sum
  }

  private static func number(_ value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? NSNumber { return value.doubleValue }
    return nil
  }

  static func candidateJSON(_ candidate: Candidate) -> [String: Any] {
    var dict: [String: Any] = [
      "title": candidate.title,
      "metadata": candidate.metadata,
    ]
    if let url = candidate.url {
      dict["url"] = url.absoluteString
    }
    switch candidate.effect {
    case .copyText(let text):
      dict["effect"] = ["type": "copy_text", "text": text]
    case .insertText(let text):
      dict["effect"] = ["type": "insert_text", "text": text]
    case .openURL(let url):
      dict["effect"] = ["type": "open", "url": url]
    case .openApplication(let bundleID):
      dict["effect"] = ["type": "open", "bundle_id": bundleID]
    case nil:
      break
    }
    return dict
  }

  static func contextJSON(_ context: AppContext) -> [String: Any] {
    [
      "bundle_id": context.bundleIdentifier,
      "front_window_frame": [
        "height": context.frontWindowFrame.height,
        "width": context.frontWindowFrame.width,
        "x": context.frontWindowFrame.minX,
        "y": context.frontWindowFrame.minY,
      ],
      "pid": Int(context.processID),
    ]
  }
}
