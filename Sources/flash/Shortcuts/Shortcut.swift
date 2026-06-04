import Foundation

/// One entry from `[shortcuts]` in flash.toml. The hotkey is the
/// LHS (TOML key); the action is the RHS resolved AOT at config
/// load by `parseShortcutAction(rawString:)` or
/// `parseShortcutAction(rawArray:)`.
struct Shortcut {
  let hotkey: String
  let action: ShortcutAction
}

/// What a hotkey fires. Resolved at config load — the Carbon
/// callback never re-parses a string.
///
/// `flashCommand` is the fast path: it runs entirely in-process
/// through the same handler `URLEventHandler` uses for live
/// `flash://...` AppleEvents. Everything else hands off to the
/// OS — `open`-equivalent for `openable` strings, `Process` for
/// `shell` argv arrays.
enum ShortcutAction {
  /// `flash://...` URL parsed into a `URLCommand`. Dispatched
  /// directly via the AppDelegate's URL handler — no `open`
  /// shell-out, no Launch Services round-trip.
  case flashCommand(URLCommand)
  /// Any other single-string value: an `http(s)://`, `file://`,
  /// or any other scheme NSWorkspace knows how to open. Also
  /// raw paths.
  case openable(URL)
  /// Array form. Exec'd directly via `Process` — no shell, no
  /// quoting hazards. Use `["sh", "-c", "..."]` if you need shell
  /// features (pipes, expansions, etc.).
  case shell([String])
}

/// Resolve a single string value into a `ShortcutAction`. Returns
/// nil when the string is neither a flash URL nor a parsable URL/
/// path.
func parseShortcutAction(rawString s: String) -> ShortcutAction? {
  let trimmed = s.trimmingCharacters(in: .whitespaces)
  guard !trimmed.isEmpty else { return nil }
  if trimmed.lowercased().hasPrefix("flash://") {
    guard let cmd = URLEventHandler.parseFlashURL(trimmed) else { return nil }
    return .flashCommand(cmd)
  }
  // Everything else delegates to NSWorkspace.open. `URL(string:)`
  // accepts the common cases (http/https/file URLs + bare absolute
  // paths). Bare app names like "Safari" return nil here — those
  // should use `flash://open_app?name=Safari` for the cached fast
  // path.
  if let url = URL(string: trimmed), url.scheme != nil {
    return .openable(url)
  }
  if trimmed.hasPrefix("/") {
    return .openable(URL(fileURLWithPath: trimmed))
  }
  return nil
}

/// Resolve an array value into a `ShortcutAction.shell`. Empty
/// arrays are rejected.
func parseShortcutAction(rawArray a: [String]) -> ShortcutAction? {
  a.isEmpty ? nil : .shell(a)
}
