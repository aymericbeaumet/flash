import AppKit
import FlashCore
import Foundation

/// `@files` and `!f`: files whose names match the query, from an
/// in-process Spotlight query (`mdfind -name` semantics). Live because no
/// catalog of every file name can be kept warm; the query runs only when the
/// user scopes the flashlight to this source. Rows carry canonical `file://`
/// URLs and selection opens the file through LaunchServices.
final class FileSearchSource: FlashSource {
  static let sourceID = "core.files"
  static let sourceLabel = "files.results"
  static let bang = CoreBang(
    token: "f", description: "Find files by name: !f <name>", scope: .type("files"))
  /// Rows per query: far more than the flashlight shows.
  static let maxResults = 200
  /// Longer paths are dropped: percent encoding can triple a path's bytes,
  /// and the URL must stay openable.
  static let maxPathBytes = 4_096
  static let kind = CandidateKind.plugin("file")

  let identifier = FileSearchSource.sourceID
  let displayName = FileSearchSource.sourceID
  let priority = 40
  var capabilities: FlashSourceCapabilities { [.candidates] }
  var servesLiveCandidates: Bool { true }
  var candidateSourceDescriptors: [CandidateSourceDescriptor] {
    [CandidateSourceDescriptor(name: Self.sourceLabel, type: "files")]
  }

  private let spotlight = SpotlightNameSearch()

  func supports(_ context: AppContext) -> Bool { false }
  func discover(in context: AppContext) throws -> [JumpTarget] { [] }

  /// One Spotlight query per explicitly scoped keystroke. A newer query
  /// supersedes this one inside `SpotlightNameSearch`; the flashlight drops
  /// replies for any query that is no longer current.
  func liveCandidates(
    matching text: String,
    in environment: FlashSourceEnvironment,
    scope: CandidateScope,
    completion: @escaping ([Candidate]) -> Void
  ) {
    _ = (environment, scope)
    guard let query = SpotlightNameSearch.query(forName: text) else {
      DispatchQueue.main.async { completion([]) }
      return
    }
    let startedNs = DispatchTime.now().uptimeNanoseconds
    spotlight.search(
      query: query,
      limit: Self.maxResults,
      deadline: .milliseconds(FlashTunables.flashlightLiveQueryTimeoutMs)
    ) { result in
      let candidates = result.paths.compactMap(Self.candidate(forPath:))
      let elapsedMs = (DispatchTime.now().uptimeNanoseconds &- startedNs) / 1_000_000
      FlashLog.trace(
        "[files] spotlight outcome=\(result.outcome.rawValue) "
          + "candidates=\(candidates.count) ms=\(elapsedMs)")
      DispatchQueue.main.async { completion(candidates) }
    }
  }

  func resolveCandidate(
    _ candidate: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    _ = environment
    guard let url = candidate.url, url.isFileURL else {
      DispatchQueue.main.async { completion(.unresolved) }
      return
    }
    // Async: the synchronous variant is a LaunchServices round trip on main.
    NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) {
      app, error in
      DispatchQueue.main.async {
        completion(error == nil ? .resolved(pid: app?.processIdentifier) : .unresolved)
      }
    }
  }

  func candidate(
    matching target: String, in environment: FlashSourceEnvironment
  ) -> Candidate? { nil }
  func documentURL(in context: AppContext) -> String? { nil }

  /// One result row: the file name as title, the path as subtitle, and its
  /// `file://` URL. Paths Spotlight should never return (relative, nameless,
  /// oversized) are dropped.
  static func candidate(forPath path: String) -> Candidate? {
    guard path.hasPrefix("/"), path.utf8.count <= maxPathBytes,
      let name = path.split(separator: "/").last.map(String.init),
      name != ".", name != "..",
      let url = URLParsing.url(fileURLString(forPath: path))
    else { return nil }
    return Candidate(
      kind: kind, sourceID: sourceID, source: sourceLabel, title: name, subtitle: path,
      url: url)
  }

  /// `file://` URL for an absolute path, percent-encoding every byte outside
  /// RFC 3986 unreserved characters and `/`.
  static func fileURLString(forPath path: String) -> String {
    let hex = Array("0123456789ABCDEF".utf8)
    var bytes = Array("file://".utf8)
    bytes.reserveCapacity(bytes.count + path.utf8.count)
    for byte in path.utf8 {
      switch byte {
      case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
        UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
        UInt8(ascii: "_"), UInt8(ascii: "~"), UInt8(ascii: "/"):
        bytes.append(byte)
      default:
        bytes.append(contentsOf: [UInt8(ascii: "%"), hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]])
      }
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}
