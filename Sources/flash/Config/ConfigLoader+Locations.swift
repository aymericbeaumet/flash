import FlashCore
import Foundation
import TOMLKit

/// Where each key of a parsed file sits, for diagnostics that point at a line.
extension ConfigLoader {
  struct ConfigSourceLocationIndex {
    private var locations: [[String]: ConfigLocation] = [:]

    init(text: String) {
      var tablePath: [String] = []
      var tableArrayIndexes: [String: Int] = [:]
      var inMultilineBasicString = false

      for (offset, linePart) in text.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      {
        let lineNumber = offset + 1
        let rawLine = String(linePart)

        if inMultilineBasicString {
          if rawLine.contains("\"\"\"") {
            inMultilineBasicString = false
          }
          continue
        }

        let line = Self.stripLineComment(rawLine).trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }

        if line.hasPrefix("[["), let close = line.range(of: "]]"),
          close.lowerBound > line.index(line.startIndex, offsetBy: 2)
        {
          let body = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
            .trimmingCharacters(in: .whitespaces)
          let index = tableArrayIndexes[body, default: 0]
          tableArrayIndexes[body] = index + 1
          tablePath = Self.splitDottedKey(body) + [String(index)]
          for length in 1...tablePath.count where locations[Array(tablePath.prefix(length))] == nil
          {
            locations[Array(tablePath.prefix(length))] = ConfigLocation(line: lineNumber, column: 1)
          }
          continue
        }

        if line.hasPrefix("["),
          let close = line.firstIndex(of: "]")
        {
          let body = String(line[line.index(after: line.startIndex)..<close])
            .trimmingCharacters(in: .whitespaces)
          tablePath = Self.splitDottedKey(body)
          // A nested table header also locates diagnostics about its parents.
          if !tablePath.isEmpty {
            for length in 1...tablePath.count
            where locations[Array(tablePath.prefix(length))] == nil {
              locations[Array(tablePath.prefix(length))] = ConfigLocation(
                line: lineNumber, column: 1)
            }
          }
          continue
        }

        guard let equals = Self.firstUnquotedEquals(in: rawLine) else { continue }
        let rawKey = String(rawLine[..<equals]).trimmingCharacters(in: .whitespaces)
        let keyPath = Self.splitDottedKey(rawKey)
        guard !keyPath.isEmpty else { continue }

        if Self.startsMultilineBasicString(after: equals, in: rawLine) {
          inMultilineBasicString = true
        }
        let column = Self.valueColumn(after: equals, in: rawLine)
        locations[tablePath + keyPath] = ConfigLocation(line: lineNumber, column: column)
      }
    }

    func location(for path: [String]) -> ConfigLocation? {
      locations[path]
    }

    private static func stripLineComment(_ raw: String) -> String {
      var result = ""
      var inString = false
      var escaping = false
      var quote: Character?
      for ch in raw {
        if inString {
          result.append(ch)
          if escaping {
            escaping = false
          } else if ch == "\\" {
            escaping = true
          } else if ch == quote {
            inString = false
            quote = nil
          }
          continue
        }
        if ch == "\"" || ch == "'" {
          inString = true
          quote = ch
          result.append(ch)
          continue
        }
        if ch == "#" { break }
        result.append(ch)
      }
      return result
    }

    private static func firstUnquotedEquals(in raw: String) -> String.Index? {
      var inString = false
      var escaping = false
      var quote: Character?
      var index = raw.startIndex
      while index < raw.endIndex {
        let ch = raw[index]
        if inString {
          if escaping {
            escaping = false
          } else if ch == "\\" {
            escaping = true
          } else if ch == quote {
            inString = false
            quote = nil
          }
        } else if ch == "\"" || ch == "'" {
          inString = true
          quote = ch
        } else if ch == "=" {
          return index
        }
        index = raw.index(after: index)
      }
      return nil
    }

    private static func valueColumn(after equals: String.Index, in raw: String) -> Int {
      var index = raw.index(after: equals)
      while index < raw.endIndex, raw[index].isWhitespace {
        index = raw.index(after: index)
      }
      return raw.distance(from: raw.startIndex, to: index) + 1
    }

    private static func startsMultilineBasicString(after equals: String.Index, in raw: String)
      -> Bool
    {
      var index = raw.index(after: equals)
      while index < raw.endIndex, raw[index].isWhitespace {
        index = raw.index(after: index)
      }
      guard index < raw.endIndex else { return false }
      return raw[index...].hasPrefix("\"\"\"")
        && raw[index...].dropFirst(3).contains("\"\"\"") == false
    }

    private static func splitDottedKey(_ raw: String) -> [String] {
      var parts: [String] = []
      var current = ""
      var inString = false
      var escaping = false
      var quote: Character?

      func appendCurrent() {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
          parts.append(trimmed)
        }
        current = ""
      }

      for ch in raw {
        if inString {
          if escaping {
            current.append(ch)
            escaping = false
          } else if ch == "\\" {
            escaping = true
          } else if ch == quote {
            inString = false
            quote = nil
          } else {
            current.append(ch)
          }
          continue
        }

        if ch == "\"" || ch == "'" {
          inString = true
          quote = ch
          continue
        }
        if ch == "." {
          appendCurrent()
          continue
        }
        current.append(ch)
      }
      appendCurrent()
      return parts
    }
  }
}
