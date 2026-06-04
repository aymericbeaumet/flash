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
/// Only two forms are supported, by design:
///
/// - `flashCommand`: the value was a `flash://...` URL. Dispatched
///   in-process through the same handler `URLEventHandler` uses for
///   live AppleEvents — sub-millisecond, no shell, no Launch
///   Services. The intent is for users to prefer this form whenever
///   the action they want is expressible as a flash command (which
///   covers app activation, hint show/dismiss, quit).
///
/// - `shell`: the value was an argv array, exec'd directly via
///   `Process`. Use `["open", "https://example.com"]` to launch
///   URLs, `["open", "-a", "Foo"]` to launch an app the slow way,
///   `["sh", "-c", "..."]` for shell features. The cost is real
///   (process spawn + Launch Services) and visible in the config,
///   which is the point — the format encourages reaching for
///   `flash://` first.
enum ShortcutAction {
  case flashCommand(URLCommand)
  case shell([String])
}

/// Resolve a single string value into a `ShortcutAction`. The
/// string must be a `flash://...` URL; the scheme is mandatory so
/// every config line either *visibly* takes the fast path
/// (`"flash://…"`) or *visibly* takes the slow argv path
/// (`["open", …]`). Parsing is delegated to
/// `URLEventHandler.parseFlashURL` — the same parser the live
/// AppleEvent handler uses — so adding a new command happens in
/// exactly one place.
func parseShortcutAction(rawString s: String) -> ShortcutAction? {
  guard let cmd = URLEventHandler.parseFlashURL(s) else { return nil }
  return .flashCommand(cmd)
}

/// Resolve an array value into `.shell`. Empty arrays are rejected.
func parseShortcutAction(rawArray a: [String]) -> ShortcutAction? {
  a.isEmpty ? nil : .shell(a)
}
