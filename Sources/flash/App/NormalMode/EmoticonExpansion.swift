import Foundation

/// ASCII-emoticon → emoji-shortcode rewriting for the flashlight query.
///
/// `normalizedSearchText` keeps only alphanumerics (plus `#`), so a literal
/// `:)` collapses to the empty string and can never fuzzy-match a candidate —
/// `@emojis.glyphs :)` would return the whole emoji set unranked. We rewrite
/// each standalone emoticon token to a word the `emojis` plugin actually
/// indexes (a Slack-style shortcode alias or the glyph's UCD name) *before*
/// normalization, so `@emojis.glyphs :)` surfaces 🙂, `:D` surfaces 😀, and so
/// on. The plugin owns the glyph/shortcode data; this table owns the
/// punctuation→word bridge that the normalizer would otherwise discard.
extension NormalModeDispatcher {
  /// Lowercased emoticon → expansion. Keys are stored lowercased so case
  /// variants collapse to one entry (`:D`/`:d`, `XD`/`xd`, `B)`/`b)`).
  /// Expansions use `_`-joined shortcodes (the normalizer turns `_` into a
  /// word break) and resolve to a single, unambiguous glyph via the emoji
  /// candidate's alias tier or its exact UCD-name title.
  static let emoticonShortcodes: [String: String] = [
    // Smiling
    ":)": "slightly_smiling_face", ":-)": "slightly_smiling_face",
    "(:": "slightly_smiling_face", "=)": "slightly_smiling_face",
    "=-)": "slightly_smiling_face",
    "^^": "smile", "^_^": "smile", "^-^": "smile",
    // Grinning / laughing
    ":d": "grinning", ":-d": "grinning", "=d": "grinning", "=-d": "grinning",
    "xd": "laughing", "x-d": "laughing",
    // Tears of joy
    ":')": "joy", ":'-)": "joy", ":'d": "joy",
    // Frowning / sad
    ":(": "slightly_frowning_face", ":-(": "slightly_frowning_face",
    "):": "slightly_frowning_face", ")-:": "slightly_frowning_face",
    "=(": "slightly_frowning_face", "=-(": "slightly_frowning_face",
    // Crying
    ":'(": "cry", ":'-(": "cry", ";(": "cry",
    // Winking
    ";)": "wink", ";-)": "wink",
    // Tongue
    ":p": "tongue", ":-p": "tongue", "=p": "tongue", "=-p": "tongue", "xp": "tongue",
    ";p": "stuck_out_tongue_winking_eye", ";-p": "stuck_out_tongue_winking_eye",
    // Surprise
    ":o": "open_mouth", ":-o": "open_mouth", "=o": "open_mouth",
    // Cool
    "b)": "sunglasses", "b-)": "sunglasses", "8)": "sunglasses", "8-)": "sunglasses",
    // Kiss
    ":*": "kiss", ":-*": "kiss", ";*": "kiss",
    // Confused / unsure
    ":/": "confused", ":-/": "confused", ":\\": "confused", ":-\\": "confused",
    // Neutral
    ":|": "neutral_face", ":-|": "neutral_face",
    // Angry
    ">:(": "angry", ">:-(": "angry", ":@": "angry",
    // Hearts
    "<3": "heart", "</3": "broken_heart", "<\\3": "broken_heart",
  ]

  /// Rewrite any standalone emoticon token in a flashlight query to its emoji
  /// shortcode. Whitespace-delimited tokens that aren't known emoticons pass
  /// through untouched — when nothing matches the original string (and its
  /// spacing) is returned verbatim, so ordinary queries are unaffected. Runs
  /// once per keystroke, so the token scan is well below the frame budget.
  static func expandEmoticons(_ text: String) -> String {
    var changed = false
    let rewritten = text.split(whereSeparator: { $0.isWhitespace }).map { token -> String in
      if let expansion = emoticonShortcodes[token.lowercased()] {
        changed = true
        return expansion
      }
      return String(token)
    }
    guard changed else { return text }
    return rewritten.joined(separator: " ")
  }
}
