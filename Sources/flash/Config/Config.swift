import Foundation

struct Config {
  struct Hints {
    var keys: String = "<qwerty>"
    var minLength: Int = 1
  }
  struct Overlay {
    var fontSize: Double = 12
    var hintFG: String = "#302505"
    /// Top stop of the chip's vertical gradient. Vimium's default light
    /// yellow. Set this equal to `hintBGBottom` for a flat fill.
    var hintBGTop: String = "#FFF785"
    /// Bottom stop of the chip's vertical gradient.
    var hintBGBottom: String = "#FFC542"
    /// 1px border around the chip.
    var hintBorder: String = "#E3BE23"
  }
  struct Debug {
    /// When true, every detected target is outlined alongside its hint chip.
    /// Useful for diagnosing missing or misplaced hints — you can see exactly
    /// which AX rect Flash decided to use.
    var showBounds: Bool = false
    /// Fill for the debug outline rectangle. Default transparent.
    var boundsBG: String = "#00000000"
    /// Stroke for the debug outline rectangle. Mirrors the `hint_fg` slot:
    /// it's the foreground colour of the bounds shape.
    var boundsFG: String = "#FF3B9A"
    /// Emit a profiling trace for every activation and background
    /// precompute. Slow activations are still logged when this is false
    /// if `slowMs` is positive.
    var profile: Bool = false
    /// Log activation profiles whose end-to-end latency is at least this
    /// many milliseconds. Set to 0 to disable slow-activation logs.
    var slowMs: Int = 100
    /// When true, the AX walker writes one line per visited element
    /// (role, subrole, frame, parent role, actions, label) to
    /// `~/Library/Logs/Flash/ax-dump.log` on every activation. Used to
    /// diagnose missing or spurious hints in apps that fall through to
    /// the AX provider (Firefox web pages, Electron, etc.). Off by
    /// default — the dump is verbose and rotates per activation.
    var dumpAx: Bool = false
    /// When true, every diagnostic line that goes to stderr is also
    /// appended to `~/Library/Logs/Flash/flash.log`. Useful when
    /// running Flash via launchd (no terminal) but you still want to
    /// see profile traces and one-off warnings.
    var dumpLogs: Bool = false
    /// Minimum severity emitted by `FlashLog`. Messages below this
    /// level are dropped before any string interpolation runs.
    /// Defaults to `info` — set to `debug` while investigating an
    /// issue, or `warn` / `error` to mute the steady-state traces.
    var logLevel: FlashLog.Level = .info
  }

  var hints = Hints()
  var overlay = Overlay()
  var debug = Debug()
  /// `[shortcuts]` section. Each entry maps a hotkey string
  /// (e.g. `"cmd+ctrl+a"`) to one of:
  ///
  ///   - a single string, which is either a `flash://...` URL
  ///     (fast path — dispatched internally), any other URL or
  ///     file path (passed to `NSWorkspace.open`), or
  ///   - an array of strings, which is exec'd as `argv` (the
  ///     first element is the executable, the rest are args).
  ///
  /// `ShortcutsCoordinator` resolves each value into a typed
  /// `ShortcutAction` AOT at config-load. The hot path on a
  /// Carbon hotkey fire dispatches the already-resolved action.
  var shortcuts: [Shortcut] = []
  var warnings: [String] = []

  static let `default` = Config()

  var resolvedAlphabet: Alphabet.Resolved {
    Alphabet.resolve(hints.keys)
  }
}
