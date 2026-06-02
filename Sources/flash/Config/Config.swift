import Foundation

struct Config {
  enum Scope: String {
    /// Hint only the focused app's controls. Default — fastest, matches
    /// classic vimium semantics.
    case activeApp = "active_app"
    /// Hint every visible app with a window on the same monitor as the
    /// focused app's main window.
    case activeMonitor = "active_monitor"
    /// Hint every visible app on every monitor.
    case everywhere
  }

  struct Hints {
    var keys: String = "<qwerty>"
    var minLength: Int = 1
    var scope: Scope = .activeApp
  }
  struct Overlay {
    var fontSize: Double = 11
    var hintFG: String = "#302505"
    /// Top stop of the chip's vertical gradient. Vimium's default light
    /// yellow. Set this equal to `hintBGBottom` for a flat fill.
    var hintBGTop: String = "#FFF785"
    /// Bottom stop of the chip's vertical gradient.
    var hintBGBottom: String = "#FFC542"
    /// 1px border around the chip.
    var hintBorder: String = "#E3BE23"
    var exitKey: String = "escape"
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
  }

  var hints = Hints()
  var overlay = Overlay()
  var debug = Debug()
  var warnings: [String] = []

  static let `default` = Config()

  var resolvedAlphabet: Alphabet.Resolved {
    Alphabet.resolve(hints.keys)
  }

  /// Stable identity of the hint-generation inputs. Used as the alphabet
  /// component of the precompute cache key, so a config hot-reload that
  /// changes the alphabet, min-length, or scope invalidates labels but
  /// keeps the underlying target geometry valid through the next walk.
  var alphabetKey: String {
    "\(hints.keys)|\(hints.minLength)|\(hints.scope.rawValue)"
  }
}
