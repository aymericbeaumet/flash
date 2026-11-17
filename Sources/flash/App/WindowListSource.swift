import AppKit
import FlashCore
import Foundation

/// `@windows`: every window the window switcher knows, as a live flashlight
/// source searched by title and app name. Rows come from the switcher's
/// in-memory catalog on main, most recently focused first with the window
/// you are in last, so a query never asks an app or WindowServer anything;
/// selecting one focuses it the way `window switch` does.
final class WindowListSource: FlashSource {
  static let label = "windows.windows"
  static let sourceID = "core.windows"
  let identifier = WindowListSource.sourceID
  let displayName = WindowListSource.sourceID
  let priority = 40
  var capabilities: FlashSourceCapabilities { [.candidates] }
  var servesLiveCandidates: Bool { true }
  /// The rows are the catalog's, whatever is typed: pulled once per scope.
  var liveCandidatesDependOnText: Bool { false }
  var candidateSourceDescriptors: [CandidateSourceDescriptor] {
    [CandidateSourceDescriptor(name: Self.label, type: "windows")]
  }

  /// One cataloged window as a row shows it.
  struct Row: Equatable {
    let key: WindowSwitcherKey
    let title: String
    let app: String
    let badge: String?
  }

  typealias Rows = () -> (rows: [Row], current: WindowSwitcherKey?)

  private let rows: Rows
  private let focus: (WindowSwitcherKey) -> Void
  /// The windows the last pull listed, by row payload. Main-confined.
  private var listed: [String: WindowSwitcherKey] = [:]

  /// `rows` and `focus` run on main.
  init(rows: @escaping Rows, focus: @escaping (WindowSwitcherKey) -> Void) {
    self.rows = rows
    self.focus = focus
  }

  func supports(_ context: AppContext) -> Bool { false }
  func discover(in context: AppContext) throws -> [JumpTarget] { [] }

  func liveCandidates(
    matching text: String,
    in environment: FlashSourceEnvironment,
    scope: CandidateScope,
    completion: @escaping ([Candidate]) -> Void
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return completion([]) }
      let read = self.rows()
      let built = Self.candidates(read.rows, current: read.current)
      self.listed = built.keys
      completion(built.candidates)
    }
  }

  func resolveCandidate(
    _ candidate: Candidate,
    in environment: FlashSourceEnvironment,
    completion: @escaping (CandidateResolution) -> Void
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self, let payload = candidate.sourcePayload, let key = self.listed[payload]
      else { return completion(.unresolved) }
      // The flashlight settles first; the window then comes forward, which
      // activates its app.
      completion(.resolved(pid: nil))
      self.focus(key)
    }
  }

  /// The rows in the order the flashlight shows them for an empty query, and
  /// the window each row's payload names. A window without a title shows its
  /// app's name; the app's name is always a search alias.
  static func candidates(_ rows: [Row], current: WindowSwitcherKey?)
    -> (candidates: [Candidate], keys: [String: WindowSwitcherKey])
  {
    var candidates: [Candidate] = []
    var keys: [String: WindowSwitcherKey] = [:]
    candidates.reserveCapacity(rows.count)
    for (index, row) in rows.enumerated() {
      let payload = "\(row.key.pid):\(index)"
      keys[payload] = row.key
      let subtitle = [row.app, row.badge].compactMap { $0 }.joined(separator: " · ")
      var candidate = Candidate(
        kind: .plugin("window"), sourceID: sourceID, source: label, pid: row.key.pid,
        title: row.title.isEmpty ? row.app : row.title, subtitle: subtitle,
        sourcePayload: payload, searchAliases: row.app)
      // The window you are in is the one you least want: last.
      candidate.sourceOrder = row.key == current ? rows.count : index
      candidates.append(candidate)
    }
    return (candidates, keys)
  }
}
