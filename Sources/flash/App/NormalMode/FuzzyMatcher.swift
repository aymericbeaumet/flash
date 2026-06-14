import Foundation

/// Fuzzy match scoring + highlight extraction for `:open` / `:flashlight`
/// candidate finders. The interpreter normalises strings once before
/// the scoring pass so per-candidate work is just the score+LCS math.
///
/// Split out of NormalMode.swift; same public surface, no behaviour
/// change.
extension NormalModeDispatcher {
  static func fuzzyScore(query rawQuery: String, candidate rawCandidate: String) -> Int? {
    let query = normalizedSearchText(rawQuery)
    let candidate = normalizedSearchText(rawCandidate)
    return fuzzyScore(normalizedQuery: query, normalizedCandidate: candidate)
  }

  static func fuzzyScore(normalizedQuery query: String, normalizedCandidate candidate: String)
    -> Int?
  {
    if query.isEmpty { return 0 }
    guard !candidate.isEmpty else { return nil }

    var best: Int?
    if let exact = exactContainmentScore(query: query, candidate: candidate) {
      best = max(best ?? exact, exact)
    }
    if let ordered = orderedMatchScore(query: query, candidate: candidate) {
      best = max(best ?? ordered, ordered)
    }

    let queryCompact = query.filter { !$0.isWhitespace }
    let compactCandidate = candidate.filter { !$0.isWhitespace }
    for segment in searchSegments(candidate: candidate) + [compactCandidate] {
      guard let score = typoScore(query: queryCompact, segment: segment) else { continue }
      best = max(best ?? score, score)
    }
    return best
  }

  static func fuzzyHighlightRanges(query rawQuery: String, candidate rawCandidate: String)
    -> [Range<Int>]
  {
    let query = normalizedSearchText(rawQuery).filter { !$0.isWhitespace }
    guard !query.isEmpty, !rawCandidate.isEmpty else { return [] }

    let indexedChars = rawCandidate.enumerated().compactMap { offset, ch -> (Int, Character)? in
      guard let scalar = String(ch).lowercased().unicodeScalars.first,
        isSearchableScalar(scalar)
      else { return nil }
      return (offset, Character(String(scalar)))
    }
    guard !indexedChars.isEmpty else { return [] }

    let compactCandidate = String(indexedChars.map(\.1))
    if let range = compactCandidate.range(of: query) {
      let start = compactCandidate.distance(from: compactCandidate.startIndex, to: range.lowerBound)
      let end = compactCandidate.distance(from: compactCandidate.startIndex, to: range.upperBound)
      return mergeCharacterOffsets(indexedChars[start..<end].map(\.0))
    }

    if let ordered = orderedHighlightOffsets(query: query, indexedChars: indexedChars) {
      return mergeCharacterOffsets(ordered)
    }

    return mergeCharacterOffsets(lcsHighlightOffsets(query: query, indexedChars: indexedChars))
  }

  static func normalizedSearchText(_ value: String) -> String {
    var out = ""
    var previousWasSpace = false
    for scalar in value.lowercased().unicodeScalars {
      if isSearchableScalar(scalar) {
        out.unicodeScalars.append(scalar)
        previousWasSpace = false
      } else if !previousWasSpace {
        out.append(" ")
        previousWasSpace = true
      }
    }
    return out.trimmed
  }

  private static func orderedHighlightOffsets(
    query: String,
    indexedChars: [(Int, Character)]
  ) -> [Int]? {
    var offsets: [Int] = []
    var queryIndex = query.startIndex
    for (offset, ch) in indexedChars where queryIndex < query.endIndex {
      if ch == query[queryIndex] {
        offsets.append(offset)
        queryIndex = query.index(after: queryIndex)
      }
    }
    return queryIndex == query.endIndex ? offsets : nil
  }

  private static func lcsHighlightOffsets(
    query: String,
    indexedChars: [(Int, Character)]
  ) -> [Int] {
    let q = Array(query)
    let c = indexedChars.map(\.1)
    guard !q.isEmpty, !c.isEmpty else { return [] }

    var table = Array(
      repeating: Array(repeating: 0, count: c.count + 1),
      count: q.count + 1)
    for qi in stride(from: q.count - 1, through: 0, by: -1) {
      for ci in stride(from: c.count - 1, through: 0, by: -1) {
        if q[qi] == c[ci] {
          table[qi][ci] = table[qi + 1][ci + 1] + 1
        } else {
          table[qi][ci] = max(table[qi + 1][ci], table[qi][ci + 1])
        }
      }
    }

    var offsets: [Int] = []
    var qi = 0
    var ci = 0
    while qi < q.count, ci < c.count {
      if q[qi] == c[ci] {
        offsets.append(indexedChars[ci].0)
        qi += 1
        ci += 1
      } else if table[qi + 1][ci] >= table[qi][ci + 1] {
        qi += 1
      } else {
        ci += 1
      }
    }
    return offsets
  }

  private static func mergeCharacterOffsets(_ offsets: [Int]) -> [Range<Int>] {
    let sorted = offsets.sorted()
    guard var start = sorted.first else { return [] }
    var previous = start
    var ranges: [Range<Int>] = []
    for offset in sorted.dropFirst() {
      if offset == previous + 1 {
        previous = offset
      } else {
        ranges.append(start..<previous + 1)
        start = offset
        previous = offset
      }
    }
    ranges.append(start..<previous + 1)
    return ranges
  }

  private static func exactContainmentScore(query: String, candidate: String) -> Int? {
    guard let range = candidate.range(of: query) else { return nil }
    let offset = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
    return 220 - min(80, offset * 3) - max(0, candidate.count - query.count) / 6
  }

  private static func orderedMatchScore(query: String, candidate: String) -> Int? {
    let query = Array(query.filter { !$0.isWhitespace })
    let candidate = Array(candidate)
    guard !query.isEmpty else { return 0 }
    var queryIndex = 0
    var score = 0
    var previousMatchIndex: Int?
    for (candidateIndex, ch) in candidate.enumerated() {
      guard queryIndex < query.count else { break }
      guard ch == query[queryIndex] else { continue }
      score += 10
      if candidateIndex == 0 {
        score += 8
      } else {
        let previous = candidate[candidateIndex - 1]
        if previous == " " || previous == "-" || previous == "_" || previous == "."
          || previous == "#"
        {
          score += 6
        }
      }
      if let previousMatchIndex {
        score +=
          candidateIndex == previousMatchIndex + 1
          ? 8 : -min(6, candidateIndex - previousMatchIndex - 1)
      }
      previousMatchIndex = candidateIndex
      queryIndex += 1
    }
    guard queryIndex == query.count else { return nil }
    return 140 + score - max(0, candidate.count - query.count) / 4
  }

  private static func isSearchableScalar(_ scalar: UnicodeScalar) -> Bool {
    CharacterSet.alphanumerics.contains(scalar) || scalar.value == 35
  }

  private static func searchSegments(candidate: String) -> [String] {
    candidate
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
      .filter { !$0.isEmpty }
  }

  private static func typoScore(query: String, segment: String) -> Int? {
    guard !query.isEmpty, !segment.isEmpty else { return nil }
    let maxEdits = allowedTypoCount(query.count)
    guard query.count <= segment.count + maxEdits else { return nil }
    let prefixLength = min(segment.count, query.count + maxEdits)
    let prefix = String(segment.prefix(prefixLength))
    guard let distance = boundedEditDistance(query, prefix, maxDistance: maxEdits) else {
      return nil
    }
    return 105 - distance * 24 - abs(prefix.count - query.count) * 3
      - max(0, segment.count - query.count) / 4
  }

  private static func allowedTypoCount(_ length: Int) -> Int {
    if length <= 2 { return 0 }
    if length <= 5 { return 1 }
    return 2
  }

  private static func boundedEditDistance(
    _ lhs: String,
    _ rhs: String,
    maxDistance: Int
  ) -> Int? {
    let a = Array(lhs)
    let b = Array(rhs)
    if abs(a.count - b.count) > maxDistance { return nil }
    var previous = Array(0...b.count)
    var current = Array(repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = i
      var rowMin = current[0]
      for j in 1...b.count {
        let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
        let insertion = current[j - 1] + 1
        let deletion = previous[j] + 1
        current[j] = min(substitution, insertion, deletion)
        rowMin = min(rowMin, current[j])
      }
      if rowMin > maxDistance { return nil }
      swap(&previous, &current)
    }
    return previous[b.count] <= maxDistance ? previous[b.count] : nil
  }
}
