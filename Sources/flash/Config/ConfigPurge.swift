import Foundation
import TOMLKit

/// Drops single-line assignments whose value still equals the bundled
/// default. Comments, blank lines, headers and multiline strings stay, and
/// nothing is written: the caller decides whether to save the result.
enum ConfigPurge {
  static func purgeDefaults(in source: String, defaults defaultsText: String) -> String {
    guard let defaults = try? TOMLTable(string: defaultsText) else { return source }
    var header: [String] = []
    var skippingArray = false
    var multiline: String?
    var kept: [(text: String, ending: String)] = []
    for piece in pieces(of: source) {
      let line = piece.text
      if let delimiter = multiline {
        kept.append(piece)
        if line.trimmingCharacters(in: .whitespaces) == delimiter { multiline = nil }
        continue
      }
      if let opener = multilineOpener(line) {
        multiline = opener
        kept.append(piece)
        continue
      }
      if let section = sectionHeader(line) {
        skippingArray = section.array
        if !section.array { header = section.parts }
        kept.append(piece)
        continue
      }
      if skippingArray || !drops(line, header: header, defaults: defaults) {
        kept.append(piece)
      }
    }
    return kept.map { $0.text + $0.ending }.joined()
  }

  /// nil when `text` is empty or parses as TOML. The message is the parse
  /// error otherwise. A save uses this so a warning is not a rejection.
  static func tomlError(in text: String) -> String? {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
    do {
      _ = try TOMLTable(string: text)
      return nil
    } catch {
      return String(describing: error)
    }
  }

  private static func drops(_ line: String, header: [String], defaults: TOMLTable) -> Bool {
    guard let keyText = textBeforeEquals(line) else { return false }
    let parts = splitKey(keyText)
    guard !parts.isEmpty, let parsed = try? TOMLTable(string: line) else { return false }
    guard let value = lookup(table: parsed, parts: parts) else { return false }
    guard let expected = lookup(table: defaults, parts: header + parts) else { return false }
    return same(value, expected)
  }

  private static func lookup(
    table: TOMLTable, parts: [String]
  ) -> (any TOMLValueConvertible)? {
    guard let first = parts.first, let value = table[first] else { return nil }
    let rest = Array(parts.dropFirst())
    if rest.isEmpty { return value }
    guard let nested = value.table else { return nil }
    return lookup(table: nested, parts: rest)
  }

  private static func same(_ lhs: any TOMLValueConvertible, _ rhs: any TOMLValueConvertible) -> Bool
  {
    if let left = lhs.bool, let right = rhs.bool { return left == right }
    if let left = number(lhs), let right = number(rhs) { return left == right }
    if let left = lhs.string, let right = rhs.string { return left == right }
    if let left = lhs.array, let right = rhs.array {
      guard left.count == right.count else { return false }
      return zip(left, right).allSatisfy { same($0, $1) }
    }
    if let left = lhs.table, let right = rhs.table {
      let leftKeys = keySet(left)
      guard leftKeys == keySet(right) else { return false }
      return leftKeys.allSatisfy { key in
        guard let leftValue = left[key], let rightValue = right[key] else { return false }
        return same(leftValue, rightValue)
      }
    }
    return false
  }

  private static func number(_ value: any TOMLValueConvertible) -> Double? {
    if let int = value.int { return Double(int) }
    return value.double
  }

  private static func keySet(_ table: TOMLTable) -> Set<String> {
    var keys = Set<String>()
    for (key, _) in table { keys.insert(key) }
    return keys
  }

  private static func pieces(of text: String) -> [(text: String, ending: String)] {
    var result: [(text: String, ending: String)] = []
    var current = ""
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      let next = text.index(after: index)
      if character == "\r" {
        if next < text.endIndex, text[next] == "\n" {
          result.append((current, "\r\n"))
          current = ""
          index = text.index(after: next)
          continue
        }
        result.append((current, "\r"))
        current = ""
        index = next
        continue
      }
      if character == "\n" {
        result.append((current, "\n"))
        current = ""
        index = next
        continue
      }
      current.append(character)
      index = next
    }
    if !current.isEmpty || result.isEmpty { result.append((current, "")) }
    return result
  }

  private static func multilineOpener(_ line: String) -> String? {
    for delimiter in ["\"\"\"", "'''"] {
      guard let range = line.range(of: delimiter) else { continue }
      if !line[range.upperBound...].contains(delimiter) { return delimiter }
    }
    return nil
  }

  private static func sectionHeader(_ line: String) -> (array: Bool, parts: [String])? {
    let trimmed = stripTrailingComment(line).trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("[") else { return nil }
    let array = trimmed.hasPrefix("[[")
    guard array ? trimmed.hasSuffix("]]") : trimmed.hasSuffix("]") else { return nil }
    let inner =
      array
      ? trimmed.dropFirst(2).dropLast(2)
      : trimmed.dropFirst().dropLast()
    let parts = splitKey(String(inner))
    guard !parts.isEmpty else { return nil }
    return (array, parts)
  }

  private static func stripTrailingComment(_ line: String) -> String {
    var quote: Character?
    var result = ""
    for character in line {
      if let active = quote {
        result.append(character)
        if character == active { quote = nil }
        continue
      }
      if character == "\"" || character == "'" {
        quote = character
        result.append(character)
        continue
      }
      if character == "#" { break }
      result.append(character)
    }
    return result
  }

  /// The key text before the first `=` that is outside quotes, or nil when
  /// the line is not an assignment.
  private static func textBeforeEquals(_ line: String) -> String? {
    var quote: Character?
    var escaped = false
    for (offset, character) in line.enumerated() {
      if let active = quote {
        if escaped {
          escaped = false
          continue
        }
        if character == "\\" && active == "\"" {
          escaped = true
          continue
        }
        if character == active { quote = nil }
        continue
      }
      if character == "\"" || character == "'" {
        quote = character
        continue
      }
      if character == "#" { return nil }
      if character == "=" { return String(line.prefix(offset)) }
    }
    return nil
  }

  private static func splitKey(_ raw: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var quote: Character?
    for character in raw {
      if let active = quote {
        if character == active {
          quote = nil
        } else {
          current.append(character)
        }
        continue
      }
      if character == "\"" || character == "'" {
        quote = character
        continue
      }
      if character == "." {
        parts.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
        continue
      }
      current.append(character)
    }
    parts.append(current.trimmingCharacters(in: .whitespaces))
    return parts.filter { !$0.isEmpty }
  }
}
