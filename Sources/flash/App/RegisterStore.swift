import AppKit

/// Vim-style registers for the normal-mode `y` (yank) / `p` (paste) operators.
///
/// The *unnamed* register — used when the user yanks/pastes without a `"<name>`
/// prefix — is the system clipboard, so Flash integrates with copy/paste in
/// every other app out of the box. The synonyms `+`, `*`, and `"` name that
/// same clipboard explicitly (matching Vim's clipboard registers).
///
/// *Named* registers (`a`–`z`, `0`–`9`) are in-process buffers that survive
/// clipboard churn, so `"ay` … `"ap` round-trips text even if the user copied
/// something else in between. An uppercase name (`"Ay`) appends to the matching
/// lowercase register instead of overwriting it, again mirroring Vim.
final class RegisterStore {
  private var named: [Character: String] = [:]

  /// Whether `register` targets the system clipboard rather than a named
  /// in-process buffer. nil (no prefix typed) and the `+` / `*` / `"` synonyms
  /// all resolve to the clipboard.
  static func isSystemClipboard(_ register: String?) -> Bool {
    guard let register, let first = register.first else { return true }
    return first == "+" || first == "*" || first == "\""
  }

  /// Store `text` into `register`. Uppercase names append to the lowercase
  /// register; everything else overwrites.
  func write(_ text: String, register: String?) {
    if Self.isSystemClipboard(register) {
      NormalModeDispatcher.copy(text)
      return
    }
    guard let name = register?.first else { return }
    let key = Character(name.lowercased())
    if name.isUppercase {
      named[key, default: ""] += text
    } else {
      named[key] = text
    }
  }

  /// Read `register`'s contents, or nil when it's empty. Reading is
  /// case-insensitive: `"Ap` and `"ap` both read register `a`.
  func read(register: String?) -> String? {
    if Self.isSystemClipboard(register) {
      return NSPasteboard.general.string(forType: .string)
    }
    guard let name = register?.first else { return nil }
    return named[Character(name.lowercased())]
  }
}
