import CoreGraphics
import FlashCore
import Foundation

/// Wire-payload validation and (de)serialization for the plugin protocol:
/// the protocol version handshake checks, the strict catalog/answer/hint
/// decoders that reject a whole payload on the first malformed row, and the
/// `perform` reply trichotomy. Pure functions over `[String: Any]` frames —
/// no process state. Quotas live in `PluginProtocol` (parity-tested against
/// `Plugins/_flash_plugin_rust/protocol.json`).
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

  /// The request id a rejected frame answers, when it is recognisably a reply
  /// (a positive integer `id`, no `method`) — so the host can fail that
  /// request at once instead of letting it time out.
  static func responseID(inMalformedFrame line: Data) -> Int? {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
      object["method"] == nil, let id = PluginJSON.integer(object["id"]), id > 0
    else { return nil }
    return id
  }

  private static let envelopeKeys: Set<String> = ["id", "method", "params", "result"]
  private static let performOKKeys: Set<String> = ["ok", "target_pid", "navigation_url", "message"]
  private static let hintPayloadKeys: Set<String> = ["ok", "targets", "context_pid"]
  private static let frameKeys: Set<String> = ["x", "y", "width", "height"]
  private static let catalogRowKeys: Set<String> = ["source", "title", "url", "metadata", "effect"]

  /// `object`'s keys all lie in `allowed`, without building a set per frame.
  private static func keys(of object: [String: Any], within allowed: Set<String>) -> Bool {
    object.keys.allSatisfy(allowed.contains)
  }

  static func decodeFrame(_ line: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
      keys(of: object, within: envelopeKeys)
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
      guard keys(of: result, within: performOKKeys) else { return nil }
      let pid: pid_t?
      if let raw = PluginJSON.present(result["target_pid"]) {
        guard let decoded = PluginJSON.pid(raw) else { return nil }
        pid = decoded
      } else {
        pid = nil
      }
      let navigationURL: URL?
      if let raw = PluginJSON.present(result["navigation_url"]) {
        guard let text = raw as? String, let url = URLParsing.url(text), url.scheme != nil else {
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
    if result.count == 2, PluginJSON.boolean(result["unhandled"]) == true {
      return .unhandled
    }
    guard result.count == 2, let error = result["error"] as? String,
      !error.trimmed.isEmpty
    else { return nil }
    return .failed(error)
  }

  static func hintTargets(
    from payload: [String: Any], sourceID: String, contextPID: pid_t
  ) -> [PluginWireTarget]? {
    guard PluginJSON.boolean(payload["ok"]) == true,
      keys(of: payload, within: hintPayloadKeys),
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

  /// Every key of one hint target (`protocol.json` `hint_target`): geometry
  /// and semantics. A target carries nothing about the mode; a click keeps it.
  static let targetKeys: Set<String> = [
    "id", "frame", "role", "label", "url", "pid", "priority", "context_id",
  ]

  static func target(from raw: [String: Any], sourceID: String) -> PluginWireTarget? {
    guard
      Set(raw.keys).isSubset(of: targetKeys),
      let id = raw["id"] as? String, !id.isEmpty,
      let frameRaw = raw["frame"] as? [String: Any],
      frameRaw.count == 4, keys(of: frameRaw, within: frameKeys),
      let x = PluginJSON.number(frameRaw["x"]), let y = PluginJSON.number(frameRaw["y"]),
      let width = PluginJSON.number(frameRaw["width"]),
      let height = PluginJSON.number(frameRaw["height"]),
      width > 0, height > 0, (x + width).isFinite, (y + height).isFinite
    else { return nil }
    for key in ["role", "label", "url"] {
      if let value = PluginJSON.present(raw[key]), !(value is String) { return nil }
    }
    let role = PluginJSON.present(raw["role"]) as? String
    let contextID: String?
    if let value = PluginJSON.present(raw["context_id"]) {
      guard let text = value as? String, !text.isEmpty else { return nil }
      contextID = text
    } else {
      contextID = nil
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
      contextID: contextID,
      pid: pid, sourceID: sourceID, priority: priority)
  }

  static let textGridKeys: Set<String> = ["ok", "columns", "rows", "lines"]
  /// The two exact key sets of a `text_grid` line (`text_grid_line`).
  static let textGridTextLineKeys: Set<String> = ["row", "column", "text"]
  static let textGridFormatLineKeys: Set<String> = ["row", "column", "width", "format"]

  /// Decode a `text_grid` reply. Atomic: a missing or out-of-bound
  /// dimension, or one line off the grid or of neither exact shape, rejects
  /// the whole reply (`nil`).
  static func textGrid(from payload: [String: Any]) -> PluginTextGrid? {
    func dimension(_ value: Any?) -> Int? {
      guard let value = PluginJSON.integer(value),
        (0...PluginProtocol.maxTextGridDimension).contains(value)
      else { return nil }
      return value
    }
    guard PluginJSON.boolean(payload["ok"]) == true, Set(payload.keys) == textGridKeys,
      let columns = dimension(payload["columns"]), let rows = dimension(payload["rows"]),
      let raw = payload["lines"] as? [Any]
    else { return nil }
    var lines: [PluginTextGrid.Line] = []
    lines.reserveCapacity(raw.count)
    for item in raw {
      guard let line = item as? [String: Any],
        let row = PluginJSON.integer(line["row"]), (0..<rows).contains(row),
        let column = PluginJSON.integer(line["column"]), (0..<columns).contains(column)
      else { return nil }
      let keys = Set(line.keys)
      if keys == textGridTextLineKeys, let text = line["text"] as? String {
        lines.append(.text(row: row, column: column, text: text))
      } else if keys == textGridFormatLineKeys, let format = line["format"] as? String,
        let width = PluginJSON.integer(line["width"]), width >= 1, width <= columns - column
      {
        lines.append(.format(row: row, column: column, width: width, format: format))
      } else {
        return nil
      }
    }
    return PluginTextGrid(columns: columns, rows: rows, lines: lines)
  }

  /// One decoded `publish`: the rows of the whole catalog (`source` nil) or
  /// of the one declared source they replace, with each row's bytes as the
  /// plugin wrote them, so the store can hold the catalog's wire size per
  /// source and apply the byte quota after a merge without re-encoding.
  struct DecodedPublish {
    var source: String?
    var rows: [Candidate]
    /// Each row object's span in the frame, in row order.
    var rowBytes: [Int]

    /// The `rows` array's wire bytes (`quotas.catalog_bytes`): every row's
    /// span, one separator byte per row and the two brackets — the compact
    /// encoding exactly when the plugin writes compact JSON.
    var encodedBytes: Int { Self.catalogBytes(spanSum: rowBytes.reduce(0, +), rows: rows.count) }

    static func catalogBytes(spanSum: Int, rows: Int) -> Int {
      rows == 0 ? 2 : spanSum + rows + 1
    }
  }

  static let publishParamKeys: Set<String> = ["rows", "source"]

  /// Decode one `publish` notification from the frame the reader holds and
  /// its parsed envelope. `source` is a first-class row field and must name
  /// a manifest `sources[].name`; a `params.source` names the one source
  /// every row must carry; routing `source_id` never crosses the wire — it
  /// is always host-stamped here. The byte quota is read off the frame, not
  /// re-encoded. Atomic: one malformed or over-quota row, an unknown params
  /// key or a row outside the named source rejects the whole payload
  /// (`nil`), and the caller keeps the previous catalog.
  static func publish(
    frame line: Data, object: [String: Any], sourceID: String, allowedSources: Set<String>
  ) -> DecodedPublish? {
    guard let params = object["params"] as? [String: Any],
      keys(of: params, within: publishParamKeys),
      let raw = params["rows"] as? [[String: Any]],
      raw.count <= PluginProtocol.maxCatalogRows
    else { return nil }
    let source: String?
    if let value = PluginJSON.present(params["source"]) {
      guard let name = value as? String, allowedSources.contains(name) else { return nil }
      source = name
    } else {
      source = nil
    }
    guard let spans = rowByteSpans(inPublishFrame: line), spans.count == raw.count,
      DecodedPublish.catalogBytes(spanSum: spans.reduce(0, +), rows: raw.count)
        <= PluginProtocol.maxCatalogBytes
    else { return nil }
    var rows: [Candidate] = []
    rows.reserveCapacity(raw.count)
    for item in raw {
      if let source, item["source"] as? String != source { return nil }
      guard
        let row = decodedCatalogRow(from: item, sourceID: sourceID, allowedSources: allowedSources)
      else { return nil }
      rows.append(row)
    }
    return DecodedPublish(source: source, rows: rows, rowBytes: spans)
  }

  /// The byte span of each row object of a `publish` frame, in row order, as
  /// the plugin wrote it: whitespace and escaping inside a row count, the
  /// envelope's never do. The frame has already parsed as JSON, so this only
  /// walks it; `nil` when it is not an object whose `params.rows` is an
  /// array (envelope keys are matched as the plain ASCII every encoder
  /// writes).
  static func rowByteSpans(inPublishFrame line: Data) -> [Int]? {
    line.withUnsafeBytes { raw -> [Int]? in
      var scanner = JSONSpanScanner(bytes: raw.bindMemory(to: UInt8.self))
      return scanner.publishRowSpans()
    }
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
    guard keys(of: raw, within: catalogRowKeys),
      let source = raw["source"] as? String, allowedSources.contains(source),
      let title = raw["title"] as? String, !title.isEmpty,
      title.utf8.count <= PluginProtocol.maxTitleBytes
    else { return nil }
    let url: URL?
    if let value = PluginJSON.present(raw["url"]) {
      guard let text = value as? String, text.utf8.count <= PluginProtocol.maxURLBytes,
        let parsed = URLParsing.url(text), parsed.scheme != nil
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
        // Never a local file: a sandboxed plugin could point a row at a
        // `.command` or an app it wrote, and opening it would run outside
        // the sandbox (`host.open` refuses them too).
        guard
          let value = effect["url"] as? String,
          value.utf8.count <= maxTextBytes,
          let parsed = URLParsing.url(value),
          let scheme = parsed.scheme, scheme.lowercased() != "file"
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

  static func spatialContextJSON(_ context: AppContext) -> [String: Any] {
    var result = contextJSON(context)
    if let scale = context.displayScale { result["display_scale"] = Double(scale) }
    return result
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

/// Walks JSON that already parsed, to measure spans without building
/// anything: strings are skipped by their escapes, containers by depth,
/// scalars to the next delimiter. One pass over the bytes.
private struct JSONSpanScanner {
  let bytes: UnsafeBufferPointer<UInt8>
  var index = 0

  private static let quote = UInt8(ascii: "\"")
  private static let backslash = UInt8(ascii: "\\")
  private static let openBrace = UInt8(ascii: "{")
  private static let closeBrace = UInt8(ascii: "}")
  private static let openBracket = UInt8(ascii: "[")
  private static let closeBracket = UInt8(ascii: "]")
  private static let comma = UInt8(ascii: ",")
  private static let colon = UInt8(ascii: ":")
  private static let params = Array("params".utf8)
  private static let rows = Array("rows".utf8)

  private var atEnd: Bool { index >= bytes.count }
  private var byte: UInt8 { bytes[index] }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
  }

  private mutating func skipWhitespace() {
    while !atEnd, Self.isWhitespace(byte) { index += 1 }
  }

  private mutating func consume(_ expected: UInt8) -> Bool {
    skipWhitespace()
    guard !atEnd, byte == expected else { return false }
    index += 1
    return true
  }

  /// At an opening quote; leaves the index past the closing one. Returns the
  /// raw bytes between them.
  private mutating func skipString() -> UnsafeBufferPointer<UInt8>.SubSequence? {
    guard !atEnd, byte == Self.quote else { return nil }
    index += 1
    let start = index
    while !atEnd {
      if byte == Self.backslash {
        index += 2
      } else if byte == Self.quote {
        let content = bytes[start..<index]
        index += 1
        return content
      } else {
        index += 1
      }
    }
    return nil
  }

  private mutating func skipValue() -> Bool {
    skipWhitespace()
    guard !atEnd else { return false }
    switch byte {
    case Self.quote:
      return skipString() != nil
    case Self.openBrace, Self.openBracket:
      var depth = 0
      while !atEnd {
        switch byte {
        case Self.quote:
          guard skipString() != nil else { return false }
          continue
        case Self.openBrace, Self.openBracket:
          depth += 1
        case Self.closeBrace, Self.closeBracket:
          depth -= 1
          if depth == 0 {
            index += 1
            return true
          }
        default:
          break
        }
        index += 1
      }
      return false
    default:
      while !atEnd, !Self.isWhitespace(byte), byte != Self.comma, byte != Self.closeBrace,
        byte != Self.closeBracket
      {
        index += 1
      }
      return true
    }
  }

  /// Walk the members of the object at the index, handing each key's bytes
  /// to `member`, which consumes the value and reports whether to go on.
  private mutating func forEachMember(
    _ member: (inout JSONSpanScanner, UnsafeBufferPointer<UInt8>.SubSequence) -> Bool?
  ) -> Bool {
    guard consume(Self.openBrace) else { return false }
    skipWhitespace()
    if !atEnd, byte == Self.closeBrace {
      index += 1
      return true
    }
    while true {
      skipWhitespace()
      guard let key = skipString(), consume(Self.colon) else { return false }
      guard let goOn = member(&self, key) else { return false }
      if !goOn { return true }
      skipWhitespace()
      guard !atEnd else { return false }
      if byte == Self.comma {
        index += 1
        continue
      }
      if byte == Self.closeBrace {
        index += 1
        return true
      }
      return false
    }
  }

  mutating func publishRowSpans() -> [Int]? {
    var spans: [Int]?
    let walked = forEachMember { scanner, key in
      guard key.elementsEqual(Self.params) else { return scanner.skipValue() ? true : nil }
      let inner = scanner.forEachMember { scanner, key in
        guard key.elementsEqual(Self.rows) else { return scanner.skipValue() ? true : nil }
        spans = scanner.arrayElementSpans()
        return spans == nil ? nil : false
      }
      return inner ? false : nil
    }
    return walked ? spans : nil
  }

  /// At an array: each element's span, from its first byte to its last.
  private mutating func arrayElementSpans() -> [Int]? {
    guard consume(Self.openBracket) else { return nil }
    var spans: [Int] = []
    skipWhitespace()
    if !atEnd, byte == Self.closeBracket {
      index += 1
      return spans
    }
    while true {
      skipWhitespace()
      let start = index
      guard skipValue() else { return nil }
      spans.append(index - start)
      skipWhitespace()
      guard !atEnd else { return nil }
      if byte == Self.comma {
        index += 1
        continue
      }
      if byte == Self.closeBracket {
        index += 1
        return spans
      }
      return nil
    }
  }
}
