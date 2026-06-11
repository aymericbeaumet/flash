import FlashCore
import FlashSearch
import Foundation

/// Translate a `SearchHit` from the persistent index into an in-memory
/// `Candidate` so the existing CandidateFinder ranking + the overlay
/// rendering path treat DB rows and live-pool rows identically. The
/// reverse mapping (Candidate → frecency item_key) lives here too.
enum SearchCandidateMapper {
  static func candidate(from hit: SearchHit) -> Candidate {
    let url = hit.document.url.flatMap(URL.init(string:))
    let kind: CandidateKind = .plugin(hit.document.kind)
    return Candidate(
      kind: kind,
      sourceID: hit.document.sourceID,
      source: deriveSource(hit: hit),
      pid: nil,
      name: hit.document.title,
      subtitle: hit.document.subtitle ?? "",
      bundleIdentifier: hit.document.bundleID ?? "",
      url: url,
      sourcePayload: payload(for: hit))
  }

  /// User-visible source label. The DB carries the full `sourceID` (e.g.
  /// `core:browser-history`); the in-memory flashlight conventionally
  /// shows a short tag (`history`, `file`, `clipboard`). Strip the
  /// canonical prefix when present.
  private static func deriveSource(hit: SearchHit) -> String {
    let sid = hit.document.sourceID
    if sid.hasPrefix("core:") {
      let tag = String(sid.dropFirst("core:".count))
      return tag.isEmpty ? sid : tag
    }
    if sid.hasPrefix("plugin:") {
      let tag = String(sid.dropFirst("plugin:".count))
      return tag.isEmpty ? sid : tag
    }
    return sid
  }

  /// Round-trip the doc_key so the resolver can find the original row
  /// without re-querying. Encoded as `<collection>\u{1f}<doc_key>` —
  /// the unit separator is illegal in flashlight names and won't
  /// collide with user content.
  private static func payload(for hit: SearchHit) -> String {
    return "\(hit.collection)\u{1f}\(hit.document.docKey)"
  }

  /// Decode a payload back into `(collection, docKey)`. Returns `nil`
  /// when the payload didn't originate from `payload(for:)`.
  static func decodePayload(_ payload: String?) -> (collection: String, docKey: String)? {
    guard let payload, let separator = payload.firstIndex(of: "\u{1f}") else { return nil }
    let collection = String(payload[..<separator])
    let docKey = String(payload[payload.index(after: separator)...])
    return (collection, docKey)
  }

  /// Stable item_key for frecency lookups. Mirrors the host's
  /// `appMovementIdentity` so a candidate that's both indexed and
  /// resolvable through the live pool gets one frecency row, not two.
  static func itemKey(for candidate: Candidate) -> String? {
    if candidate.kind == .app {
      if !candidate.bundleIdentifier.isEmpty {
        return FrecencyKey.app(bundleID: candidate.bundleIdentifier)
      }
      if let path = candidate.url?.standardizedFileURL.path, !path.isEmpty {
        return FrecencyKey.appPath(path)
      }
    }
    if let url = candidate.url?.absoluteString, !url.isEmpty {
      return FrecencyKey.url(canonicalizeURL(url))
    }
    if let decoded = decodePayload(candidate.sourcePayload) {
      return FrecencyKey.document(collection: decoded.collection, docKey: decoded.docKey)
    }
    return nil
  }

  /// Lower-case host + strip a trailing slash so `https://X.example/`
  /// and `https://x.example` map to the same frecency row.
  static func canonicalizeURL(_ raw: String) -> String {
    guard let url = URL(string: raw) else { return raw }
    var host = url.host?.lowercased() ?? ""
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    let scheme = url.scheme?.lowercased() ?? ""
    var path = url.path
    if path.hasSuffix("/") { path = String(path.dropLast()) }
    let suffix: String
    if let q = url.query, !q.isEmpty { suffix = "?\(q)" } else { suffix = "" }
    if scheme.isEmpty { return "\(host)\(path)\(suffix)" }
    return "\(scheme)://\(host)\(path)\(suffix)"
  }
}
