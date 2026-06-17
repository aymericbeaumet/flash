import Foundation

/// Parses the user-facing key-string syntax used in `flash.toml`
/// (`[mode.normal.mappings]`, `[mode.normal] leader`, etc.) into the
/// interpreter's internal token form.
///
/// Split out of NormalMode.swift; same public surface, no behaviour
/// change.
extension NormalModeInterpreter {
  /// Parse a user-facing key string into a sequence of internal-form
  /// atoms.
  ///
  /// **Syntax (single source of truth):**
  ///   - Letters/digits and any printable ASCII punctuation are
  ///     literal: `h`, `1`, `'`, `[`, `:`, `?`, `/`.
  ///   - The three syntactic markers `+`, `<`, `>` cannot appear
  ///     bare; use `<plus>`, `<less>`, `<greater>` instead.
  ///   - `<name>` accepts any of:
  ///       - a single bare-allowed character (`<a>` == `a`,
  ///         `<'>` == `'`);
  ///       - a punctuation fullname (`<colon>` == `:`,
  ///         `<lbracket>` == `[`, `<backslash>` == `\`);
  ///       - a named non-typeable key (`<tab>`, `<space>`,
  ///         `<escape>`, `<enter>`, `<delete>`, `<delete_forward>`,
  ///         `<up>`, `<down>`, `<left>`, `<right>`, `<home>`,
  ///         `<end>`, `<pageup>`, `<pagedown>`);
  ///       - `<leader>` (substituted later from `mode.normal.leader`).
  ///   - Modifier chords use `+`: `ctrl+i`, `cmd+shift+<lbracket>`,
  ///     `cmd+<delete>`. Modifier aliases: `cmd`/`command`,
  ///     `ctrl`/`control`, `shift`, `alt`/`opt`/`option`.
  ///   - Whitespace is stripped throughout so `ctrl+i <leader>c` and
  ///     `ctrl+i<leader>c` are equivalent.
  ///
  /// Returns nil for any malformed input. Each returned atom is the
  /// interpreter's internal token (single char, named key word, or
  /// "<leader>" placeholder).
  static func parseKeySequence(_ raw: String) -> [String]? {
    let stripped = String(raw.filter { !$0.isWhitespace })
    guard !stripped.isEmpty else { return nil }
    var atoms: [String] = []
    var idx = stripped.startIndex
    while idx < stripped.endIndex {
      if let chord = readModifierChord(stripped, from: &idx) {
        atoms.append(chord)
        continue
      }
      let ch = stripped[idx]
      if ch == "<" {
        guard let inner = readAngleBracketed(stripped, from: &idx),
          let translated = translateNamedKey(inner)
        else { return nil }
        atoms.append(translated)
        continue
      }
      if isBareKeyChar(ch) {
        atoms.append(String(ch))
        idx = stripped.index(after: idx)
        continue
      }
      return nil
    }
    return atoms
  }

  static let keyAtomSeparator: Character = "\u{1F}"

  static func encodeKeyAtoms(_ atoms: [String]) -> String {
    atoms.joined(separator: String(keyAtomSeparator))
  }

  static func keyAtoms(from sequence: String) -> [String] {
    sequence.split(separator: keyAtomSeparator, omittingEmptySubsequences: false)
      .map(String.init)
  }

  static func appendKeyAtom(_ prefix: String, _ atom: String) -> String {
    prefix.isEmpty ? atom : prefix + String(keyAtomSeparator) + atom
  }

  /// Canonicalize a mapping-key string into the interpreter's internal
  /// form. Multi-key sequences are separated by an untypeable atom
  /// delimiter so named keys like `<space>` do not contribute character
  /// prefixes (`<space>s` must not be a prefix of `<space><space>`).
  static func canonicalizeMappingKey(_ raw: String) -> String? {
    parseKeySequence(raw).map(encodeKeyAtoms)
  }

  /// Translate the configured leader value into the interpreter's
  /// internal token form. Must resolve to exactly one atom — leader
  /// is a single keystroke, never a chord/sequence.
  static func translateLeader(_ raw: String) -> String? {
    guard let atoms = parseKeySequence(raw), atoms.count == 1 else { return nil }
    let atom = atoms[0]
    return atom == "<leader>" ? nil : atom
  }

  /// True when `ch` may appear bare in mapping/leader syntax. Reserves
  /// the syntactic markers and rejects whitespace + non-printable.
  static func isBareKeyChar(_ ch: Character) -> Bool {
    if ch == "+" || ch == "<" || ch == ">" { return false }
    guard ch.isASCII, let code = ch.asciiValue else { return false }
    return code >= 0x21 && code <= 0x7E
  }

  /// Map an `<name>` payload to the interpreter's internal token.
  /// `leader` stays as the `<leader>` placeholder for late
  /// substitution. Single bare-allowed characters are a literal
  /// alias (so `<a>` is identical to bare `a`).
  static func translateNamedKey(_ name: String) -> String? {
    if name == "leader" { return "<leader>" }
    if name.count == 1, let ch = name.first, isBareKeyChar(ch) {
      return String(ch)
    }
    if let punct = punctuationCharacter(for: name) {
      return String(punct)
    }
    return Self.namedKeyAliases.contains(name) ? name : nil
  }

  /// Reverse of `translateNamedKey` for help-text formatting. Returns
  /// the user-facing fullname surrounded by `<>`, or nil for ordinary
  /// alphanumeric input.
  static func fullName(forCharacter ch: Character) -> String? {
    Self.punctuationFullNames[ch]
  }

  /// Punctuation chars accepted as `<fullname>` tokens. Lookup is by
  /// fullname so the canonicalizer can map `<lbracket>` → `[`.
  private static let punctuationFullNames: [Character: String] = [
    ":": "colon",
    ";": "semicolon",
    ",": "comma",
    ".": "period",
    "/": "slash",
    "?": "question",
    "!": "bang",
    "'": "apostrophe",
    "\"": "quote",
    "[": "lbracket",
    "]": "rbracket",
    "{": "lbrace",
    "}": "rbrace",
    "(": "lparen",
    ")": "rparen",
    "<": "less",
    ">": "greater",
    "-": "minus",
    "_": "underscore",
    "=": "equal",
    "+": "plus",
    "*": "asterisk",
    "&": "ampersand",
    "^": "caret",
    "%": "percent",
    "$": "dollar",
    "#": "hash",
    "@": "at",
    "~": "tilde",
    "`": "backtick",
    "\\": "backslash",
    "|": "pipe",
  ]

  private static func punctuationCharacter(for fullname: String) -> Character? {
    Self.punctuationFullNames.first { $0.value == fullname }?.key
  }

  /// Named keys other than punctuation that the interpreter or
  /// HotkeySyntax can route. Kept narrow: only the keys we actually
  /// emit or accept.
  private static let namedKeyAliases: Set<String> = [
    "tab", "space",
    "delete", "backspace",
    "delete_forward", "forward_delete",
    "return", "enter",
    "escape", "esc",
    "up", "down", "left", "right",
    "home", "end",
    "pageup", "pagedown",
  ]

  private static let modifierAliases: [(token: String, canonical: String)] = [
    ("command", "cmd"),
    ("control", "ctrl"),
    ("option", "alt"),
    ("opt", "alt"),
    ("cmd", "cmd"),
    ("ctrl", "ctrl"),
    ("shift", "shift"),
    ("alt", "alt"),
  ]

  private static func readModifierChord(_ s: String, from idx: inout String.Index) -> String? {
    var probe = idx
    var collected: [String] = []
    while probe < s.endIndex {
      let lower = s[probe...].lowercased()
      var matched: (String, String)?
      for (token, canonical) in modifierAliases {
        if lower.hasPrefix(token + "+") {
          matched = (token, canonical)
          break
        }
      }
      guard let (token, canonical) = matched else { break }
      collected.append(canonical)
      probe = s.index(probe, offsetBy: token.count + 1)
    }
    guard !collected.isEmpty else { return nil }
    guard probe < s.endIndex else { return nil }
    let key: String
    if s[probe] == "<" {
      var local = probe
      guard let inner = readAngleBracketed(s, from: &local),
        let translated = translateNamedKey(inner)
      else { return nil }
      key = translated
      probe = local
    } else if let named = readNamedKeyAlias(s, from: probe) {
      key = named.key
      probe = named.end
    } else if isBareKeyChar(s[probe]) {
      key = String(s[probe])
      probe = s.index(after: probe)
    } else {
      return nil
    }
    idx = probe
    let usesCmdOrAlt = collected.contains("cmd") || collected.contains("alt")
    if !usesCmdOrAlt, collected.count == 1, collected[0] == "ctrl",
      key.count == 1,
      let ch = key.first,
      ch.isASCII,
      ch.isLetter || ch.isNumber
    {
      return "ctrl-\(key)"
    }
    return (collected + [key]).joined(separator: "+")
  }

  private static func readNamedKeyAlias(
    _ s: String,
    from idx: String.Index
  ) -> (key: String, end: String.Index)? {
    let tail = s[idx...].lowercased()
    for alias in namedKeyAliases.sorted(by: { $0.count > $1.count }) where tail.hasPrefix(alias) {
      let end = s.index(idx, offsetBy: alias.count)
      return (translateNamedKey(alias) ?? alias, end)
    }
    for fullname in punctuationFullNames.values.sorted(by: { $0.count > $1.count })
      where tail.hasPrefix(fullname)
    {
      let end = s.index(idx, offsetBy: fullname.count)
      guard let translated = translateNamedKey(fullname) else { continue }
      return (translated, end)
    }
    return nil
  }

  private static func readAngleBracketed(_ s: String, from idx: inout String.Index) -> String? {
    precondition(s[idx] == "<")
    guard let end = s[s.index(after: idx)...].firstIndex(of: ">") else {
      return nil
    }
    let inner = String(s[s.index(after: idx)..<end])
    idx = s.index(after: end)
    return inner.isEmpty ? nil : inner
  }
}
