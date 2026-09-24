import Foundation

/// The `flash.toml` Flash writes when the user has none: one working hint
/// shortcut plus commented suggestions. It lives in the user's file rather than
/// in `config.default.toml`: a starter is the user's to edit or delete, while
/// a bundled default would take an explicit `"<key>" = false` to remove.
enum StarterConfig {
  static let text = """
    # Flash configuration. Flash created this starter because you had no config
    # and never rewrites it, so edit freely. Changes apply as soon as you save.
    # Every option, with its default and documentation:
    # https://github.com/aymericbeaumet/flash/blob/main/config.default.toml

    [mode.all.mappings]
    # Label every clickable control in the focused app, then type a label to
    # click it (Escape cancels).
    "cmd+shift+space" = ["flash", "mouse_target"]

    # More shortcuts: delete the leading "# " to enable one.
    #
    # Reach any screen position with a grid laid out like the left half of
    # your keyboard (12345 / qwert / asdfg / zxcvb): press the key where you
    # want to go, then again to refine.
    # "cmd+shift+alt+space" = ["flash", "mouse_grid"]
    #
    # Search apps, browser tabs, emoji and more (keep the space after flashlight):
    # "cmd+ctrl+alt+space" = ["flash", "enter_command_mode", "--input=:flashlight "]
    #
    # Vim-like normal mode. While it is on, unmapped keys are captured instead of
    # typed until you press cmd+ctrl+i or click into a text field.
    # "cmd+ctrl+[" = ["flash", "enter_normal_mode"]
    # "cmd+ctrl+i" = ["flash", "enter_insert_mode"]

    """

  /// Whether to write the starter. Never when `FLASH_CONFIG` is present, even
  /// empty: it names a file its caller (a test, a harness) owns. Never over an
  /// existing file, even an empty one: that file is the user's.
  static func shouldSeed(environment: [String: String], configExists: Bool) -> Bool {
    environment["FLASH_CONFIG"] == nil && !configExists
  }

  /// Writes the starter where `ConfigLoader` reads the user config, creating
  /// its directory. Returns the written file, or nil when nothing was written.
  @discardableResult
  static func seedIfNeeded(environment: [String: String]) -> URL? {
    seedIfNeeded(at: ConfigLoader.resolvePath(environment: environment), environment: environment)
  }

  /// The same at an explicit path, so tests can use a temporary one.
  static func seedIfNeeded(at url: URL, environment: [String: String]) -> URL? {
    let fileManager = FileManager.default
    guard
      shouldSeed(
        environment: environment, configExists: fileManager.fileExists(atPath: url.path))
    else { return nil }
    do {
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      // Exclusive create: a file (or dangling symlink) that appeared after the
      // check is left alone rather than replaced.
      try Data(text.utf8).write(to: url, options: .withoutOverwriting)
    } catch {
      FlashLog.warn("[config] starter_failed path=\(url.path) error=\(error.localizedDescription)")
      return nil
    }
    FlashLog.info("[config] starter_created path=\(url.path)")
    return url
  }
}
