import Foundation

enum StatusFormatAlignment: String, Equatable {
  case `default`, left, centre, right
  case absoluteCentre = "absolute-centre"
}

enum StatusFormatUnderline: String, Equatable {
  case single = "underscore"
  case double = "double-underscore"
  case curly = "curly-underscore"
  case dotted = "dotted-underscore"
  case dashed = "dashed-underscore"
  static let ordered: [Self] = [.single, .double, .curly, .dotted, .dashed]
  var bit: UInt8 { 1 << UInt8(Self.ordered.firstIndex(of: self)!) }
}

enum StatusFormatList: String, Equatable {
  case off, on, focus
  case leftMarker = "left-marker"
  case rightMarker = "right-marker"
}

struct StatusFormatRange: Equatable {
  enum Kind: String, Equatable { case left, right, control, pane, window, session, user }
  var kind: Kind
  var argument: String = ""
}

struct StatusFormatWidth: Equatable {
  var value: UInt32
  var percentage: Bool
}

/// Expanded formats become a document once, in output order. The same runs feed
/// bar drawing, hit testing and terminal document conversion.
struct StatusFormatDocument: Equatable {
  var runs: [FlashStatusTextSegment]

  static func parse(
    _ evaluation: StatusFormatEvaluation,
    defaultForeground: FlashStatusTextColor = .defaultForeground
  ) -> Self {
    let raw = evaluation.text
    var locations: [(range: Range<Int>, span: StatusFormatSpan)] = []
    var offset = 0
    for fragment in evaluation.fragments {
      locations.append((offset..<(offset + fragment.text.utf8.count), fragment.span))
      offset += fragment.text.utf8.count
    }
    var state = StatusFormatStyleState(defaultForeground: defaultForeground)
    var runs: [FlashStatusTextSegment] = []
    var inlineCounts: [String: Int] = [:]
    for piece in StatusFormatCells.pieces(raw) {
      let origin =
        locations.first(where: { $0.range.contains(piece.bytes.lowerBound) })?.span
        ?? StatusFormatSpan(origin: .init(), bytes: piece.bytes)
      if piece.style, !state.current.ignore {
        let body = String(piece.raw.dropFirst(2).dropLast())
        guard state.apply(body) else { continue }
        if let content = state.current.popupContent, !content.isEmpty,
          StatusFormatStyleState.tokens(body).contains(where: {
            $0.lowercased().hasPrefix("popup=inline:")
          })
        {
          let count = inlineCounts[origin.identity, default: 0]
          inlineCounts[origin.identity] = count + 1
          state.current.popup = "inline-" + stableID("\(origin.identity):\(count)")
        }
        var boundary = state.current
        boundary.origin = origin
        boundary.isStyleBoundary = true
        boundary.text = ""
        runs.append(boundary)
        continue
      }
      let text = state.current.ignore ? piece.raw : piece.text
      guard !text.isEmpty else { continue }
      var run = state.current
      run.text = text
      run.origin = origin
      if run.alternateCharacterSet { run.text = alternateCharacters(run.text) }
      if var last = runs.last {
        last.text = run.text
        if last == run {
          runs[runs.count - 1].text += run.text
          continue
        }
      }
      runs.append(run)
    }
    return Self(runs: runs)
  }

  static func parse(
    _ raw: String, origin: StatusFormatOrigin = .init(),
    defaultForeground: FlashStatusTextColor = .defaultForeground
  ) -> Self {
    parse(
      StatusFormatEvaluation(fragments: [
        .init(text: raw, span: .init(origin: origin, bytes: 0..<raw.utf8.count))
      ]), defaultForeground: defaultForeground)
  }

  func aligned(_ alignment: StatusFormatAlignment) -> [FlashStatusTextSegment] {
    runs.filter { $0.alignment == alignment || (alignment == .left && $0.alignment == .default) }
  }

  static func serialize(_ runs: [FlashStatusTextSegment]) -> String {
    runs.map { run in
      var style = [
        "default", "fg=\(run.foreground.markerValue)", "bg=\(run.background.markerValue)",
      ]
      for (name, enabled) in [
        ("bold", run.bold), ("italics", run.italics), ("dim", run.dim),
        ("reverse", run.reverse), ("blink", run.blink), ("breathing", run.breathing),
        ("hidden", run.hidden), ("overline", run.overline), ("strikethrough", run.strikethrough),
      ] where enabled {
        style.append(name)
      }
      if run.underline { style.append(run.underlineStyle.rawValue) }
      style.append(run.link.map { "link=\($0)" } ?? "nolink")
      style.append(run.range.map { "range=user|\($0)" } ?? "norange")
      if let popup = run.popupContent {
        let encoded = popup.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        style.append("popup=inline:\(encoded)")
      } else {
        style.append(run.popup.map { "popup=\($0)" } ?? "nopopup")
      }
      style.append(run.pill ? "pill" : "nopill")
      style.append(run.shrink ? "shrink" : "noshrink")
      style.append(run.cycle ? "cyc" : "nocyc")
      return "#[\(style.joined(separator: ","))]"
        + run.text.replacingOccurrences(of: "#", with: "##")
    }.joined()
  }

  static func stableID(_ source: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in source.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
    return String(hash, radix: 16)
  }

  private static func alternateCharacters(_ text: String) -> String {
    let mapping: [Character: Character] = [
      "j": "┘", "k": "┐", "l": "┌", "m": "└", "n": "┼", "q": "─", "t": "├",
      "u": "┤", "v": "┴", "w": "┬", "x": "│", "a": "▒", "f": "°", "g": "±",
      "~": "·", ",": "←", "+": "→", ".": "↓", "-": "↑", "0": "█",
    ]
    return String(text.map { mapping[$0] ?? $0 })
  }
}

extension FlashStatusTextColor {
  var markerValue: String {
    switch self {
    case .defaultForeground, .defaultBackground: return "default"
    case .palette(let index): return "colour\(index)"
    case .rgb(let rgb): return String(format: "#%06x", rgb)
    }
  }
}

struct StatusFormatStyleState {
  private var base: FlashStatusTextSegment
  private var currentDefault: FlashStatusTextSegment
  var current: FlashStatusTextSegment

  init(defaultForeground: FlashStatusTextColor = .defaultForeground) {
    let value = FlashStatusTextSegment(text: "", foreground: defaultForeground)
    base = value
    currentDefault = value
    current = value
  }

  static func tokens(_ body: String) -> [String] {
    body.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
  }

  /// A malformed style leaves the preceding style intact, including all tokens
  /// earlier in the same marker. A pushed default saves the pre-marker style.
  @discardableResult
  mutating func apply(_ body: String) -> Bool {
    let previous = current
    var candidate = current
    var defaultAction: String?
    for raw in Self.tokens(body) {
      let token = raw.lowercased()
      let extensionToken = token.hasPrefix("link=") || token.hasPrefix("popup=")
      guard extensionToken || raw.utf8.count <= 255 else { return false }
      if token == "default" {
        Self.copyAppearance(currentDefault, into: &candidate)
      } else if ["push-default", "pop-default", "set-default"].contains(token) {
        defaultAction = token
      } else if token == "none" {
        Self.clearAttributes(&candidate)
      } else if token == "noattr" {
        candidate.noAttributes = true
      } else if token == "ignore" {
        candidate.ignore = true
      } else if token == "noignore" {
        candidate.ignore = false
      } else if token == "noalign" {
        candidate.alignment = .default
      } else if token.hasPrefix("align=") {
        guard let value = StatusFormatAlignment(rawValue: String(token.dropFirst(6))),
          value != .default
        else { return false }
        candidate.alignment = value
      } else if token == "nolist" {
        candidate.list = .off
      } else if token.hasPrefix("list=") {
        guard let value = StatusFormatList(rawValue: String(token.dropFirst(5))), value != .off
        else { return false }
        candidate.list = value
      } else if token == "norange" {
        candidate.nativeRange = nil
        candidate.range = nil
      } else if token.hasPrefix("range=") {
        let parts = raw.dropFirst(6).split(
          separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count < 2 || !parts[1].isEmpty else { return false }
        // tmux accepts an unknown range kind without changing the current range.
        if StatusFormatRange.Kind(rawValue: parts[0].lowercased()) == nil { continue }
        guard let range = Self.range(String(raw.dropFirst(6))) else { return false }
        candidate.nativeRange = range
        candidate.range = range.kind == .user ? range.argument : nil
      } else if token.hasPrefix("fg=") || token.hasPrefix("bg=") || token.hasPrefix("us=") {
        let word = String(token.dropFirst(3))
        guard let color = FlashStatusTextColor.validated(word) else { return false }
        if token.hasPrefix("fg=") {
          candidate.foreground = word == "default" ? currentDefault.foreground : color
        }
        if token.hasPrefix("bg=") {
          candidate.background =
            word == "default"
            ? currentDefault.background : word == "terminal" ? .defaultBackground : color
        }
        if token.hasPrefix("us=") {
          candidate.underlineColor = word == "default" ? currentDefault.underlineColor : color
        }
      } else if token.hasPrefix("fill=") {
        let word = String(token.dropFirst(5))
        guard let color = FlashStatusTextColor.validated(word) else { return false }
        candidate.fill = word == "default" ? nil : word == "terminal" ? .defaultBackground : color
      } else if token.hasPrefix("width=") {
        let percent = token.hasSuffix("%")
        let word = String(token.dropFirst(6).dropLast(percent ? 1 : 0))
        guard let value = StatusFormatNumber.unsigned(word), !percent || value <= 100 else {
          return false
        }
        candidate.width = StatusFormatWidth(value: value, percentage: percent)
      } else if token.hasPrefix("pad=") {
        guard let value = StatusFormatNumber.unsigned(String(token.dropFirst(4))) else {
          return false
        }
        candidate.padding = Int(value)
      } else if token.hasPrefix("link=") {
        let value = String(raw.dropFirst(5))
        candidate.link = value.isEmpty ? nil : value
      } else if token == "nolink" {
        candidate.link = nil
      } else if token == "nopopup" {
        candidate.popup = nil
        candidate.popupContent = nil
      } else if token.hasPrefix("popup=") {
        let value = String(raw.dropFirst(6))
        if value.hasPrefix("inline:") {
          let encoded = String(value.dropFirst(7))
          guard !encoded.isEmpty, encoded.utf8.count <= 16_384,
            let content = encoded.removingPercentEncoding, !content.isEmpty
          else {
            FlashLog.debug(
              "Status inline popup rejected", fields: ["encoded_bytes": String(encoded.utf8.count)],
              source: "core:StatusFormatDocument.popup")
            return false
          }
          candidate.popup = "inline"
          candidate.popupContent = content
        } else {
          candidate.popup = value.isEmpty ? nil : value
          candidate.popupContent = nil
        }
      } else if token == "pill" {
        candidate.pill = true
      } else if token == "nopill" {
        candidate.pill = false
      } else if token == "shrink" {
        candidate.shrink = true
      } else if token == "noshrink" {
        candidate.shrink = false
      } else if token == "cyc" {
        candidate.cycle = true
      } else if token == "nocyc" {
        candidate.cycle = false
      } else {
        let enabled = !token.hasPrefix("no")
        let attributes = enabled ? token : String(token.dropFirst(2))
        if attributes == "none" || attributes == "default" { continue }
        guard attributes.first != "|", attributes.last != "|" else { return false }
        for attribute in attributes.split(separator: "|") {
          switch attribute {
          case "bright", "bold": candidate.bold = enabled
          case "dim": candidate.dim = enabled
          case "italics": candidate.italics = enabled
          case "reverse": candidate.reverse = enabled
          case "blink": candidate.blink = enabled
          case "hidden": candidate.hidden = enabled
          case "overline": candidate.overline = enabled
          case "strikethrough": candidate.strikethrough = enabled
          case "acs": candidate.alternateCharacterSet = enabled
          case "breathing": candidate.breathing = enabled
          default:
            guard let underline = StatusFormatUnderline(rawValue: String(attribute)) else {
              return false
            }
            if enabled {
              candidate.underlineMask |= underline.bit
            } else {
              candidate.underlineMask &= ~underline.bit
            }
          }
        }
      }
    }
    let cleared =
      previous.underlineMask & ~candidate.underlineMask != 0
      || (previous.bold && !candidate.bold) || (previous.dim && !candidate.dim)
      || (previous.italics && !candidate.italics) || (previous.reverse && !candidate.reverse)
      || (previous.blink && !candidate.blink) || (previous.hidden && !candidate.hidden)
      || (previous.overline && !candidate.overline)
      || (previous.strikethrough && !candidate.strikethrough)
      || (previous.alternateCharacterSet && !candidate.alternateCharacterSet)
    let underlineChanges =
      cleared ? candidate.underlineMask : candidate.underlineMask & ~previous.underlineMask
    if let underline = StatusFormatUnderline.ordered.first(where: { underlineChanges & $0.bit != 0 }
    ) {
      candidate.underlineStyle = underline
    }
    candidate.underline = candidate.underlineMask != 0
    current = candidate
    switch defaultAction {
    case "push-default": currentDefault = previous
    case "pop-default": currentDefault = base
    case "set-default":
      base = previous
      currentDefault = previous
    default: break
    }
    return true
  }

  private static func copyAppearance(
    _ source: FlashStatusTextSegment, into target: inout FlashStatusTextSegment
  ) {
    target.foreground = source.foreground
    target.background = source.background
    target.underlineColor = source.underlineColor
    target.bold = source.bold
    target.dim = source.dim
    target.italics = source.italics
    target.underline = source.underline
    target.underlineStyle = source.underlineStyle
    target.underlineMask = source.underlineMask
    target.noAttributes = source.noAttributes
    target.blink = source.blink
    target.reverse = source.reverse
    target.hidden = source.hidden
    target.overline = source.overline
    target.strikethrough = source.strikethrough
    target.alternateCharacterSet = source.alternateCharacterSet
    target.breathing = source.breathing
  }

  private static func clearAttributes(_ target: inout FlashStatusTextSegment) {
    target.bold = false
    target.dim = false
    target.italics = false
    target.underline = false
    target.blink = false
    target.reverse = false
    target.hidden = false
    target.overline = false
    target.strikethrough = false
    target.alternateCharacterSet = false
    target.breathing = false
    target.underlineMask = 0
    target.noAttributes = false
  }

  private static func range(_ raw: String) -> StatusFormatRange? {
    let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
    guard let first = parts.first, let kind = StatusFormatRange.Kind(rawValue: first.lowercased())
    else { return nil }
    if kind == .left || kind == .right { return parts.count == 1 ? .init(kind: kind) : nil }
    guard parts.count == 2 else { return nil }
    let argument = String(parts[1])
    if kind == .user {
      return .init(kind: kind, argument: String(decoding: argument.utf8.prefix(15), as: UTF8.self))
    }
    let prefix = kind == .pane ? "%" : kind == .session ? "$" : ""
    guard argument.hasPrefix(prefix),
      let value = StatusFormatNumber.unsigned(String(argument.dropFirst(prefix.count))),
      kind != .control || value <= 9
    else { return nil }
    return .init(kind: kind, argument: prefix + String(value))
  }
}
