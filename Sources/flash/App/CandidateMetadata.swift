import FlashCore
import Foundation

/// Host-side convention names for routing fields stashed in `Candidate.metadata`.
/// FlashCore makes no claim on these — they're just the strings the bundled
/// sources and host code agree on. Plugins are free to ignore them, share them,
/// or invent their own.
enum CandidateMetadataKey {
  static let source = "source"
  static let sourceID = "source_id"
  static let kind = "kind"
  static let pid = "pid"
  static let navigationURL = "navigation_url"
  static let bundleID = "bundle_id"
  static let subtitle = "subtitle"
  static let payload = "payload"
  static let aliases = "aliases"
  static let finishesCommand = "finishes_command"
}

extension Candidate {
  var source: String { metadata[CandidateMetadataKey.source] ?? "" }
  var sourceID: String { metadata[CandidateMetadataKey.sourceID] ?? "" }
  var kind: CandidateKind {
    let raw = metadata[CandidateMetadataKey.kind] ?? ""
    return raw == "app" ? .app : .plugin(raw)
  }
  var pid: pid_t? {
    guard let raw = metadata[CandidateMetadataKey.pid], let value = Int32(raw) else { return nil }
    return value
  }
  var navigationURL: URL? {
    guard let raw = metadata[CandidateMetadataKey.navigationURL], !raw.isEmpty else { return nil }
    return URL(string: raw)
  }
  var bundleIdentifier: String { metadata[CandidateMetadataKey.bundleID] ?? "" }
  var subtitle: String { metadata[CandidateMetadataKey.subtitle] ?? "" }
  var sourcePayload: String? { metadata[CandidateMetadataKey.payload] }
  var searchAliases: String { metadata[CandidateMetadataKey.aliases] ?? "" }
  var finishesCommand: Bool { metadata[CandidateMetadataKey.finishesCommand] == "1" }

  /// Build a candidate from the conventional host-side fields. `title` and `url`
  /// land on the typed Candidate fields; everything else goes into `metadata`
  /// under its canonical key.
  init(
    kind: CandidateKind,
    sourceID: String,
    source: String,
    pid: pid_t? = nil,
    title: String,
    subtitle: String = "",
    bundleIdentifier: String = "",
    url: URL? = nil,
    navigationURL: URL? = nil,
    sourcePayload: String? = nil,
    searchAliases: String = "",
    finishesCommand: Bool = false,
    extra: [String: String] = [:]
  ) {
    var metadata = extra
    metadata[CandidateMetadataKey.kind] = Self.kindString(kind)
    if !sourceID.isEmpty { metadata[CandidateMetadataKey.sourceID] = sourceID }
    if !source.isEmpty { metadata[CandidateMetadataKey.source] = source }
    if let pid { metadata[CandidateMetadataKey.pid] = String(pid) }
    if !subtitle.isEmpty { metadata[CandidateMetadataKey.subtitle] = subtitle }
    if !bundleIdentifier.isEmpty { metadata[CandidateMetadataKey.bundleID] = bundleIdentifier }
    if let navigationURL {
      metadata[CandidateMetadataKey.navigationURL] = navigationURL.absoluteString
    }
    if let sourcePayload { metadata[CandidateMetadataKey.payload] = sourcePayload }
    if !searchAliases.isEmpty { metadata[CandidateMetadataKey.aliases] = searchAliases }
    if finishesCommand { metadata[CandidateMetadataKey.finishesCommand] = "1" }
    self.init(title: title, url: url, metadata: metadata)
  }

  static func kindString(_ kind: CandidateKind) -> String {
    switch kind {
    case .app: return "app"
    case .plugin(let tag): return tag
    }
  }
}
