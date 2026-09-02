import CoreGraphics
import FlashCore
import Foundation

/// Wire-payload validation and (de)serialization for the plugin protocol:
/// the protocol version handshake checks, the strict catalog/answer/hint
/// decoders that reject a whole payload on the first malformed row, and the
/// `perform` reply trichotomy. Pure functions over `[String: Any]` frames —
/// no process state. Quotas live in `PluginProtocol` (parity-tested against
/// `Plugins/_flash_plugin_specs/protocol.json`).
enum PluginWireCodec {

  static func acceptsProtocolVersion(_ response: [String: Any]?) -> Bool {
    protocolVersionValue(response) == PluginProtocol.version
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
      throw PluginError.failure("non-object IPC frame")
    }
    return object
  }

  /// The response law: every result is a JSON object carrying boolean `ok`.
  /// Returns the result payload iff `ok: true`; anything else (missing
  /// result, missing/false `ok`) is nil, and the caller settles empty.
  static func okPayload(_ result: [String: Any]?) -> [String: Any]? {
    guard let result, result["ok"] as? Bool == true else { return nil }
    return result
  }

  /// Decode one `perform` reply into the universal trichotomy. `nil`
  /// (deadline expiry, plugin crash mid-call) coerces to `.failed` — the
  /// plugin was dispatched, so the action may still land and the host must
  /// not double-fire a fallback. The never-dispatched → `.unhandled` case is
  /// the caller's, decided before any frame is written.
  static func performOutcome(from result: [String: Any]?) -> PluginPerformOutcome {
    guard let result else { return .failed("no reply within the perform deadline") }
    guard let ok = result["ok"] as? Bool else { return .failed("reply missing ok") }
    if ok {
      let pid = (result["target_pid"] as? Int).map(pid_t.init)
      let navigationURL = (result["navigation_url"] as? String).flatMap(URL.init(string:))
      let message = (result["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      return .performed(pid: pid, navigationURL: navigationURL, message: message)
    }
    if result["unhandled"] as? Bool == true { return .unhandled }
    let error =
      (result["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? "unspecified error"
    return .failed(error)
  }

  /// Per-method ceiling on a reply frame, above the SDK-owned encoded value
  /// boundary. The frame also carries id/result envelope keys outside those
  /// SDK-owned values, hence the small fixed allowance.
  static func responsePayloadLimit(for method: String) -> Int? {
    switch method {
    case "search":
      return PluginProtocol.maxCatalogBytes + 1_024
    case "evaluate":
      return PluginProtocol.maxAnswersBytes + 1_024
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

  /// Decode a complete catalog payload (`publish` rows or a `search` reply).
  /// `source` is a first-class row field and must name a manifest
  /// `sources[].name`; routing `source_id` never crosses the wire — it is
  /// always host-stamped here. Atomic: one malformed or over-quota row
  /// rejects the whole payload (`nil`), and the caller keeps the previous
  /// catalog.
  static func catalogRows(
    from raw: [[String: Any]],
    sourceID: String,
    allowedSources: Set<String>
  ) -> (rows: [Candidate], encodedBytes: Int)? {
    guard raw.count <= PluginProtocol.maxCatalogRows else { return nil }
    var aggregateBytes = 0
    var rows: [Candidate] = []
    rows.reserveCapacity(raw.count)
    for item in raw {
      guard
        let decoded = decodedCatalogRow(
          from: item,
          sourceID: sourceID,
          allowedSources: allowedSources),
        let nextBytes = addingBytes(
          aggregateBytes,
          decoded.stringBytes,
          limit: PluginProtocol.maxCatalogBytes)
      else {
        // A catalog is atomic. Keeping the valid prefix would expose a
        // deterministic but incomplete catalog and hide the plugin defect.
        return nil
      }
      aggregateBytes = nextBytes
      rows.append(decoded.candidate)
    }
    return (rows, aggregateBytes)
  }

  private static func decodedCatalogRow(
    from raw: [String: Any],
    sourceID: String,
    allowedSources: Set<String>
  ) -> (candidate: Candidate, stringBytes: Int)? {
    let allowedKeys: Set<String> = ["source", "title", "url", "metadata", "effect"]
    guard Set(raw.keys).isSubset(of: allowedKeys),
      let source = raw["source"] as? String,
      allowedSources.contains(source),
      let title = raw["title"] as? String,
      !title.isEmpty,
      title.utf8.count <= PluginProtocol.maxTitleBytes
    else { return nil }

    var stringBytes = source.utf8.count + title.utf8.count
    let url: URL?
    if let rawURL = present(raw["url"]) {
      guard
        let value = rawURL as? String,
        value.utf8.count <= PluginProtocol.maxURLBytes,
        let parsed = URL(string: value),
        parsed.scheme != nil,
        let nextBytes = addingBytes(
          stringBytes,
          value.utf8.count,
          limit: PluginProtocol.maxCatalogBytes)
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
        dict.count <= PluginProtocol.maxMetadataEntries
      else { return nil }
      metadata.reserveCapacity(dict.count + 3)
      for (key, rawValue) in dict {
        guard
          key.utf8.count <= PluginProtocol.maxMetadataKeyBytes,
          let value = rawValue as? String,
          value.utf8.count <= PluginProtocol.maxMetadataValueBytes,
          let withKey = addingBytes(
            stringBytes,
            key.utf8.count,
            limit: PluginProtocol.maxCatalogBytes),
          let withValue = addingBytes(
            withKey,
            value.utf8.count,
            limit: PluginProtocol.maxCatalogBytes)
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
          maxTextBytes: PluginProtocol.maxEffectTextBytes,
          allowOpen: true),
        let nextBytes = addingBytes(
          stringBytes,
          decoded.textBytes,
          limit: PluginProtocol.maxCatalogBytes)
      else { return nil }
      effect = decoded.effect
      stringBytes = nextBytes
    } else {
      effect = nil
    }

    // Provenance and routing ownership are host-stamped, never trusted from
    // metadata: the first-class `source` overwrites any metadata echo.
    metadata[CandidateMetadataKey.source] = source
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
    guard raw.count <= PluginProtocol.maxAnswers else { return nil }
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
          limit: PluginProtocol.maxAnswersBytes)
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
      title.utf8.count <= PluginProtocol.maxAnswerFieldBytes,
      let rawEffect = present(raw["effect"]),
      let decodedEffect = candidateEffect(
        from: rawEffect,
        maxTextBytes: PluginProtocol.maxAnswerFieldBytes,
        allowOpen: false)
    else { return nil }
    var stringBytes = title.utf8.count
    guard
      let withEffect = addingBytes(
        stringBytes,
        decodedEffect.textBytes,
        limit: PluginProtocol.maxAnswersBytes)
    else { return nil }
    stringBytes = withEffect
    let subtitle: String?
    if let rawSubtitle = present(raw["subtitle"]) {
      guard
        let value = rawSubtitle as? String,
        value.utf8.count <= PluginProtocol.maxAnswerFieldBytes,
        let nextBytes = addingBytes(
          stringBytes,
          value.utf8.count,
          limit: PluginProtocol.maxAnswersBytes)
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
  /// 10,000-row catalogs.
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

  /// Serialize a candidate back to the wire row shape for `perform
  /// {kind: "resolve"}`. Rows must be resolvable from their own content — a
  /// restarted plugin sees exactly this.
  static func candidateJSON(_ candidate: Candidate) -> [String: Any] {
    var metadata = candidate.metadata
    let source = metadata.removeValue(forKey: CandidateMetadataKey.source) ?? ""
    metadata.removeValue(forKey: CandidateMetadataKey.sourceID)
    var dict: [String: Any] = [
      "source": source,
      "title": candidate.title,
      "metadata": metadata,
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
