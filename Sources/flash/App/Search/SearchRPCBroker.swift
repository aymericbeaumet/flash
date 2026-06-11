import FlashCore
import FlashSearch
import Foundation

/// Routes `search.*` plugin→host RPCs into the running `SearchService`.
/// The broker owns a dedicated serial queue so SQLite work never runs on
/// the plugin's IPC queue (`PluginProcess` holds that lock and would
/// stall the entire plugin's protocol if a write transaction blocked
/// there). All replies route back through `reply` regardless of which
/// queue the work landed on.
final class SearchRPCBroker {
  private let service: SearchService
  private let queue: DispatchQueue

  init(service: SearchService) {
    self.service = service
    self.queue = DispatchQueue(label: "flash.search.rpc", qos: .userInitiated)
  }

  func handle(
    method: String,
    params: [String: Any],
    pluginID: String,
    reply: @escaping ([String: Any]) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else {
        reply(["ok": false, "error": "search broker gone"])
        return
      }
      self.handleOnQueue(method: method, params: params, pluginID: pluginID, reply: reply)
    }
  }

  private func handleOnQueue(
    method: String,
    params: [String: Any],
    pluginID: String,
    reply: @escaping ([String: Any]) -> Void
  ) {
    switch method {
    case "search.query":
      handleQuery(params: params, pluginID: pluginID, reply: reply)
    case "search.upsert":
      handleWrite(
        params: params, pluginID: pluginID, reply: reply,
        kind: .upsert)
    case "search.replace":
      handleWrite(
        params: params, pluginID: pluginID, reply: reply,
        kind: .replace)
    case "search.delete":
      handleDelete(params: params, pluginID: pluginID, reply: reply)
    case "search.drop_collection":
      handleDrop(params: params, pluginID: pluginID, reply: reply)
    default:
      reply(["ok": false, "error": "unknown search method: \(method)"])
    }
  }

  // MARK: - Query

  private func handleQuery(
    params: [String: Any], pluginID: String,
    reply: @escaping ([String: Any]) -> Void
  ) {
    let text = (params["text"] as? String) ?? ""
    let limit = params["limit"] as? Int
    let collections = params["collections"] as? [String]
    let filters = decodeFilters(params["filters"])
    let includeMemory = (params["include_memory"] as? Bool) ?? false
    let q = SearchQuery(text: text, filters: filters, collections: collections, limit: limit)
    do {
      let hits = try service.queryEngine.querySync(q)
      var rows = hits.map(Self.wireHit(_:))
      if includeMemory {
        rows.append(contentsOf: matchLivePool(text: text, filters: filters))
      }
      reply(["ok": true, "hits": rows])
    } catch {
      FlashLog.warn(
        "[search] plugin query failed",
        fields: ["plugin": pluginID, "error": "\(error)"])
      reply(["ok": false, "error": "\(error)"])
    }
  }

  /// Fuzzy-match the cached live-pool snapshot for `include_memory`
  /// queries. Same matcher the keystroke path uses, returns identical
  /// `displayTitle` shape.
  private func matchLivePool(
    text: String, filters: [SearchFilter]
  ) -> [[String: Any]] {
    let pool = service.liveSnapshot()
    let normalizedQuery = NormalModeDispatcher.normalizedSearchText(text)
    let fuzzy = NormalModeDispatcher.fuzzyScore(normalizedQuery:normalizedCandidate:)
    let scored = CandidateFinder.scoreMatches(
      pool: pool, normalizedQuery: normalizedQuery, fuzzyScore: fuzzy)
    let sorted = CandidateFinder.sortedMatches(scored).prefix(64)
    return sorted.map { match in
      [
        "collection": "core:live",
        "doc_key": match.candidate.sourceID + ":" + match.candidate.name,
        "title": match.candidate.name,
        "subtitle": match.candidate.subtitle,
        "url": match.candidate.url?.absoluteString ?? "",
        "kind": CandidateFinder.candidateKindString(match.candidate.kind),
        "bundle_id": match.candidate.bundleIdentifier,
        "bm25": Double(-match.score),
      ]
    }
  }

  // MARK: - Writes (upsert / replace / delete / drop)

  private enum WriteKind { case upsert, replace }

  private func handleWrite(
    params: [String: Any], pluginID: String,
    reply: @escaping ([String: Any]) -> Void,
    kind: WriteKind
  ) {
    guard let collectionName = ownedCollection(
      params: params, pluginID: pluginID, reply: reply)
    else { return }
    let docs = decodeDocuments(params["documents"], pluginID: pluginID)
    let owner = "plugin:\(pluginID)"
    // Per-collection visibility. The flag rides on every write so a
    // plugin can register its collection with the correct hidden state
    // on the same RPC that delivers the first batch — no separate
    // "register" call to coordinate. Omitting it (or sending false)
    // leaves the collection visible to flashlight, which is the
    // existing behaviour for everything except the clipboard plugin.
    let hidden = (params["hidden"] as? Bool) ?? false
    let completion: (Result<Int, Error>) -> Void = { result in
      switch result {
      case .success(let written): reply(["ok": true, "written": written])
      case .failure(let err): reply(["ok": false, "error": "\(err)"])
      }
    }
    switch kind {
    case .upsert:
      service.indexer.upsert(
        collection: collectionName, owner: owner, documents: docs, hidden: hidden,
        completion: completion)
    case .replace:
      service.indexer.replaceCollection(
        collection: collectionName, owner: owner, documents: docs, hidden: hidden,
        completion: completion)
    }
  }

  private func handleDelete(
    params: [String: Any], pluginID: String,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let collectionName = ownedCollection(
      params: params, pluginID: pluginID, reply: reply)
    else { return }
    let docKeys = (params["doc_keys"] as? [String]) ?? []
    service.indexer.delete(
      collection: collectionName,
      owner: "plugin:\(pluginID)",
      docKeys: docKeys
    ) { result in
      switch result {
      case .success(let removed): reply(["ok": true, "removed": removed])
      case .failure(let err): reply(["ok": false, "error": "\(err)"])
      }
    }
  }

  private func handleDrop(
    params: [String: Any], pluginID: String,
    reply: @escaping ([String: Any]) -> Void
  ) {
    guard let collectionName = ownedCollection(
      params: params, pluginID: pluginID, reply: reply)
    else { return }
    service.indexer.dropCollection(
      collection: collectionName,
      owner: "plugin:\(pluginID)"
    ) { result in
      switch result {
      case .success: reply(["ok": true])
      case .failure(let err): reply(["ok": false, "error": "\(err)"])
      }
    }
  }

  /// Force every write into `plugin:<id>:<suffix>` so one plugin can't
  /// scribble on another's collection — even if it asks nicely. A
  /// plugin may pass the bare suffix (preferred) or the fully-qualified
  /// name; anything else is rejected.
  private func ownedCollection(
    params: [String: Any], pluginID: String,
    reply: @escaping ([String: Any]) -> Void
  ) -> String? {
    guard let raw = (params["collection"] as? String)?.trimmingCharacters(
      in: .whitespacesAndNewlines), !raw.isEmpty
    else {
      reply(["ok": false, "error": "missing collection"])
      return nil
    }
    let expectedPrefix = "plugin:\(pluginID):"
    if raw.hasPrefix(expectedPrefix) { return raw }
    if raw.contains(":") {
      reply([
        "ok": false,
        "error": "plugin \(pluginID) may only write collections under \(expectedPrefix)",
      ])
      return nil
    }
    return expectedPrefix + raw
  }

  // MARK: - Wire decode / encode

  private func decodeFilters(_ raw: Any?) -> [SearchFilter] {
    // Accept either a list of objects `{field, kind, pattern}` (the
    // typed shape Rust serializes) or a list of strings
    // `field:kind:pattern` (the shorthand a hand-rolled plugin can
    // build without ceremony).
    if let list = raw as? [[String: Any]] {
      return list.compactMap { decodeFilterObject($0) }
    }
    if let list = raw as? [String] {
      return list.compactMap { decodeFilterString($0) }
    }
    return []
  }

  private func decodeFilterObject(_ object: [String: Any]) -> SearchFilter? {
    guard let field = object["field"] as? String,
      let pattern = object["pattern"] as? String
    else { return nil }
    return SearchFilter.parse(field: field, pattern: pattern)
  }

  /// `field:kind:pattern` with explicit kind, or `field:pattern`.
  private func decodeFilterString(_ raw: String) -> SearchFilter? {
    let parts = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    if parts.count == 3 {
      let field = parts[0]
      let kindHint = parts[1]
      let needle = parts[2]
      switch kindHint.lowercased() {
      case "exact": return SearchFilter.parse(field: field, pattern: needle)
      case "prefix": return SearchFilter.parse(field: field, pattern: needle + "*")
      case "suffix": return SearchFilter.parse(field: field, pattern: "*" + needle)
      case "contains": return SearchFilter.parse(field: field, pattern: "*" + needle + "*")
      case "any": return SearchFilter.parse(field: field, pattern: "*")
      default: return SearchFilter.parse(field: field, pattern: needle)
      }
    }
    if parts.count == 2 {
      return SearchFilter.parse(field: parts[0], pattern: parts[1])
    }
    return nil
  }

  private func decodeDocuments(_ raw: Any?, pluginID: String) -> [SearchDocument] {
    let list = (raw as? [[String: Any]]) ?? []
    var out: [SearchDocument] = []
    out.reserveCapacity(list.count)
    for entry in list {
      guard let docKey = (entry["doc_key"] as? String) ?? (entry["id"] as? String),
        let title = entry["title"] as? String,
        !title.isEmpty
      else { continue }
      let kind = (entry["kind"] as? String) ?? "plugin"
      let sourceID = (entry["source_id"] as? String) ?? "plugin:\(pluginID)"
      var meta: [String: String] = [:]
      if let metaObject = entry["meta"] as? [String: Any] {
        for (key, value) in metaObject {
          if let stringValue = value as? String {
            meta[key] = stringValue
          } else if let n = value as? NSNumber {
            meta[key] = n.stringValue
          }
        }
      }
      out.append(SearchDocument(
        docKey: docKey,
        title: title,
        kind: kind,
        sourceID: sourceID,
        subtitle: entry["subtitle"] as? String,
        body: entry["body"] as? String,
        url: entry["url"] as? String,
        bundleID: entry["bundle_id"] as? String,
        meta: meta))
    }
    return out
  }

  private static func wireHit(_ hit: SearchHit) -> [String: Any] {
    var out: [String: Any] = [
      "collection": hit.collection,
      "doc_key": hit.document.docKey,
      "title": hit.document.title,
      "kind": hit.document.kind,
      "source_id": hit.document.sourceID,
      "bm25": hit.bm25,
    ]
    if let s = hit.document.subtitle { out["subtitle"] = s }
    if let b = hit.document.body { out["body"] = b }
    if let u = hit.document.url { out["url"] = u }
    if let b = hit.document.bundleID { out["bundle_id"] = b }
    if !hit.document.meta.isEmpty { out["meta"] = hit.document.meta }
    return out
  }
}
