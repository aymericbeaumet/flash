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
    PluginJSON.integer(response?["protocol_version"])
  }

  /// Serialize one frame as a newline-terminated JSON line.
  /// JSONSerialization never emits raw newlines without .prettyPrinted, so
  /// the delimiter is unambiguous.
  static func encodeFrame(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(
      withJSONObject: object, options: [.withoutEscapingSlashes])
    data.append(0x0A)
    return data
  }

  static func decodeFrame(_ line: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
      Set(object.keys).isSubset(of: ["id", "method", "params", "result"])
    else { throw PluginError.failure("invalid IPC envelope") }
    if let id = object["id"] {
      guard let integer = PluginJSON.integer(id), integer > 0 else {
        throw PluginError.failure("invalid IPC id")
      }
    }
    if let method = object["method"] {
      guard let name = method as? String, !name.isEmpty, object["result"] == nil,
        object["params"] == nil || object["params"] is [String: Any]
      else { throw PluginError.failure("invalid IPC request") }
    } else {
      guard object["id"] != nil, object["params"] == nil, object["result"] is [String: Any]
      else { throw PluginError.failure("invalid IPC response") }
    }
    return object
  }

  /// The response law: every result is a JSON object carrying boolean `ok`.
  /// Returns the result payload iff `ok: true`; anything else (missing
  /// result, missing/false `ok`) is nil, and the caller settles empty.
  static func okPayload(_ result: [String: Any]?) -> [String: Any]? {
    guard let result, PluginJSON.boolean(result["ok"]) == true,
      result["error"] == nil, result["unhandled"] == nil
    else { return nil }
    return result
  }

  /// Decode one `perform` reply into the universal trichotomy. `nil`
  /// (deadline expiry, plugin crash mid-call) coerces to `.failed` — the
  /// plugin was dispatched, so the action may still land and the host must
  /// not double-fire a fallback. The never-dispatched → `.unhandled` case is
  /// the caller's, decided before any frame is written.
  static func performOutcome(from result: [String: Any]?) -> PluginPerformOutcome {
    guard let result else { return .failed("no reply within the perform deadline") }
    return validatedPerformResult(result) ?? .failed("malformed perform reply")
  }

  static func validatedPerformResult(_ result: [String: Any]) -> PluginPerformOutcome? {
    guard let ok = PluginJSON.boolean(result["ok"]) else { return nil }
    if ok {
      guard Set(result.keys).isSubset(of: ["ok", "target_pid", "navigation_url", "message"]) else {
        return nil
      }
      let pid: pid_t?
      if let raw = PluginJSON.present(result["target_pid"]) {
        guard let decoded = PluginJSON.pid(raw) else { return nil }
        pid = decoded
      } else {
        pid = nil
      }
      let navigationURL: URL?
      if let raw = PluginJSON.present(result["navigation_url"]) {
        guard let text = raw as? String, let url = URL(string: text), url.scheme != nil else {
          return nil
        }
        navigationURL = url
      } else {
        navigationURL = nil
      }
      let message: String?
      if let raw = PluginJSON.present(result["message"]) {
        guard let text = raw as? String else { return nil }
        message = text.isEmpty ? nil : text
      } else {
        message = nil
      }
      return .performed(pid: pid, navigationURL: navigationURL, message: message)
    }
    if Set(result.keys) == ["ok", "unhandled"], PluginJSON.boolean(result["unhandled"]) == true {
      return .unhandled
    }
    guard Set(result.keys) == ["ok", "error"], let error = result["error"] as? String,
      !error.trimmed.isEmpty
    else { return nil }
    return .failed(error)
  }

  static func hintTargets(
    from payload: [String: Any], sourceID: String, contextPID: pid_t
  ) -> [PluginWireTarget]? {
    guard PluginJSON.boolean(payload["ok"]) == true,
      Set(payload.keys).isSubset(of: ["ok", "targets", "context_pid"]),
      let raw = payload["targets"] as? [[String: Any]]
    else { return nil }
    if let value = PluginJSON.present(payload["context_pid"]) {
      guard PluginJSON.pid(value) == contextPID else { return nil }
    }
    var targets: [PluginWireTarget] = []
    targets.reserveCapacity(raw.count)
    for item in raw {
      guard let target = target(from: item, sourceID: sourceID) else { return nil }
      targets.append(target)
    }
    return targets
  }

  static func target(from raw: [String: Any], sourceID: String) -> PluginWireTarget? {
    guard
      Set(raw.keys).isSubset(of: [
        "id", "frame", "role", "label", "url", "pid", "enters_insert_mode", "priority",
      ]),
      let id = raw["id"] as? String, !id.isEmpty,
      let frameRaw = raw["frame"] as? [String: Any],
      Set(frameRaw.keys) == ["x", "y", "width", "height"],
      let x = PluginJSON.number(frameRaw["x"]), let y = PluginJSON.number(frameRaw["y"]),
      let width = PluginJSON.number(frameRaw["width"]),
      let height = PluginJSON.number(frameRaw["height"]),
      width > 0, height > 0, (x + width).isFinite, (y + height).isFinite
    else { return nil }
    for key in ["role", "label", "url"] {
      if let value = PluginJSON.present(raw[key]), !(value is String) { return nil }
    }
    let role = PluginJSON.present(raw["role"]) as? String
    let entersInsertMode: Bool
    if let value = PluginJSON.present(raw["enters_insert_mode"]) {
      guard let decoded = PluginJSON.boolean(value) else { return nil }
      entersInsertMode = decoded
    } else {
      entersInsertMode = JumpTarget.textInputRoles.contains(role ?? "")
    }
    let priority: FlashPriority
    if let value = PluginJSON.present(raw["priority"]) {
      guard let text = value as? String, let parsed = FlashPriority(rawValue: text) else {
        return nil
      }
      priority = parsed
    } else {
      priority = .normal
    }
    let pid: pid_t?
    if let value = PluginJSON.present(raw["pid"]) {
      guard let decoded = PluginJSON.pid(value) else { return nil }
      pid = decoded
    } else {
      pid = nil
    }
    return PluginWireTarget(
      id: id, frame: CGRect(x: x, y: y, width: width, height: height), role: role,
      label: PluginJSON.present(raw["label"]) as? String,
      url: PluginJSON.present(raw["url"]) as? String,
      pid: pid, entersInsertMode: entersInsertMode, sourceID: sourceID, priority: priority)
  }

  /// Decode a complete catalog payload (`publish` rows or a `search` reply).
  /// `source` is a first-class row field and must name a manifest
  /// `sources[].name`; routing `source_id` never crosses the wire — it is
  /// always host-stamped here. Atomic: one malformed or over-quota row
  /// rejects the whole payload (`nil`), and the caller keeps the previous
  /// catalog.
  static func catalogRows(
    from raw: [[String: Any]], sourceID: String, allowedSources: Set<String>
  ) -> (rows: [Candidate], encodedBytes: Int)? {
    decodeArray(
      raw, countLimit: PluginProtocol.maxCatalogRows, byteLimit: PluginProtocol.maxCatalogBytes
    ) {
      decodedCatalogRow(from: $0, sourceID: sourceID, allowedSources: allowedSources)
    }.map { ($0.values, $0.encodedBytes) }
  }

  private static func decodeArray<T>(
    _ raw: [[String: Any]], countLimit: Int, byteLimit: Int, decode: ([String: Any]) -> T?
  ) -> (values: [T], encodedBytes: Int)? {
    guard raw.count <= countLimit, let encodedBytes = PluginJSON.encodedBytes(raw),
      encodedBytes <= byteLimit
    else { return nil }
    var values: [T] = []
    values.reserveCapacity(raw.count)
    for item in raw {
      guard let value = decode(item) else { return nil }
      values.append(value)
    }
    return (values, encodedBytes)
  }

  private static func decodedCatalogRow(
    from raw: [String: Any], sourceID: String, allowedSources: Set<String>
  ) -> Candidate? {
    guard Set(raw.keys).isSubset(of: ["source", "title", "url", "metadata", "effect"]),
      let source = raw["source"] as? String, allowedSources.contains(source),
      let title = raw["title"] as? String, !title.isEmpty,
      title.utf8.count <= PluginProtocol.maxTitleBytes
    else { return nil }
    let url: URL?
    if let value = PluginJSON.present(raw["url"]) {
      guard let text = value as? String, text.utf8.count <= PluginProtocol.maxURLBytes,
        let parsed = URL(string: text), parsed.scheme != nil
      else { return nil }
      url = parsed
    } else {
      url = nil
    }
    var metadata: [String: String] = [:]
    if let value = PluginJSON.present(raw["metadata"]) {
      guard let entries = value as? [String: Any],
        entries.count <= PluginProtocol.maxMetadataEntries
      else { return nil }
      for (key, value) in entries {
        guard key.utf8.count <= PluginProtocol.maxMetadataKeyBytes,
          let text = value as? String, text.utf8.count <= PluginProtocol.maxMetadataValueBytes
        else { return nil }
        metadata[key] = text
      }
    }
    let effect: CandidateEffect?
    if let value = PluginJSON.present(raw["effect"]) {
      guard
        let decoded = candidateEffect(
          from: value, maxTextBytes: PluginProtocol.maxEffectTextBytes, allowOpen: true)
      else { return nil }
      effect = decoded
    } else {
      effect = nil
    }
    // Routing and provenance are always owned by the receiving host.
    metadata[CandidateMetadataKey.source] = source
    metadata[CandidateMetadataKey.sourceID] = sourceID
    if metadata[CandidateMetadataKey.kind] == nil { metadata[CandidateMetadataKey.kind] = "plugin" }
    if let priority = metadata[CandidateMetadataKey.priority],
      FlashPriority(rawValue: priority) == nil
    {
      return nil
    }
    return Candidate(title: title, url: url, metadata: metadata, effect: effect)
  }

  static func queryAnswers(
    from raw: [[String: Any]], sourceID: String, source: String
  ) -> [Candidate]? {
    decodeArray(
      raw, countLimit: PluginProtocol.maxAnswers, byteLimit: PluginProtocol.maxAnswersBytes
    ) {
      decodedQueryAnswer(from: $0, sourceID: sourceID, source: source)
    }?.values
  }

  private static func decodedQueryAnswer(
    from raw: [String: Any], sourceID: String, source: String
  ) -> Candidate? {
    guard Set(raw.keys).isSubset(of: ["title", "subtitle", "effect"]),
      let title = raw["title"] as? String, !title.isEmpty,
      title.utf8.count <= PluginProtocol.maxAnswerFieldBytes,
      let value = PluginJSON.present(raw["effect"]),
      let effect = candidateEffect(
        from: value, maxTextBytes: PluginProtocol.maxAnswerFieldBytes, allowOpen: false)
    else { return nil }
    var metadata: [String: String] = [
      CandidateMetadataKey.source: source, CandidateMetadataKey.sourceID: sourceID,
      CandidateMetadataKey.kind: "query_answer",
      CandidateMetadataKey.priority: FlashPriority.urgent.rawValue,
      CandidateMetadataKey.finishesCommand: "1",
    ]
    if let value = PluginJSON.present(raw["subtitle"]) {
      guard let text = value as? String, text.utf8.count <= PluginProtocol.maxAnswerFieldBytes
      else { return nil }
      if !text.isEmpty { metadata[CandidateMetadataKey.subtitle] = text }
    }
    return Candidate(title: title, metadata: metadata, effect: effect)
  }

  /// `allowOpen` gates the `open` effect to catalog rows: query evaluators
  /// are deliberately unable to manufacture navigation (the same reason they
  /// can't return URLs), so an `open` effect in a query answer rejects it.
  private static func candidateEffect(
    from raw: Any,
    maxTextBytes: Int,
    allowOpen: Bool
  ) -> CandidateEffect? {
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
      return type == "copy_text" ? .copyText(text) : .insertText(text)
    case "open" where allowOpen:
      if Set(effect.keys) == Set(["type", "url"]) {
        guard
          let value = effect["url"] as? String,
          value.utf8.count <= maxTextBytes,
          let parsed = URL(string: value),
          parsed.scheme != nil
        else { return nil }
        return .openURL(value)
      }
      if Set(effect.keys) == Set(["type", "bundle_id"]) {
        guard
          let value = effect["bundle_id"] as? String,
          !value.isEmpty,
          value.utf8.count <= maxTextBytes
        else { return nil }
        return .openApplication(value)
      }
      return nil
    default:
      return nil
    }
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
