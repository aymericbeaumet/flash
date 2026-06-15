import Foundation

// Line-level lexer for the hand-rolled TOML subset. Splits the input file
// into `LogicalLine`s, joins multi-line array values back together, strips
// unquoted comments, and provides the few column helpers the diagnostic
// path needs to point error markers at the right column. The actual `parse`
// pass in ConfigLoader iterates these lines and dispatches each one to
// `apply`.

extension ConfigLoader {
  struct LogicalLine {
    var lineNumber: Int
    var rawLine: String
  }

  static func logicalLines(from text: String) -> [LogicalLine] {
    var lines: [LogicalLine] = []
    var collectedLineNumber = 0
    var collectedRaw = ""
    var arrayDepth = 0
    /// Mode the collector is currently in: nil = single-line, `.array` =
    /// inside `key = [` … `]`, `.multilineString` = inside `key = """` …
    /// `"""`. The string mode skips `stripUnquotedComment` and the
    /// bracket-depth bookkeeping — a `#` inside a string is content, and
    /// a `[` inside a string is also content.
    var collectMode: CollectMode = .none

    func appendCollectedIfComplete() {
      guard arrayDepth <= 0 else { return }
      lines.append(LogicalLine(lineNumber: collectedLineNumber, rawLine: collectedRaw))
      collectedLineNumber = 0
      collectedRaw = ""
      arrayDepth = 0
      collectMode = .none
    }

    for (lineOffset, rawLinePart) in text.split(
      separator: "\n", omittingEmptySubsequences: false
    ).enumerated() {
      let lineNumber = lineOffset + 1
      let rawLine = String(rawLinePart)

      if collectMode == .multilineString {
        collectedRaw += "\n" + rawLine
        if rawLine.contains("\"\"\"") {
          collectMode = .none
          lines.append(LogicalLine(lineNumber: collectedLineNumber, rawLine: collectedRaw))
          collectedLineNumber = 0
          collectedRaw = ""
        }
        continue
      }

      let lineWithoutComment = stripUnquotedComment(rawLine)

      if collectMode == .array {
        collectedRaw += "\n" + lineWithoutComment
        arrayDepth += bracketDelta(in: lineWithoutComment)
        appendCollectedIfComplete()
        continue
      }

      if startsMultilineString(rawLine: rawLine) {
        collectedLineNumber = lineNumber
        collectedRaw = rawLine
        collectMode = .multilineString
        // The same line may also contain the closing `"""` when the user
        // writes the whole literal on one row (rare, but the parser must
        // still terminate cleanly).
        if let close = closingTripleQuoteIndex(in: rawLine) {
          _ = close
          collectMode = .none
          lines.append(LogicalLine(lineNumber: collectedLineNumber, rawLine: collectedRaw))
          collectedLineNumber = 0
          collectedRaw = ""
        }
        continue
      }

      guard startsMultilineArray(rawLine: lineWithoutComment) else {
        lines.append(LogicalLine(lineNumber: lineNumber, rawLine: rawLine))
        continue
      }

      collectedLineNumber = lineNumber
      collectedRaw = lineWithoutComment
      arrayDepth = bracketDelta(in: lineWithoutComment)
      collectMode = .array
      appendCollectedIfComplete()
    }

    if collectedLineNumber != 0 {
      lines.append(LogicalLine(lineNumber: collectedLineNumber, rawLine: collectedRaw))
    }
    return lines
  }

  private enum CollectMode {
    case none
    case array
    case multilineString
  }

  /// True when `rawLine` opens a TOML multi-line basic string (`key = """`)
  /// that doesn't close on the same line. Counts the `"""` triples so a
  /// single-line `key = """short"""` literal stays single-line.
  static func startsMultilineString(rawLine: String) -> Bool {
    guard let eqIdx = rawLine.firstIndex(of: "=") else { return false }
    let valuePart = rawLine[rawLine.index(after: eqIdx)...]
      .trimmingCharacters(in: .whitespaces)
    guard valuePart.hasPrefix("\"\"\"") else { return false }
    var count = 0
    var idx = valuePart.startIndex
    while let next = valuePart.range(of: "\"\"\"", range: idx..<valuePart.endIndex) {
      count += 1
      idx = next.upperBound
    }
    return count == 1
  }

  /// First `"""` index in `rawLine` if the line completes a multi-line
  /// string opened earlier (or self-contains a `"""…"""` literal).
  static func closingTripleQuoteIndex(in rawLine: String) -> String.Index? {
    guard let eqIdx = rawLine.firstIndex(of: "=") else { return nil }
    let after = rawLine.index(after: eqIdx)
    let valuePart = rawLine[after...]
    let trimmed = valuePart.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("\"\"\"") else { return nil }
    // Skip the opening `"""` then look for the next one.
    guard let openRange = valuePart.range(of: "\"\"\"") else { return nil }
    return valuePart.range(of: "\"\"\"", range: openRange.upperBound..<valuePart.endIndex)?
      .lowerBound
  }

  static func startsMultilineArray(rawLine: String) -> Bool {
    var line = rawLine.trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty, !line.hasPrefix("#"), let eqIdx = line.firstIndex(of: "=") else {
      return false
    }
    line = String(line[line.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)
    guard line.hasPrefix("[") else { return false }
    return bracketDelta(in: line) > 0
  }

  static func stripUnquotedComment(_ line: String) -> String {
    guard let hashIdx = unquotedCommentIndex(in: line) else { return line }
    return String(line[..<hashIdx])
  }

  static func bracketDelta(in line: String) -> Int {
    var delta = 0
    var inString = false
    var escaped = false

    for c in line {
      if escaped {
        escaped = false
        continue
      }
      if inString, c == "\\" {
        escaped = true
        continue
      }
      if c == "\"" {
        inString.toggle()
        continue
      }
      guard !inString else { continue }
      if c == "[" {
        delta += 1
      } else if c == "]" {
        delta -= 1
      }
    }
    return delta
  }

  static func unquotedCommentIndex(in line: String) -> String.Index? {
    var inString = false
    var escaped = false
    var i = line.startIndex
    while i < line.endIndex {
      let c = line[i]
      if escaped {
        escaped = false
      } else if inString && c == "\\" {
        escaped = true
      } else if c == "\"" {
        inString.toggle()
      } else if c == "#" && !inString {
        return i
      }
      i = line.index(after: i)
    }
    return nil
  }

  static func firstNonWhitespaceColumn(in rawLine: String) -> Int {
    guard let idx = rawLine.firstIndex(where: { !$0.isWhitespace }) else { return 1 }
    return columnNumber(in: rawLine, at: idx)
  }

  static func valueColumn(in rawLine: String) -> Int? {
    guard var idx = rawLine.firstIndex(of: "=") else { return nil }
    idx = rawLine.index(after: idx)
    while idx < rawLine.endIndex, rawLine[idx].isWhitespace {
      idx = rawLine.index(after: idx)
    }
    guard idx < rawLine.endIndex else { return columnNumber(in: rawLine, at: rawLine.endIndex) }
    return columnNumber(in: rawLine, at: idx)
  }

  static func columnNumber(in rawLine: String, at idx: String.Index) -> Int {
    rawLine.distance(from: rawLine.startIndex, to: idx) + 1
  }

  static func splitTablePath(_ raw: String) -> [String] {
    var parts: [String] = []
    var buf = ""
    var inString = false
    for c in raw {
      if c == "\"" {
        inString.toggle()
        continue
      }
      if c == "." && !inString {
        parts.append(buf)
        buf = ""
        continue
      }
      buf.append(c)
    }
    if !buf.isEmpty { parts.append(buf) }
    return parts.map { $0.trimmingCharacters(in: .whitespaces) }
  }
}
