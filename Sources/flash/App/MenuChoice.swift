import FlashCore
import Foundation

/// `menu choose`: a dmenu/rofi-style picker for scripts and mappings. The
/// flashlight lists the lines of `--file` as they come, filters them as you
/// type with the flashlight's scorer, and the command answers with the line
/// picked: `flash menu choose` prints it and exits 0, and a cancelled pick
/// fails, so a shell script reads `choice=$(… | flash menu choose) || exit`.
/// Return with no matching line picks the typed text, as dmenu does.
enum MenuChoice {
  static let name = CommandName("menu", "choose")
  static let sourceID = "core.menu"
  static let source = "menu"
  static let kind = CandidateKind.plugin("menu_item")
  /// Bounds what one pick reads and lists.
  static let itemLimit = 10_000
  static let fileByteLimit = 4 * 1024 * 1024

  static func validPrompt(_ prompt: String) -> Bool {
    !prompt.trimmingCharacters(in: .whitespaces).isEmpty && prompt.count <= 120
      && prompt.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
  }

  static func explanation(file: String) -> String {
    "Lists the lines of \(file) in the flashlight and answers with the one picked."
  }

  /// One item per line; blank lines and a Windows line ending are dropped,
  /// everything else is kept as written.
  static func items(from contents: String) -> [String] {
    contents.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
      .map { String($0.hasSuffix("\r") ? $0.dropLast() : $0) }
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
  }

  /// The items of the file at `path` (`~/` expanded), or why there are none.
  static func load(path: String) -> Result<[String], MenuChoiceError> {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes?[.size] as? Int else { return .failure(.unreadable(path)) }
    guard size <= fileByteLimit else { return .failure(.tooLarge(path)) }
    guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable(path)) }
    let items = Self.items(from: String(decoding: data, as: UTF8.self))
    guard !items.isEmpty else { return .failure(.empty(path)) }
    guard items.count <= itemLimit else { return .failure(.tooMany(path, items.count)) }
    return .success(items)
  }

  /// The items as flashlight rows, in their order.
  static func candidates(_ items: [String]) -> [Candidate] {
    CandidateFinder.prepare(
      items.enumerated().map { index, item in
        var candidate = Candidate(
          kind: kind, sourceID: sourceID, source: source, title: item,
          sourcePayload: String(index))
        candidate.sourceOrder = index
        return candidate
      })
  }

  /// What the list shows for `query`: every item in its order for an empty
  /// query, else the flashlight scorer's matches, best first and file order
  /// among equals.
  static func matches(_ pool: [Candidate], query: String) -> [CandidateMatch] {
    let text = query.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return pool.map { CandidateMatch(candidate: $0, score: 0) } }
    let normalized = NormalModeDispatcher.normalizedSearchText(text)
    let scored = CandidateFinder.scoreMatches(
      pool: pool, normalizedQuery: normalized,
      fuzzyScore: NormalModeDispatcher.fuzzyScorer(normalizedQuery: normalized),
      allowParallel: false)
    return CandidateFinder.sortedMatches(scored, precedence: .default)
  }

  /// Return's answer: the selected row, else what was typed; nil when
  /// nothing was typed and nothing matches.
  static func pick(matches: [CandidateMatch], selectedIndex: Int, query: String) -> String? {
    if !matches.isEmpty {
      return matches[min(max(0, selectedIndex), matches.count - 1)].candidate.title
    }
    let typed = query.trimmingCharacters(in: .whitespaces)
    return typed.isEmpty ? nil : typed
  }
}

enum MenuChoiceError: Error, Equatable, CustomStringConvertible {
  case unreadable(String)
  case tooLarge(String)
  case empty(String)
  case tooMany(String, Int)
  case cancelled

  var description: String {
    switch self {
    case .unreadable(let path): return "cannot read \(path)"
    case .tooLarge(let path):
      return "\(path) is larger than \(MenuChoice.fileByteLimit / 1024 / 1024) MB"
    case .empty(let path): return "\(path) lists nothing to choose"
    case .tooMany(let path, let count):
      return "\(path) lists \(count) items; menu choose takes up to \(MenuChoice.itemLimit)"
    case .cancelled: return "cancelled"
    }
  }
}

/// A pick in progress: its rows and who waits for the answer. Main-confined,
/// owned by the candidate finder while the command line shows it.
struct MenuSession {
  let candidates: [Candidate]
  var prompt: String? = nil
  let complete: (Result<String, MenuChoiceError>) -> Void
}
