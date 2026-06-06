import FlashCore
import Foundation

struct CandidateMatch {
  var candidate: Candidate
  var score: Int
}

enum CandidateFinder {
  static func displayTitle(source: String, name: String) -> String {
    "[\(source)] \(name)"
  }

  static func displayTitle(_ candidate: Candidate) -> String {
    guard candidate.kind == .browserTab else {
      return displayTitle(source: candidate.source, name: candidate.name)
    }
    return browserTabDisplayTitle(candidate)
  }

  static func prepare(
    _ candidates: [Candidate],
    normalize: (String) -> String = NormalModeDispatcher.normalizedSearchText
  ) -> [Candidate] {
    candidates.map { prepare($0, normalize: normalize) }
  }

  static func prepare(
    _ candidate: Candidate,
    normalize: (String) -> String = NormalModeDispatcher.normalizedSearchText
  ) -> Candidate {
    var prepared = candidate
    prepared.displayTitle = displayTitle(candidate)
    prepared.normalizedSearchText = normalize(
      searchText(candidate))
    return prepared
  }

  static func score(
    query: String,
    candidate: Candidate,
    normalize: (String) -> String = NormalModeDispatcher.normalizedSearchText,
    fuzzyScore: (String, String) -> Int? = NormalModeDispatcher.fuzzyScore(
      normalizedQuery:normalizedCandidate:)
  ) -> Int? {
    let normalizedQuery = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
    if normalizedQuery.isEmpty { return 0 }

    var best: Int?
    if let titleScore = fieldScore(
      query: normalizedQuery,
      field: candidate.name,
      base: 10_000,
      normalize: normalize,
      fuzzyScore: fuzzyScore)
    {
      best = max(best ?? titleScore, titleScore)
    }
    if let sourceTitleScore = fieldScore(
      query: normalizedQuery,
      field: "\(candidate.source) \(candidate.name)",
      base: 8_000,
      normalize: normalize,
      fuzzyScore: fuzzyScore)
    {
      best = max(best ?? sourceTitleScore, sourceTitleScore)
    }
    if let urlScore = fieldScore(
      query: normalizedQuery,
      field: urlSearchText(candidate),
      base: 9_000,
      normalize: normalize,
      fuzzyScore: fuzzyScore)
    {
      best = max(best ?? urlScore, urlScore)
    }
    if let displayScore = fieldScore(
      query: normalizedQuery,
      field: candidate.displayTitle,
      base: 7_000,
      normalize: normalize,
      fuzzyScore: fuzzyScore)
    {
      best = max(best ?? displayScore, displayScore)
    }
    if let searchScore = fuzzyScore(normalizedQuery, candidate.normalizedSearchText) {
      best = max(best ?? searchScore, searchScore)
    }
    return best
  }

  static func isAlive(_ candidate: Candidate) -> Bool {
    candidate.pid != nil
  }

  static func sortedMatches(_ matches: [CandidateMatch]) -> [CandidateMatch] {
    matches.sorted { lhs, rhs in
      let lhsAlive = isAlive(lhs.candidate)
      let rhsAlive = isAlive(rhs.candidate)
      if lhsAlive != rhsAlive { return lhsAlive }
      if lhs.score != rhs.score { return lhs.score > rhs.score }

      let titleOrder = lhs.candidate.name.localizedCaseInsensitiveCompare(rhs.candidate.name)
      if titleOrder != .orderedSame { return titleOrder == .orderedAscending }

      let sourceOrder = lhs.candidate.source.localizedCaseInsensitiveCompare(rhs.candidate.source)
      if sourceOrder != .orderedSame { return sourceOrder == .orderedAscending }

      let lhsDisplay = lhs.candidate.displayTitle.isEmpty
        ? displayTitle(lhs.candidate) : lhs.candidate.displayTitle
      let rhsDisplay = rhs.candidate.displayTitle.isEmpty
        ? displayTitle(rhs.candidate) : rhs.candidate.displayTitle
      let displayOrder = lhsDisplay.localizedCaseInsensitiveCompare(rhsDisplay)
      if displayOrder != .orderedSame { return displayOrder == .orderedAscending }

      return lhs.candidate.sourceID < rhs.candidate.sourceID
    }
  }

  private static func browserTabDisplayTitle(_ candidate: Candidate) -> String {
    let candidateTitle = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = browserTabURLString(candidate) ?? ""
    let title: String
    if candidateTitle.isEmpty || candidateTitle == url {
      title = url.isEmpty ? candidateTitle : url
    } else if url.isEmpty {
      title = candidateTitle
    } else {
      title = "\(candidateTitle) (\(url))"
    }
    return displayTitle(source: candidate.source, name: title)
  }

  private static func browserTabURLString(_ candidate: Candidate) -> String? {
    guard candidate.kind == .browserTab else { return nil }
    if let url = candidate.url?.absoluteString, !url.isEmpty {
      return url
    }
    let payload = candidate.sourcePayload?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return payload.isEmpty ? nil : payload
  }

  private static func searchText(_ candidate: Candidate) -> String {
    "\(candidate.source) \(candidate.name) \(urlSearchText(candidate)) \(browserTabTitleDomainAliases(candidate))"
  }

  private static func urlSearchText(_ candidate: Candidate) -> String {
    if let url = browserTabURLString(candidate), !url.isEmpty {
      return url
    }
    guard let url = candidate.url else { return "" }
    return url.isFileURL ? url.path : url.absoluteString
  }

  private static func browserTabTitleDomainAliases(_ candidate: Candidate) -> String {
    guard
      candidate.kind == .browserTab,
      let url = candidate.url,
      let host = url.host
    else { return "" }
    let parts = host.split(separator: ".")
    guard let suffix = parts.last, suffix.count >= 2 else { return "" }
    let separators = CharacterSet.alphanumerics.inverted
    let tokens = candidate.name
      .components(separatedBy: separators)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return tokens.map { "\($0).\(suffix)" }.joined(separator: " ")
  }

  private static func fieldScore(
    query: String,
    field: String,
    base: Int,
    normalize: (String) -> String,
    fuzzyScore: (String, String) -> Int?
  ) -> Int? {
    let normalizedField = normalize(field)
    guard !normalizedField.isEmpty else { return nil }
    if normalizedField == query {
      return base + 1_000
    }
    if normalizedField.hasPrefix(query) {
      return base + 700 - min(200, normalizedField.count - query.count)
    }
    if let range = normalizedField.range(of: query) {
      let offset = normalizedField.distance(from: normalizedField.startIndex, to: range.lowerBound)
      return base + 400 - min(300, offset * 4) - min(120, normalizedField.count - query.count)
    }
    guard let fuzzy = fuzzyScore(query, normalizedField) else { return nil }
    return base + min(300, fuzzy)
  }

  static func mergeAppCandidates(
    running: [Candidate],
    installed: [Candidate]
  ) -> [Candidate] {
    var byIdentifier: [String: Candidate] = [:]
    var byPath: [String: Candidate] = [:]

    for candidate in running {
      if !candidate.bundleIdentifier.isEmpty {
        byIdentifier[candidate.bundleIdentifier] = candidate
      } else if let path = candidate.url?.path {
        byPath[path] = candidate
      }
    }

    for candidate in installed {
      if !candidate.bundleIdentifier.isEmpty {
        if byIdentifier[candidate.bundleIdentifier]?.pid == nil {
          byIdentifier[candidate.bundleIdentifier] = candidate
        }
      } else if let path = candidate.url?.path {
        byPath[path] = candidate
      }
    }

    return (Array(byIdentifier.values) + Array(byPath.values)).sorted { lhs, rhs in
      lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }
}
