import AppKit
import Foundation

/// The ONE lexer for the status bar's tmux-flavoured markup. Every consumer
/// (template compile, region routing, truncation, style application, link
/// measurement) walks `[Token]` from here — the five hand-rolled scanners
/// this replaces each re-implemented the `#[…]` / `##` grammar with subtle
/// drift (the confirmed truncation-eats-`#[nocyc]` bug was one such).
enum FlashStatusBarMarkup {
  enum Token: Equatable {
    /// Visible text. Escapes are already applied: a template `##` arrives
    /// here as one `#`.
    case text(String)
    /// A `#[…]` marker body split into its space/comma-separated tokens.
    case marker([String])
    /// A `#{…}` template variable body (template mode only).
    case variable(String)
    /// A tmux one-letter alias (`#H`, `#S`, …; template mode only).
    case alias(Character)
  }

  /// Tokenize a *value* (plugin segment, script output): `#[…]` markers and
  /// `##` escapes only. `#{…}` in a value is literal text — dynamic values
  /// are never recursively expanded.
  static func tokenizeValue(_ raw: String) -> [Token] {
    tokenize(raw, template: false)
  }

  /// Tokenize the *template* string: markers, variables, and tmux aliases.
  static func tokenizeTemplate(_ raw: String) -> [Token] {
    tokenize(raw, template: true)
  }

  private static func tokenize(_ raw: String, template: Bool) -> [Token] {
    var tokens: [Token] = []
    var buffer = ""
    func flush() {
      if !buffer.isEmpty {
        tokens.append(.text(buffer))
        buffer = ""
      }
    }
    var index = raw.startIndex
    while index < raw.endIndex {
      guard raw[index] == "#",
        let next = raw.index(index, offsetBy: 1, limitedBy: raw.endIndex),
        next < raw.endIndex
      else {
        buffer.append(raw[index])
        index = raw.index(after: index)
        continue
      }
      let mark = raw[next]
      if mark == "#" {
        buffer.append("#")
        index = raw.index(after: next)
        continue
      }
      if mark == "[", let close = raw[next...].firstIndex(of: "]") {
        flush()
        let body = raw[raw.index(after: next)..<close]
        tokens.append(.marker(splitMarkerBody(body)))
        index = raw.index(after: close)
        continue
      }
      if template, mark == "{", let close = matchingBrace(in: raw, openingAt: next) {
        flush()
        tokens.append(.variable(String(raw[raw.index(after: next)..<close]).trimmed))
        index = raw.index(after: close)
        continue
      }
      if template, FlashStatusBarTemplateEngine.tmuxShortFormatToken(for: mark) != nil {
        flush()
        tokens.append(.alias(mark))
        index = raw.index(after: next)
        continue
      }
      buffer.append(raw[index])
      index = raw.index(after: index)
    }
    flush()
    return tokens
  }

  static func splitMarkerBody(_ body: Substring) -> [String] {
    body.split { $0 == " " || $0 == "," }.map(String.init)
  }

  /// The `}` closing the `{` at `open`, balanced against nested `#{…}` so
  /// tmux conditionals (`#{?cond,#{a},b}`) tokenize as ONE variable.
  static func matchingBrace(in raw: String, openingAt open: String.Index) -> String.Index? {
    var depth = 0
    var index = open
    while index < raw.endIndex {
      let ch = raw[index]
      if ch == "#",
        let next = raw.index(index, offsetBy: 1, limitedBy: raw.endIndex),
        next < raw.endIndex, raw[next] == "{"
      {
        depth += 1
        index = raw.index(after: next)
        continue
      }
      if ch == "{" && index == open {
        depth += 1
        index = raw.index(after: index)
        continue
      }
      if ch == "}" {
        depth -= 1
        if depth == 0 { return index }
      }
      index = raw.index(after: index)
    }
    return nil
  }

  /// Split a modifier's argument list on top-level commas — commas inside
  /// nested `#{…}` belong to the inner format, and `#,` escapes a literal
  /// comma (tmux's convention).
  static func splitFormatArguments(_ body: Substring) -> [String] {
    var args: [String] = []
    var current = ""
    var depth = 0
    var index = body.startIndex
    while index < body.endIndex {
      let ch = body[index]
      if ch == "#",
        let next = body.index(index, offsetBy: 1, limitedBy: body.endIndex),
        next < body.endIndex
      {
        if body[next] == "," {
          current.append(",")
          index = body.index(after: next)
          continue
        }
        if body[next] == "{" {
          depth += 1
          current.append("#{")
          index = body.index(after: next)
          continue
        }
      }
      if ch == "}" && depth > 0 {
        depth -= 1
        current.append("}")
        index = body.index(after: index)
        continue
      }
      if ch == "," && depth == 0 {
        args.append(current)
        current = ""
        index = body.index(after: index)
        continue
      }
      current.append(ch)
      index = body.index(after: index)
    }
    args.append(current)
    return args
  }

  /// Re-serialize tokens to the marker-bearing string form (the transitional
  /// region-bucket representation). Text is emitted verbatim — matching the
  /// historical single-unescape behaviour of the string pipeline.
  static func serialize(_ tokens: [Token]) -> String {
    var out = ""
    for token in tokens {
      switch token {
      case .text(let text): out += text
      case .marker(let parts): out += "#[\(parts.joined(separator: " "))]"
      case .variable(let body): out += "#{\(body)}"
      case .alias(let ch): out += "#\(ch)"
      }
    }
    return out
  }

  /// Count of visible characters across the token list — markers are
  /// zero-width.
  static func visibleCount(_ tokens: [Token]) -> Int {
    tokens.reduce(0) { count, token in
      if case .text(let text) = token { return count + text.count }
      return count
    }
  }

  /// Truncate the token list to `limit` visible characters, keeping EVERY
  /// marker regardless of which side of the cut it falls on — dropping
  /// trailing markers is how the old character-walk lost `#[nocyc]` /
  /// `#[nolink]` and silently killed the cycle slide / bled links.
  static func truncate(
    _ tokens: [Token],
    limit: Int,
    fromTail: Bool,
    ellipsis: Bool,
    marker: String? = nil
  ) -> [Token] {
    let visible = visibleCount(tokens)
    guard visible > limit else { return tokens }
    // Reserve one cell for the glyph so the trimmed run is exactly `limit`
    // visible characters wide.
    let keep = ellipsis ? max(0, limit - 1) : limit
    let ordered = fromTail ? Array(tokens.reversed()) : tokens
    var kept: [Token] = []
    var seen = 0
    for token in ordered {
      guard case .text(let text) = token else {
        kept.append(token)
        continue
      }
      if seen >= keep { continue }
      let budget = keep - seen
      let slice = fromTail ? String(text.suffix(budget)) : String(text.prefix(budget))
      seen += slice.count
      if !slice.isEmpty { kept.append(.text(slice)) }
    }
    if fromTail { kept.reverse() }
    // tmux's `#{=/N/marker:…}` form: the marker sits flush against the kept
    // text (inside its style context), does NOT count toward the width, and
    // keeps adjacent whitespace (tmux doesn't trim).
    if let marker, !marker.isEmpty {
      if fromTail {
        if let index = kept.firstIndex(where: { if case .text = $0 { return true }; return false }),
          case .text(let text) = kept[index]
        {
          kept[index] = .text(marker + text)
        } else {
          kept.insert(.text(marker), at: 0)
        }
      } else {
        if let index = kept.lastIndex(where: { if case .text = $0 { return true }; return false }),
          case .text(let text) = kept[index]
        {
          kept[index] = .text(text + marker)
        } else {
          kept.append(.text(marker))
        }
      }
      return kept
    }
    guard ellipsis else { return kept }
    // The glyph sits flush against the text: drop whitespace adjacent to it
    // so a truncation that lands on a space doesn't render "foo …".
    let glyph = FlashStatusBarTemplateEngine.truncationEllipsis
    if fromTail {
      if let index = kept.firstIndex(where: { if case .text = $0 { return true }; return false }),
        case .text(var text) = kept[index]
      {
        while let first = text.first, first.isWhitespace { text.removeFirst() }
        kept[index] = .text(glyph + text)
      } else {
        kept.insert(.text(glyph), at: 0)
      }
    } else {
      if let index = kept.lastIndex(where: { if case .text = $0 { return true }; return false }),
        case .text(var text) = kept[index]
      {
        while let last = text.last, last.isWhitespace { text.removeLast() }
        kept[index] = .text(text + glyph)
      } else {
        kept.append(.text(glyph))
      }
    }
    return kept
  }
}

extension FlashStatusTextColor {
  /// Parse a tmux colour word: `colourNNN`/`colorNNN` (full xterm-256
  /// palette), `#RRGGBB` hex, the ANSI colour names, or `default`.
  /// Unknown words fall back to the default foreground — matching tmux,
  /// which ignores styles it can't parse rather than erroring the line.
  static func parse(_ raw: String) -> FlashStatusTextColor {
    let word = raw.lowercased()
    if word == "default" { return .defaultForeground }
    for prefix in ["colour", "color"] where word.hasPrefix(prefix) {
      if let n = UInt8(word.dropFirst(prefix.count)) { return .palette(n) }
      return .defaultForeground
    }
    if word.hasPrefix("#"), word.count == 7,
      let value = UInt32(word.dropFirst(), radix: 16)
    {
      return .rgb(value)
    }
    switch word {
    case "black": return .palette(0)
    case "red": return .palette(196)  // historical Flash mapping (tmuxRed196)
    case "green": return .palette(2)
    case "yellow": return .palette(3)
    case "blue": return .palette(4)
    case "magenta": return .palette(5)
    case "cyan": return .palette(6)
    case "white": return .palette(7)
    case "brightblack": return .palette(8)
    case "brightred": return .palette(9)
    case "brightgreen": return .palette(10)
    case "brightyellow": return .palette(11)
    case "brightblue": return .palette(12)
    case "brightmagenta": return .palette(13)
    case "brightcyan": return .palette(14)
    case "brightwhite": return .palette(15)
    default: return .defaultForeground
    }
  }

  /// The xterm-256 palette, computed. Four values keep their historical
  /// Nord-theme overrides (the bar's look predates the full palette and the
  /// live templates depend on those exact shades): colour0 → polar night,
  /// colour178 → aurora yellow, colour196 → pure red, colour245 → grey.
  static func nsColor(_ color: FlashStatusTextColor) -> NSColor {
    switch color {
    case .defaultForeground:
      return OverlayPanel.tmuxGrey245
    case .defaultBackground:
      return OverlayPanel.nordPolarNight0
    case .rgb(let value):
      return NSColor(
        calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1)
    case .palette(let n):
      switch n {
      case 0: return OverlayPanel.nordPolarNight0
      case 178: return OverlayPanel.nordAuroraYellow
      case 196: return OverlayPanel.tmuxRed196
      case 245: return OverlayPanel.tmuxGrey245
      default: return Self.xterm(n)
      }
    }
  }

  /// Plain xterm-256: 16 ANSI entries, a 6×6×6 colour cube, 24 greys.
  static func xterm(_ n: UInt8) -> NSColor {
    let index = Int(n)
    if index < 16 {
      // Standard + bright ANSI (xterm defaults).
      let table: [(CGFloat, CGFloat, CGFloat)] = [
        (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
        (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
        (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
        (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
      ]
      let (r, g, b) = table[index]
      return NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }
    if index < 232 {
      let cube = index - 16
      let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
      let r = steps[cube / 36]
      let g = steps[(cube / 6) % 6]
      let b = steps[cube % 6]
      return NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }
    let grey = CGFloat(8 + (index - 232) * 10)
    return NSColor(calibratedWhite: grey / 255, alpha: 1)
  }
}
