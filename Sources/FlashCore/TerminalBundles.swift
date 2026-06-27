import Foundation

/// Known terminal-emulator bundle identifiers. Used by the source
/// registry's `.terminalBundles` activation filter and by `AppDelegate`'s
/// terminal-aware mode handling. Lives in `FlashCore` so both can
/// reference the same set without depending on a specific provider.
public enum TerminalBundles {
  public static let identifiers: Set<String> = [
    "org.alacritty",
    "io.alacritty",
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    "dev.warp.Warp-Stable",
    "co.zeit.hyperterm",
    "co.zeit.hyper",
  ]
}
