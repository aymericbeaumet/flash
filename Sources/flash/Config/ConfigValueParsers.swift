import Foundation

// Leaf parsers for the hand-rolled TOML subset used by Flash. Each one
// returns nil on malformed input so the caller can record a clean
// diagnostic instead of throwing — silent failure is acceptable here
// because the calling `apply` site already has the source location and
// emits the user-facing error message.

extension ConfigLoader {
  static func parseString(_ v: String) -> String? {
    if v.hasPrefix("\"\"\""), v.hasSuffix("\"\"\""), v.count >= 6 {
      return parseMultilineBasicString(v)
    }
    guard v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 else { return nil }
    var out = ""
    var escaping = false
    for ch in v.dropFirst().dropLast() {
      if escaping {
        switch ch {
        case "\\":
          out.append("\\")
        case "\"":
          out.append("\"")
        case "n":
          out.append("\n")
        case "r":
          out.append("\r")
        case "t":
          out.append("\t")
        default:
          out.append("\\")
          out.append(ch)
        }
        escaping = false
      } else if ch == "\\" {
        escaping = true
      } else {
        out.append(ch)
      }
    }
    if escaping {
      out.append("\\")
    }
    return out
  }

  /// TOML basic multi-line string (`"""…"""`). The opening `"""` may be
  /// followed immediately by a newline that is stripped; a backslash at
  /// end of line trims that backslash, the trailing whitespace, the
  /// newline, *and* any leading whitespace on the next line — matching
  /// the line-continuation rule the user expects (write the prose on
  /// several rows, render it as one). Standard `\n`, `\t`, `\"`, `\\`
  /// escapes are honoured inline; everything else is a content character.
  private static func parseMultilineBasicString(_ v: String) -> String? {
    var body = String(v.dropFirst(3).dropLast(3))
    // TOML strips an immediate newline after the opening `"""`.
    if body.hasPrefix("\r\n") { body.removeFirst(2) }
    if body.hasPrefix("\n") { body.removeFirst() }
    var out = ""
    var index = body.startIndex
    while index < body.endIndex {
      let ch = body[index]
      if ch == "\\" {
        let next = body.index(after: index)
        if next == body.endIndex {
          out.append("\\")
          break
        }
        let following = body[next]
        switch following {
        case "\\":
          out.append("\\")
          index = body.index(after: next)
        case "\"":
          out.append("\"")
          index = body.index(after: next)
        case "n":
          out.append("\n")
          index = body.index(after: next)
        case "r":
          out.append("\r")
          index = body.index(after: next)
        case "t":
          out.append("\t")
          index = body.index(after: next)
        case " ", "\t", "\n", "\r":
          // Line continuation: backslash + trailing whitespace + newline +
          // leading whitespace on the next non-blank-or-whitespace line
          // are collapsed away.
          var skip = next
          while skip < body.endIndex,
            body[skip].isWhitespace,
            body[skip] != "\n"
          {
            skip = body.index(after: skip)
          }
          guard skip < body.endIndex, body[skip] == "\n" else {
            // Backslash followed by whitespace but no newline — emit the
            // backslash literally and let the next iteration consume the
            // whitespace as content.
            out.append("\\")
            index = next
            continue
          }
          var skip2 = body.index(after: skip)
          while skip2 < body.endIndex, body[skip2].isWhitespace {
            skip2 = body.index(after: skip2)
          }
          index = skip2
        default:
          out.append("\\")
          out.append(following)
          index = body.index(after: next)
        }
        continue
      }
      out.append(ch)
      index = body.index(after: index)
    }
    return out
  }

  static func parseBool(_ v: String) -> Bool? {
    switch v {
    case "true": return true
    case "false": return false
    default: return nil
    }
  }

  static func parseInt(_ v: String) -> Int? { Int(v) }
  static func parseDouble(_ v: String) -> Double? { Double(v) }

  /// Infer the type of a `[plugin.<id>]` value. Order matters: bool and
  /// int are checked before string so `true` / `42` come through typed,
  /// and quoted/array forms are recognized before falling back to a bare
  /// string.
  static func parsePluginConfigValue(_ v: String) -> PluginConfigValue? {
    if let bool = parseBool(v) { return .bool(bool) }
    if let int = parseInt(v) { return .int(int) }
    if let double = parseDouble(v) { return .double(double) }
    if let array = parseStringArray(v) { return .stringArray(array) }
    if let string = parseString(v) { return .string(string) }
    return nil
  }

  static func parseInspectorHost(_ v: String) -> String? {
    let raw = parseString(v) ?? v.trimmed
    guard ["localhost", "127.0.0.1", "::1"].contains(raw) else { return nil }
    return raw
  }

  /// Parse a TOML inline table with string values:
  /// `{ normal = "N", insert = "I", command = "C" }`.
  /// This intentionally stays smaller than full TOML: bare keys and
  /// quoted string values only.
  static func parseInlineStringTable(_ v: String) -> [String: String]? {
    let trimmed = v.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
    let inner = trimmed.dropFirst().dropLast()
    var result: [String: String] = [:]
    var i = inner.startIndex

    func skipWhitespace() {
      while i < inner.endIndex, inner[i].isWhitespace {
        i = inner.index(after: i)
      }
    }

    while true {
      skipWhitespace()
      if i >= inner.endIndex { break }

      let keyStart = i
      while i < inner.endIndex,
        inner[i].isLetter || inner[i].isNumber || inner[i] == "_" || inner[i] == "-"
      {
        i = inner.index(after: i)
      }
      guard keyStart < i else { return nil }
      let key = String(inner[keyStart..<i])

      skipWhitespace()
      guard i < inner.endIndex, inner[i] == "=" else { return nil }
      i = inner.index(after: i)
      skipWhitespace()

      guard i < inner.endIndex, inner[i] == "\"" else { return nil }
      i = inner.index(after: i)
      var value = ""
      while i < inner.endIndex, inner[i] != "\"" {
        if inner[i] == "\\", inner.index(after: i) < inner.endIndex {
          i = inner.index(after: i)
          value.append(inner[i])
        } else {
          value.append(inner[i])
        }
        i = inner.index(after: i)
      }
      guard i < inner.endIndex else { return nil }
      i = inner.index(after: i)
      result[key] = value

      skipWhitespace()
      if i >= inner.endIndex { break }
      guard inner[i] == "," else { return nil }
      i = inner.index(after: i)
    }
    return result
  }

  /// Parse a TOML inline array of strings: `["a", "b", "c"]`.
  /// Returns nil when the input doesn't look like an array. Handles
  /// quoted strings with `\"` and `\\` escapes; rejects malformed
  /// input (unterminated quote, stray garbage) by returning nil.
  static func parseStringArray(_ v: String) -> [String]? {
    let trimmed = v.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
    let inner = trimmed.dropFirst().dropLast()
    var out: [String] = []
    var i = inner.startIndex
    while i < inner.endIndex {
      while i < inner.endIndex,
        inner[i].isWhitespace || inner[i] == ","
      {
        i = inner.index(after: i)
      }
      if i >= inner.endIndex { break }
      guard inner[i] == "\"" else { return nil }
      i = inner.index(after: i)
      var current = ""
      while i < inner.endIndex, inner[i] != "\"" {
        if inner[i] == "\\", inner.index(after: i) < inner.endIndex {
          i = inner.index(after: i)
          current.append(inner[i])
        } else {
          current.append(inner[i])
        }
        i = inner.index(after: i)
      }
      guard i < inner.endIndex else { return nil }
      out.append(current)
      i = inner.index(after: i)
    }
    return out
  }
}
