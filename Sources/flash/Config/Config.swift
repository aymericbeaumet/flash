import FlashCore
import Foundation

struct PluginReference: Equatable {
  enum Kind: Equatable {
    /// GitHub-hosted plugin pinned to a full 40-character commit SHA. The pin
    /// is mandatory: third-party plugin code runs as the user with full
    /// host privileges, so a moving `main` would let a compromised plugin
    /// author (or anyone briefly controlling the repo) silently land new
    /// install/start scripts on every config reload.
    case github(owner: String, repository: String, commit: String)
    case file(path: String)
  }

  var raw: String
  var kind: Kind

  static func parse(_ raw: String, sourceURL: URL? = nil) -> PluginReference? {
    let trimmed = raw.trimmed
    if trimmed.hasPrefix("github:") {
      return parseGithub(trimmed)
    }
    if trimmed.hasPrefix("file:") {
      let rawPath = String(trimmed.dropFirst("file:".count))
        .trimmed
      guard !rawPath.isEmpty else { return nil }
      let expanded = (rawPath as NSString).expandingTildeInPath
      let resolved: String
      if expanded.hasPrefix("/") {
        resolved = expanded
      } else if let sourceURL {
        resolved =
          sourceURL.deletingLastPathComponent()
          .appendingPathComponent(expanded)
          .standardizedFileURL
          .path
      } else {
        resolved = expanded
      }
      return PluginReference(raw: trimmed, kind: .file(path: resolved))
    }
    return nil
  }

  /// Parses `github:owner/repo@<40-char-sha>`. Anything else is rejected with
  /// nil so the loader surfaces a clear diagnostic instead of silently pulling
  /// a moving branch.
  private static func parseGithub(_ trimmed: String) -> PluginReference? {
    let slug = String(trimmed.dropFirst("github:".count))
    let atSplit = slug.split(separator: "@", maxSplits: 1).map(String.init)
    guard atSplit.count == 2 else { return nil }
    let path = atSplit[0]
    let commit = atSplit[1].lowercased()
    let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2, isValidGithubComponent(parts[0]), isValidGithubComponent(parts[1]),
      isFullCommitSHA(commit)
    else { return nil }
    return PluginReference(
      raw: trimmed,
      kind: .github(owner: parts[0], repository: parts[1], commit: commit))
  }

  /// A GitHub owner / repo path component: non-empty, restricted to
  /// `[A-Za-z0-9._-]`, and never `.`/`..` or containing `..`. Without this an
  /// owner/repo of `..` would flow into the materialized cache path
  /// (`github/<owner>-<repository>-<sha>`) and the `git clone` URL; the fix
  /// closes the traversal footgun at the parse boundary.
  private static func isValidGithubComponent(_ s: String) -> Bool {
    guard !s.isEmpty, s != ".", s != "..", !s.contains("..") else { return false }
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    return s.unicodeScalars.allSatisfy { allowed.contains($0) }
  }

  /// Full 40-character lowercase hex commit SHA. Short SHAs are rejected: they
  /// have weaker collision resistance and don't pin against a future crafted
  /// commit landing in the upstream repository's object database.
  private static func isFullCommitSHA(_ value: String) -> Bool {
    guard value.count == 40 else { return false }
    return value.allSatisfy { $0.isHexDigit && (!$0.isLetter || $0.isLowercase) }
  }
}

struct ConfigLocation: Equatable {
  let line: Int
  let column: Int
}

/// The layer that wrote one resolved value. Missing means the bundled default
/// configuration, or the Swift built-in when that file leaves the key out.
/// `layer` is `config`, `env`, `cli`, or another writer; `detail` names the
/// file, variable, or flag.
struct ConfigValueSource: Equatable {
  var layer: String
  var detail: String
}

struct ConfigDiagnostic: Equatable {
  let message: String
  let location: ConfigLocation?
  /// The file whose value raised it, when one did: the user's config for
  /// its own entries, the bundled defaults for theirs. `flash config check`
  /// prints it as the `path` of `path:line:col`.
  var file: String? = nil

  var logMessage: String {
    guard let location else { return message }
    return "line \(location.line), col \(location.column): \(message)"
  }

  var alertLine: String { logMessage }
}

/// A single value inside a `[plugins.<id>]` settings table. Carries enough
/// type information to round-trip into JSON for the plugin's
/// `FLASH_PLUGIN_CONFIG`. Equatable so a config reload can detect when a
/// plugin's settings actually changed and restart only then.
enum PluginConfigValue: Equatable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case stringArray([String])

  var jsonValue: Any {
    switch self {
    case .string(let value): return value
    case .int(let value): return value
    case .double(let value): return value
    case .bool(let value): return value
    case .stringArray(let value): return value
    }
  }
}

/// `[overlay] hint_placement`: where a hint chip sits relative to its target
/// frame. The geometry is `HintPlacement.chipFrame`.
enum HintPlacement: String, CaseIterable, Equatable {
  /// On the target's top-left corner, centred on a target barely larger than
  /// the chip: the long-standing placement.
  case corner
  /// Centred on the target.
  case center
  /// Just above the target's top edge.
  case above
  /// Just below the target's bottom edge.
  case below
}

struct Config {
  struct App: Equatable {
    /// macOS menu-bar icon (see `StatusItemController.swift`, the single
    /// sanctioned status item) carrying About / Open Configuration / Quit.
    /// `[app] menu_bar_icon = false` hides it — Flash stays fully
    /// driveable through the CLI and mappings without it.
    var menuBarIcon: Bool = true
    /// Login-item registration through SMAppService, reconciled on every
    /// launch and config reload. `[app] autostart = false` unregisters.
    var autostart: Bool = true
    /// The layout keys are read against for hint labels, the grid and
    /// NORMAL (`KeyboardLayout.Setting`): "auto" reads them on the paired
    /// ASCII-capable layout while a non-Latin source is selected, an
    /// input-source ID always reads them on that layout.
    var keyboardLayout: String = "auto"
    /// What Flash does about new releases by itself (`UpdateMode`):
    /// `install`, `check` or `off`. See `UpdateController`.
    var updates: UpdateMode = .install
    /// Ask the window server to leave every Flash window out of
    /// screenshots, recordings and screen sharing (`NSWindow.sharingType =
    /// .none`, `CaptureSharing`). A request most capture on macOS 15 and
    /// later does not honour; see docs/privacy.md#screen-capture.
    var hideFromCapture = false
  }

  /// Logical key positions. Distinct from `app.keyboardLayout`, which only
  /// chooses the input source that reads a keypress.
  struct Keyboard: Equatable {
    /// `qwerty`, `colemak`, `dvorak`, or `bepo`. Hint selectors, the mouse
    /// grid, bisect, pointer movement and HYPER arrows follow it.
    var layout: String = "qwerty"
  }

  struct Clipboard: Equatable {
    var historySize: Int = 1_000
  }

  /// Which target gets the easiest label (`[hints] label_order`).
  enum LabelOrder: String, Equatable, CaseIterable {
    /// Reading order: top to bottom, left to right.
    case reading
    /// The target nearest the centre of the window (or screen) first.
    case center
    /// The first key of every label names the keyboard-shaped zone of the
    /// window the target sits in; the rest of the label is ergonomic.
    case zones
  }

  /// What the digits do in `--adjust` (`[hints] adjust_digits`).
  enum AdjustDigits: String, Equatable, CaseIterable {
    /// `1`–`9` place the point at n/10 of the target's width.
    case width
    /// A numeric-keypad grid: `7` `8` `9` across the top third, `4` `5` `6`
    /// the middle and `1` `2` `3` the bottom.
    case grid
  }

  /// Which apps share `mouse position`'s saved positions
  /// (`[hints] position_history_scope`).
  enum PositionScope: String, Equatable, CaseIterable {
    /// One list for every app.
    case global
    /// A list per app: a position saved in one never shows in another.
    case app
  }

  struct Hints: Equatable {
    var keys: String = Alphabet.defaultKeys
    var minLength: Int = 1
    var magicModifiers: [String] = ["cmd", "ctrl", "alt", "shift"]
    /// Keys that outrank the layout's ease, best first (`key_priority`).
    var keyPriority: String = ""
    var labelOrder: LabelOrder = .reading
    var adjustDigits: AdjustDigits = .width
    /// How many positions `mouse position` keeps (per app when scoped).
    var positionHistorySize: Int = 16
    var positionHistoryScope: PositionScope = .global
    /// A newly focused app brings the pointer to the centre of its window.
    var pointerFollowsFocus = false
    /// `mouse pointer` movement: points per keystroke at rest, added per
    /// autorepeat, and the ceiling.
    var pointerStep: Int = 12
    var pointerAcceleration: Int = 6
    var pointerMaxStep: Int = 90
    /// Number of selection steps for the `mouse grid` command. Larger values
    /// give finer precision but require more keystrokes per click.
    var mouseGridSteps: Int = 3
    /// The grid's key matrix, one string per keyboard row. Empty derives the
    /// left-hand block of the `keys` layout (`resolvedMouseGridKeys`).
    var mouseGridKeys: [String] = []
    /// Move the pointer to the grid region's centre after every step.
    var mouseGridCursorFollow = false
    /// Draw each cell's next step faintly inside it, labelled with the two
    /// keys that reach each of its cells, so the next key can be read ahead.
    var mouseGridPreview = true
    /// Put the pointer back where it was after a committed hint or grid
    /// click, drag or selection, and after `mouse repeat` (`--move` and
    /// `mouse pointer` still move it).
    var restorePointer = false
    /// Opacity (0.0..1.0) applied to every mouse-grid chip so the user
    /// can still see what's underneath the precision overlay. 1.0 is
    /// fully opaque, 0.0 invisible. Default 0.5 — the underlying window
    /// stays clearly visible through the precision grid.
    var mouseGridOpacity: Double = 0.5
  }
  struct Overlay: Equatable {
    var fontSize: Double = 12
    var hintFG: String = "#302505"
    /// Top stop of the chip's vertical gradient. Set this equal to
    /// `hintBGBottom` for a flat fill.
    var hintBGTop: String = "#FFF785"
    /// Bottom stop of the chip's vertical gradient.
    var hintBGBottom: String = "#FFC542"
    /// 1px border around the chip.
    var hintBorder: String = "#E3BE23"
    /// Foreground / gradient / border for hints whose target priority is
    /// `important` or `urgent` (tmux panes, browser tabs, …). Defaults to a
    /// red-ish Nord-aurora-red gradient so structural chips read as an accent
    /// against the regular yellow `f` chips. Set any field equal to its `hint*`
    /// counterpart to opt out of the distinction for that surface.
    var importantHintFG: String = "#ECEFF4"
    var importantHintBGTop: String = "#BF616A"
    var importantHintBGBottom: String = "#5C3940"
    var importantHintBorder: String = "#BF616A"
    /// Colored stroke around the focused app's frontmost window while
    /// advanced mode is on — green in normal, glowing blue in insert,
    /// purple in command — so the active window is always identifiable.
    /// `[overlay] window_border = false` turns it off entirely.
    var windowBorder: Bool = true
    /// Stroke width in points, applied to every mode. `0` (default) keeps
    /// the per-mode widths: 1 in normal/command, 2 in insert.
    var windowBorderSize: Double = 0
    /// Stroke color (`#RRGGBB` / `#RRGGBBAA`), applied to every mode.
    /// Empty (default) keeps the per-mode Nord colors.
    var windowBorderColor: String = ""
    /// Seconds an `alert show` toast stays up when the call passes no
    /// explicit --duration.
    var alertDuration: Double = 3.0
    /// Milliseconds a transient banner (command output, "Copied: …")
    /// stays up.
    var bannerDurationMs: Int = 700
    /// Where a hint chip sits relative to its target. Only the chip moves:
    /// the click aims at the same point whatever the placement.
    var hintPlacement: HintPlacement = .corner
    /// `[overlay.dark]`: chip colours drawn while the system appearance is
    /// dark. An empty value keeps its `[overlay]` counterpart.
    var dark = DarkHintColors()
    /// Draw a short ring where each committed click lands (demos,
    /// screencasts).
    var clickFeedback = false

    /// `[overlay.dark]`: the colour keys of `[overlay]`, each empty until set.
    struct DarkHintColors: Equatable {
      var hintFG = ""
      var hintBGTop = ""
      var hintBGBottom = ""
      var hintBorder = ""
      var importantHintFG = ""
      var importantHintBGTop = ""
      var importantHintBGBottom = ""
      var importantHintBorder = ""
    }

    /// The chip colours to draw with. Under a dark appearance every
    /// non-empty `[overlay.dark]` value replaces its `[overlay]`
    /// counterpart, one key at a time.
    func hintColors(dark isDark: Bool) -> HintColors {
      func pick(_ darkValue: String, _ lightValue: String) -> String {
        isDark && !darkValue.isEmpty ? darkValue : lightValue
      }
      return HintColors(
        fg: pick(dark.hintFG, hintFG),
        bgTop: pick(dark.hintBGTop, hintBGTop),
        bgBottom: pick(dark.hintBGBottom, hintBGBottom),
        border: pick(dark.hintBorder, hintBorder),
        importantFG: pick(dark.importantHintFG, importantHintFG),
        importantBGTop: pick(dark.importantHintBGTop, importantHintBGTop),
        importantBGBottom: pick(dark.importantHintBGBottom, importantHintBGBottom),
        importantBorder: pick(dark.importantHintBorder, importantHintBorder))
    }
  }

  /// One appearance's resolved chip colours, as hex strings.
  struct HintColors: Equatable {
    var fg: String
    var bgTop: String
    var bgBottom: String
    var border: String
    var importantFG: String
    var importantBGTop: String
    var importantBGBottom: String
    var importantBorder: String
  }
  /// Tunables for the `:flashlight` command-line surface.
  struct Flashlight: Equatable {
    /// Number of command-bar suggestions shown for `:flashlight`,
    /// `:emojis`, source filters, bangs, and command completions.
    var suggestionCount: Int = 10
    /// Half-life in days of the frecency decay — the sticky-vs-fresh dial.
    /// Applied when the store is (re)constructed on load/reload.
    var frecencyHalfLifeDays: Double = 14
    /// Cap on the frecency boost added to the ranker score; 0 disables
    /// frecency outright.
    var frecencyMaxBoost: Int = 600
    /// Per-keystroke deadline of the file search's Spotlight query
    /// (`@files`, `!f`), which then answers with the rows gathered so
    /// far. Live sources never join the first paint, so raising this cannot
    /// regress the flashlight open.
    var liveQueryTimeoutMs: Int = 1000
    /// Word-substitution aliases. The key is the exact whitespace-
    /// delimited token the user types (any leading sigil — `!`, `@`,
    /// or none — is part of the key, not implicit). The value is
    /// the literal expansion. When the user types `<key>` followed
    /// by whitespace the buffer is rewritten in place so downstream
    /// parsing (bang detection, source filters, fuzzy scoring) sees
    /// the canonical form. Empty by default — every pair is opt-in
    /// via `[flashlight.aliases]` in flash.toml.
    ///
    /// Example:
    /// ```toml
    /// [flashlight.aliases]
    /// "!g"  = "!google"
    /// "!gh" = "!github"
    /// "@ft" = "@tabs"
    /// ```
    var aliases: [String: String] = [:]
    /// A bang of the user's own, `[flashlight.bangs]`: `!<name> <query>`
    /// opens `url` with the query percent-encoded into each `{query}`; a URL
    /// without one is a quicklink, opened as written. `description` is what
    /// the `!` list shows under the trigger; empty shows the URL.
    struct Bang: Equatable {
      var url: String
      var description: String = ""
    }
    /// The user's bangs by name, one lowercase word of letters and digits.
    /// Empty by default. A name Flash's own `!f` and `!clip` or a bundled
    /// plugin's bang owns is rejected at load.
    var bangs: [String: Bang] = [:]
    /// Precedence override weights per resource type (`tabs` weighs every
    /// browser's tabs). Higher weight wins. Sources of an unlisted type
    /// derive their weight from the descriptor the native source or plugin
    /// manifest declares: location sources start at 50, standard sources at
    /// 0, plus the `sources[].priority` salience (`low` -20 … `important`
    /// +100).
    /// Precedence orders rows inside one match tier only: a row whose own
    /// name is what the user typed (exact, prefix, word, substring) always
    /// leads rows the query merely touches, whatever their sources weigh.
    ///
    /// Example:
    /// ```toml
    /// [flashlight.precedence]
    /// terminals = 200
    /// tabs      = 120
    /// ```
    var precedence: [String: Int] = [:]
    /// Bonus added to any candidate whose `pid != nil` so running
    /// processes outrank installed-but-not-running rows under the
    /// same source and match tier. With the `locations` source kind this
    /// gives active locations an effective weight of 60 vs. inactive 50
    /// before the source's own priority.
    var precedenceAliveBonus: Int = 10
    /// Apps, by name, bundle id or path, left out of the installed-app
    /// catalog and the `app open` command.
    var ignoredApps: [String] = []
    /// Directories scanned (recursively) and watched for `.app` bundles —
    /// the flashlight's installed-app catalog and the `app open` command's
    /// search roots. `~` expands to the user home. The defaults cover
    /// every standard macOS install location, including the Sequoia+ app
    /// cryptex where Safari really lives.
    var appDirectories: [String] = Flashlight.defaultAppDirectories

    static let defaultAppDirectories = [
      "/Applications",
      "/System/Applications",
      "/System/Applications/Utilities",
      "/System/Library/CoreServices",
      "/System/Cryptexes/App/System/Applications",
      "~/Applications",
    ]
  }
  struct Debug: Equatable {
    /// When true, every detected target is outlined alongside its hint chip.
    /// Useful for diagnosing missing or misplaced hints — you can see exactly
    /// which AX rect Flash decided to use.
    var showHintsBounds: Bool = false
    /// Fill for the debug outline rectangle. Default transparent.
    var hintsBoundsBG: String = "#00000000"
    /// Stroke for the debug outline rectangle. Mirrors the `hint_fg` slot:
    /// it's the foreground colour of the bounds shape.
    var hintsBoundsFG: String = "#FF3B9A"
    /// Minimum severity emitted by `FlashLog`. Messages below this
    /// level are dropped before any string interpolation runs.
    /// Defaults to `info` — set to `trace` while investigating a
    /// stuck-mode/input issue, `debug` for broader diagnostics, or
    /// `warn` / `error` / `fatal` to mute the steady-state traces.
    var logLevel: FlashLog.Level = .info
    /// When true, Flash binds a loopback-only HTTP server *at launch* that
    /// exposes live logs + resolved config + clipboard history for the
    /// inspector dashboard. Off by default (fail-safe): the dashboard-backed
    /// commands (`:logs`, `:plugins show`, `:commands`, `:help`, …) start the server
    /// on demand via `openDebugDashboard`, so they still work with this off —
    /// this flag only controls whether the server listens continuously from
    /// launch. Enable with `debug.http_inspector_enabled = true`.
    var httpInspectorEnabled: Bool = false
    /// Loopback hostname the inspector binds on. Restricted to
    /// `localhost` / `127.0.0.1` / `::1` (validated at start).
    var httpInspectorHost: String = "localhost"
    /// TCP port the inspector listens on.
    var httpInspectorPort: Int = 4242
  }
  /// `[telemetry.receiver]` and `[telemetry.exporter]`: OpenTelemetry in
  /// and out. Both are off by default.
  struct Telemetry: Equatable {
    /// The loopback OTLP/HTTP receiver whose metrics status formats read
    /// (`#{flash.otel:<metric>}`), and its in-memory retention.
    struct Receiver: Equatable {
      var enabled = false
      /// Bound on 127.0.0.1 only; 4318 is OTLP/HTTP's standard port.
      var port = 4318
      /// When set, a request must carry `Authorization: Bearer <token>`:
      /// every account and process shares the loopback address, and a
      /// received metric can drive a monitor whose `run` executes. Empty
      /// asks for none. Never shown, logged or exported.
      var token = ""
      var maxSeries = 1000
      var maxPoints = 60
      var maxLogs = 1000
      var maxSpans = 1000

      var limits: TelemetryStore.Limits {
        TelemetryStore.Limits(
          maxSeries: maxSeries, maxPoints: maxPoints, maxLogs: maxLogs, maxSpans: maxSpans)
      }
    }

    /// Flash's own telemetry, sent to an OTLP/HTTP endpoint.
    struct Exporter: Equatable {
      /// The OTLP/HTTP base URL; each signal posts to `<endpoint>/v1/<signal>`.
      /// Empty turns the exporter off.
      var endpoint = ""
      var encoding = OTLPEncoding.protobuf
      var gzip = false
      /// Sent with every request. Explicit values only, never logged or
      /// shown by the inspector.
      var headers: [String: String] = [:]
      var serviceName = "flash"
      var signals: Set<TelemetrySignal> = [.metrics, .traces]
      var intervalSeconds = 30
    }

    var receiver = Receiver()
    var exporter = Exporter()

    /// The endpoint the exporter sends to, or nil: empty, or Flash's own
    /// receiver (which would feed Flash's telemetry back into itself).
    var exportEndpoint: URL? {
      guard !exporter.endpoint.isEmpty, let url = URLParsing.url(exporter.endpoint),
        !Self.targetsReceiver(url, receiver: receiver)
      else { return nil }
      return url
    }

    /// Whether `url` is the loopback receiver's own address.
    static func targetsReceiver(_ url: URL, receiver: Receiver) -> Bool {
      guard receiver.enabled, let host = url.host?.lowercased() else { return false }
      let loopback =
        host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
        || host == "0.0.0.0"
      let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
      return loopback && port == receiver.port
    }
  }

  struct Plugins: Equatable {
    /// Third-party plugins explicitly requested by the user. Official
    /// bundled plugins are discovered from the app bundle, not this list.
    var thirdParty: [PluginReference] = []
    /// Plugin ids to keep unloaded. This applies to bundled and third-party
    /// plugins so users can opt out of the default plugin layer entirely.
    var disabled: Set<String> = []
    /// When true (the default), each plugin's directory tree is watched
    /// and any file change triggers a plugin reload. Set to false to
    /// disable hot-reload — useful if a plugin keeps a noisy log
    /// somewhere in its tree that would otherwise restart-loop it.
    var watchingEnabled: Bool = true
    /// Hard kill for a third-party plugin install script (a cold cargo
    /// build on a slow machine can legitimately take minutes).
    var installTimeoutSeconds: Int = 120
    /// `initialize` reply deadline. The reply must be immediate (warm
    /// catalogs publish after it), so this only needs to absorb interpreter
    /// startup — 5 s is the protocol default.
    var startupTimeoutSeconds: Int = 5
    /// Per-plugin user settings from `[plugins.<id>]` tables. Delivered to
    /// each plugin as a JSON object via `FLASH_PLUGIN_CONFIG`. Keyed by
    /// plugin id, then by setting name.
    var settings: [String: [String: PluginConfigValue]] = [:]
  }
  /// `[popup]`: the chrome every popup shares — hover previews, pinned
  /// popups and standalone popup windows alike.
  struct PopupStyle: Equatable {
    /// Default text colour. Inline `#[fg=…]` markers override it exactly as
    /// they do in the status bar.
    var foreground: String = "#D8DEE9"
    var background: String = "#2E3440"
    var borderColor: String = "#4C566A"
    var borderWidth: Double = 1
    var cornerRadius: Double = 8
    var padding: Double = 8
    /// Narrowest a text popup's pager gets, in points: 50 columns of the
    /// 13-point font with 10-point padding, room for the pager's prompt.
    var minWidth: Double = 480
    /// Widest a text popup's pager grows, in points: 80 columns, room for
    /// the three-month calendar.
    var maxWidth: Double = 750
    /// Gap between the status bar and a hover popup's top edge.
    var offset: Double = 8
  }

  /// A terminal popup's `size = "COLUMNSxROWS"`. Each side is a cell count or
  /// a percentage of the visible frame of the screen the popup shows on.
  struct PopupSize: Equatable, CustomStringConvertible {
    enum Side: Equatable {
      case cells(Int)
      /// A percentage of the screen, from 1 through 100. Fractions are kept,
      /// so `78.615%` is not truncated to 78%.
      case percent(Double)
    }

    var columns: Side
    var rows: Side

    /// The only place the default grid is written: `size = "100x28"`.
    static let `default` = PopupSize(columns: .cells(100), rows: .cells(28))

    init(columns: Side, rows: Side) {
      self.columns = columns
      self.rows = rows
    }

    /// `"120x36"`, `"90%x85%"` or a mix. Cells are whole counts from 1 to
    /// 1000. A percentage is 1% to 100% and may be fractional (`78.615%`).
    init?(_ raw: String) {
      let parts = raw.split(separator: "x", omittingEmptySubsequences: false)
      guard parts.count == 2, let columns = Self.side(parts[0]), let rows = Self.side(parts[1])
      else { return nil }
      self.init(columns: columns, rows: rows)
    }

    private static func side(_ raw: Substring) -> Side? {
      if raw.hasSuffix("%") {
        guard let value = percentValue(raw.dropLast()) else { return nil }
        return (1...100).contains(value) ? .percent(value) : nil
      }
      guard !raw.isEmpty, raw.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
        raw.count <= 4, let value = Int(raw), (1...1_000).contains(value)
      else { return nil }
      return .cells(value)
    }

    /// A percentage written with digits and at most one decimal point.
    /// `78.615` is in range; `10.5` without a `%` stays a cell count and is
    /// rejected by `side` because cells are whole.
    private static func percentValue(_ raw: Substring) -> Double? {
      guard !raw.isEmpty, raw.count <= 8, raw.first != ".", raw.last != "." else { return nil }
      var dots = 0
      for scalar in raw.unicodeScalars {
        if scalar == "." {
          dots += 1
          continue
        }
        guard (0x30...0x39).contains(scalar.value) else { return nil }
      }
      guard dots <= 1, let value = Double(raw), value.isFinite else { return nil }
      return value
    }

    var description: String {
      func text(_ side: Side) -> String {
        switch side {
        case .cells(let value): return String(value)
        case .percent(let value): return Self.percentText(value) + "%"
        }
      }
      return text(columns) + "x" + text(rows)
    }

    /// Whole percentages stay `90%`. A fraction keeps up to four decimal
    /// places, so `78.615%` round-trips and `90.0` does not appear.
    private static func percentText(_ value: Double) -> String {
      if value == value.rounded() { return String(Int(value)) }
      var text = String(format: "%.4f", value)
      while text.last == "0" { text.removeLast() }
      if text.last == "." { text.removeLast() }
      return text
    }

    /// The grid before the popup has a screen: cells as written, and a
    /// percentage side at the default grid's.
    var unplacedGrid: (columns: Int, rows: Int) {
      func cells(_ side: Side, fallback: Side) -> Int {
        if case .cells(let value) = side { return value }
        if case .cells(let value) = fallback { return value }
        return 1
      }
      return (
        cells(columns, fallback: Self.default.columns), cells(rows, fallback: Self.default.rows)
      )
    }

    /// Whether the grid follows the screen: a percentage on either side.
    var followsScreen: Bool {
      if case .percent = columns { return true }
      if case .percent = rows { return true }
      return false
    }

    /// The grid on a screen whose visible frame is `visible`. A percentage
    /// sizes the popup's outer frame, `inset` (padding plus border) on each
    /// edge included; `reservedHeight` is kept below the grid (an exit
    /// footer). Every side is clamped to what fits on the screen.
    func grid(
      visible: CGSize, cell: CGSize, inset: CGFloat, reservedHeight: CGFloat = 0
    ) -> (columns: Int, rows: Int) {
      func cells(_ side: Side, extent: CGFloat, cell: CGFloat, reserved: CGFloat) -> Int {
        let cell = max(1, cell)
        let fits = max(1, Int((extent - inset * 2 - reserved) / cell))
        switch side {
        case .cells(let value):
          return min(fits, value)
        case .percent(let value):
          let outer = extent * CGFloat(value) / 100
          return min(fits, max(1, Int((outer - inset * 2 - reserved) / cell)))
        }
      }
      return (
        cells(columns, extent: visible.width, cell: cell.width, reserved: 0),
        cells(rows, extent: visible.height, cell: cell.height, reserved: reservedHeight)
      )
    }
  }

  /// How a terminal popup's process lives. `persistent = true` selects
  /// `persistent`; the default is `fresh`.
  enum PopupLifecycle: Equatable {
    /// One long-lived process, started once the login environment resolves,
    /// kept while hidden and restarted with backoff when it exits.
    case persistent
    /// One process per showing: dismissal stops it, and a referenced popup
    /// keeps the next one started ahead.
    case fresh
  }

  /// A `[popup.<name>]` with `command`.
  struct Terminal: Equatable {
    var command: [String]
    var workingDirectory: String?
    var environment: [String: String] = [:]
    var size: PopupSize = .default
    var lifecycle: PopupLifecycle = .fresh
    /// `pause_hidden`: a persistent process is stopped (SIGSTOP) while the
    /// popup is hidden and continued (SIGCONT) when it shows, so it costs
    /// no CPU in the background; its first frame after showing is the one
    /// it drew before, until it redraws. Never set on a fresh popup.
    var pauseHidden: Bool = false

    /// The command reads the hovered span's `#[link]` (`$FLASH_STATUS_LINK`).
    /// A prewarmed process would start before any hover, so it is left to
    /// start when shown.
    var readsHoveredLink: Bool {
      command.contains { argument in
        argument.contains("$FLASH_STATUS_LINK") || argument.contains("${FLASH_STATUS_LINK}")
      }
    }
  }

  /// A `[popup.<name>]` table: exactly one of `text` or `command`.
  enum Popup: Equatable {
    /// `text`: a status format, shown through the terminal pager.
    case text(FlashStatusBarTemplate)
    /// `command`: a program in its own PTY.
    case terminal(Terminal)
  }

  struct StatusBar: Equatable {
    /// Which displays show the bar. `all` (default) puts it on every screen's
    /// top band; `primary` shows it only on the main (menu-bar) display.
    enum Monitor: String {
      case all
      case primary
    }

    /// Whether the persistent top status bar is shown. This is the *sole*
    /// condition for the bar's visibility — it is deliberately independent
    /// of advanced mode (the `mode normal` binding). Off by default;
    /// set `[statusbar] enabled = true` to opt in.
    var enabled: Bool = false
    /// Which monitors the bar renders on. `[statusbar] monitor = "primary"`
    /// limits it to the main display; `"all"` (default) covers every screen.
    var monitor: Monitor = .all
    /// Bar text size in points (the mode pill uses the same size).
    var fontSize: Double = 13
    /// Timeout for one named Flash source run;
    /// SIGTERM then SIGKILL past it, keeping the previous value.
    var commandTimeoutSeconds: Double = 6
    /// Points kept clear on each side of a notch (camera housing). 4pt: a 6pt
    /// margin overlaps the next cell by under a point on the 16-inch housing
    /// and the bar drops that whole glyph.
    var notchMargin: Double = 4
    /// Rows of `#{flash.top_cpu}` and `#{flash.top_mem}`, 1 through 20.
    var topCount: Int = ProcessStatusFormat.defaultTopCount
    /// Default cadence for named sources; zero runs only on initial load.
    var refreshIntervalSeconds: Double = 5
    /// URL schemes a `#[link]` may open beside `http`, `https` and `mailto`
    /// (`StatusLinkPolicy`): exact lowercase names, as authored. A link is
    /// text a plugin, a source or a program wrote, so nothing else opens.
    var linkSchemes: [String] = []
    /// One native tmux format, with Flash presentation styles and values.
    static let defaultTemplateString =
      "#[align=left]#[pill]#{flash.mode}#[nopill]#[align=right]#[fg=#EBCB8B]#{flash.date}"
    var template: FlashStatusBarTemplate = Self.defaultTemplate
    var sources: [String: FlashStatusBarSourceDefinition] = [:]
    var sourcesUsingDefaultInterval: Set<String> = []
    /// What a click on a `#[range=user|<name>]…#[norange]` span does —
    /// tmux's status-line mouse model: the span names an action, the
    /// binding lives outside the string. `[statusbar.click]` values are a
    /// URL string or a `["flash", "<topic>", "<action>", …]` action array.
    enum ClickAction: Equatable {
      case url(String)
      case command(MappingCommand)
    }
    var clickActions: [String: ClickAction] = Self.defaultClickActions
    /// The bundled sysinfo plugin wraps its battery chip in
    /// `#[range=user|bat-prefs]`, so the default map makes that span open
    /// the Battery pane out of the box.
    static let defaultClickActions: [String: ClickAction] = [
      "bat-prefs": .url("x-apple.systempreferences:com.apple.preference.battery")
    ]
    static let defaultTemplate = FlashStatusBarTemplate(
      template: Self.defaultTemplateString,
      variables: [
        FlashStatusBarTemplateVariable(
          id: "statusbar.template.mode",
          token: "flash.mode",
          source: .sdk(.modeLabel)),
        FlashStatusBarTemplateVariable(
          id: "statusbar.template.date",
          token: "flash.date",
          source: .sdk(.date)),
      ])

    /// The popups the enabled bar template's `#[popup=<name>]` markers open.
    var shownPopupNames: Set<String> {
      guard enabled else { return [] }
      return StatusFormatDocument.popupNames(in: template.template)
    }
  }

  /// A `[widgets.<name>]` table: one status format drawn as stacked lines in
  /// a click-through window on the desktop, below every app window.
  struct Widget: Equatable {
    enum Screen: Equatable {
      case primary
      case all
      /// 1-based, counting displays left to right.
      case index(Int)
    }

    enum Anchor: String, CaseIterable {
      case topLeft = "top_left"
      case topCentre = "top_centre"
      case topRight = "top_right"
      case centreLeft = "centre_left"
      case centre
      case centreRight = "centre_right"
      case bottomLeft = "bottom_left"
      case bottomCentre = "bottom_centre"
      case bottomRight = "bottom_right"
    }

    var enabled = true
    /// The compiled status format.
    var template = FlashStatusBarTemplate(template: "")
    var screen = Screen.primary
    var anchor = Anchor.topLeft
    /// Points from the anchored edges of the usable frame (the screen minus
    /// the Dock and the Flash bar band); ignored along a centred axis.
    var gapX: Double = 24
    var gapY: Double = 24
    /// Cell columns; 0 sizes the widget to its widest line, up to
    /// `maxColumns`.
    var columns = 0
    var maxColumns = 120
    /// A monospaced font name; empty uses the system monospaced font.
    var font = ""
    var fontSize: Double = 13
    var lineSpacing: Double = 0
    var foreground = "#D8DEE9"
    var background = "#2E344000"
    var border = "#00000000"
    var borderSize: Double = 0
    var cornerRadius: Double = 8
    var padding: Double = 8
    /// `#()` refresh cadence in seconds; 0 follows `[statusbar] interval`.
    /// Time shown refreshes on its own boundaries, not on this cadence.
    var intervalSeconds: Double = 0
    /// Ask the window server to leave the widget out of screen captures.
    var hideFromCapture = false

    var spec: StatusWidgetSpec {
      StatusWidgetSpec(
        template: template, intervalSeconds: intervalSeconds,
        columns: columns > 0 ? columns : maxColumns)
    }
  }

  /// `[startup]`: the commands Flash runs once each time it launches, after
  /// the configuration loads, and again on `startup run`. Editing them never
  /// runs them; see `StartupRunner`.
  struct Startup: Equatable {
    /// In order, each a Flash command or an executable, as a monitor's
    /// `run` takes them. Empty runs nothing.
    var run: [MappingCommand] = []
    /// Seconds each command may take before its process group is stopped.
    var timeoutSeconds = MonitorRunDefaults.timeoutSeconds
  }

  /// A `[monitors.<name>]` table, as authored: a status format read as a
  /// number, the thresholds it is judged against and the alert it raises.
  /// `monitorSpecs` compiles the enabled ones for the status controller.
  struct Monitor: Equatable {
    var enabled = true
    /// The status format whose expanded text must start with a number.
    var value = ""
    /// The alert's title, a status format; empty derives it from the name
    /// and the threshold crossed.
    var message = ""
    /// What is failing, a status format the alert shows under the title in
    /// place of the value; empty, or empty once expanded, shows the value.
    var detail = ""
    var warning: Double?
    var error: Double?
    var direction = MonitorDirection.above
    /// How often the monitor needs a fresh value, in seconds.
    var intervalSeconds: Double = 60
    /// Host events to watch instead of a value: the names and globs a
    /// plugin's `listen` takes (`core:system.woke`, `core:apps.*`).
    var event: [String] = []
    /// Narrows app events to one bundle identifier.
    var app = ""
    /// Narrows `core:usb.attached` and `core:usb.detached` to one device.
    var usb: USBDeviceFilter?
    /// The idle time, in seconds, `core:user.idle` and `core:user.active`
    /// match at; nil is `IdleWatch.defaultSeconds`.
    var idleSeconds: Int?
    /// The times of day `core:clock.minute` fires at; empty is never.
    var at: [ClockTime] = []
    /// The days `at` fires on; empty is every day.
    var days: [Weekday] = []
    /// What runs when it fires, in order: each a Flash command or an
    /// executable, as a mapping's value. Empty runs nothing.
    var run: [MappingCommand] = []
    /// Seconds the whole run may take; nil is `MonitorRunDefaults.timeoutSeconds`.
    var timeoutSeconds: Int?
    /// Seconds after a run starts before the next may; nil is none.
    var cooldownSeconds: Int?
    /// Whether a rise shows the centred alert.
    var alert = true
    /// Whether a rise, or a matching event, also posts a macOS notification.
    var notify = false

    var timeout: Int { timeoutSeconds ?? MonitorRunDefaults.timeoutSeconds }
    var cooldown: Int { cooldownSeconds ?? 0 }

    init(
      enabled: Bool = true, value: String = "", message: String = "", detail: String = "",
      warning: Double? = nil, error: Double? = nil, direction: MonitorDirection = .above,
      intervalSeconds: Double = 60
    ) {
      self.enabled = enabled
      self.value = value
      self.message = message
      self.detail = detail
      self.warning = warning
      self.error = error
      self.direction = direction
      self.intervalSeconds = intervalSeconds
    }

    /// Why the monitor cannot run once every layer is applied, or nil.
    var problem: String? {
      if run.isEmpty, timeoutSeconds != nil || cooldownSeconds != nil {
        return " has a timeout or a cooldown, which only a run has"
      }
      if idleSeconds != nil,
        !event.contains(where: { pattern in
          [HostEvent.userIdle, .userActive].contains { PluginPattern(pattern).matches($0.rawValue) }
        })
      {
        return ".idle times core:user.idle and core:user.active; it needs one of them in .event"
      }
      if !at.isEmpty || !days.isEmpty,
        !event.contains(where: { PluginPattern($0).matches(HostEvent.clockMinute.rawValue) })
      {
        return ".at and .days time core:clock.minute; it needs it in .event"
      }
      if usb != nil,
        !event.contains(where: { pattern in
          [HostEvent.usbAttached, .usbDetached].contains {
            PluginPattern(pattern).matches($0.rawValue)
          }
        })
      {
        return
          ".usb narrows core:usb.attached and core:usb.detached; it needs one of them in .event"
      }
      if !days.isEmpty, at.isEmpty { return ".days narrows .at; it needs an at" }
      if at.isEmpty, event.contains(HostEvent.clockMinute.rawValue) {
        return " listens to core:clock.minute, which needs .at times to fire at (\"09:55\")"
      }
      if !event.isEmpty {
        if !value.isEmpty { return " watches either a value or an event, not both" }
        if warning != nil || error != nil { return " has thresholds, which only a value has" }
        if let pattern = event.first(where: { pattern in
          !PluginProtocol.hostEvents.contains { PluginPattern(pattern).matches($0) }
        }) {
          return ".event \"\(pattern)\" matches no host event"
        }
        if run.isEmpty, message.isEmpty { return " needs a run or a message for its events" }
        if notify, message.isEmpty { return " notifies with its message, which is empty" }
        return nil
      }
      if !app.isEmpty { return ".app narrows events; it needs an event" }
      if value.isEmpty { return ".value or .event is required" }
      guard warning != nil || error != nil || !run.isEmpty else {
        return " needs a warning or an error threshold, or a run for when the value changes"
      }
      if notify, warning == nil, error == nil {
        return " notifies on a rise, which needs a warning or an error threshold"
      }
      if let warning, let error {
        switch direction {
        case .above where warning >= error:
          return ".warning must be below .error when direction is \"above\""
        case .below where warning <= error:
          return ".warning must be above .error when direction is \"below\""
        default: break
        }
      }
      return nil
    }

    func spec(name: String) -> StatusMonitorSpec {
      StatusMonitorSpec(
        enabled: enabled && problem == nil,
        origin: Config.defaultMonitors[name] == nil ? .config : .default,
        value: FlashStatusBarTemplate(
          template: value, origin: StatusFormatOrigin("monitors.\(name).value")),
        message: message.isEmpty
          ? nil
          : FlashStatusBarTemplate(
            template: message, origin: StatusFormatOrigin("monitors.\(name).message")),
        detail: detail.isEmpty
          ? nil
          : FlashStatusBarTemplate(
            template: detail, origin: StatusFormatOrigin("monitors.\(name).detail")),
        warning: warning, error: error, direction: direction, intervalSeconds: intervalSeconds,
        fires: run.isEmpty ? .never : (warning == nil && error == nil ? .onChange : .onRise),
        alerts: alert, notifies: notify)
    }

    /// The event monitor this table declares; nil for a value monitor.
    func eventSpec() -> EventMonitorSpec? {
      guard !event.isEmpty else { return nil }
      return EventMonitorSpec(
        patterns: event.map(PluginPattern.init), app: app.isEmpty ? nil : app, usb: usb,
        message: message.isEmpty ? nil : message, alerts: alert, notifies: notify,
        idleSeconds: idleSeconds ?? IdleWatch.defaultSeconds, clockTimes: Set(at),
        weekdays: Set(days))
    }
  }

  /// The built-in monitors, mirrored by `config.default.toml`. Each reads a
  /// value Flash already has: an event-driven plugin segment or a core value
  /// sampled only at the monitor's interval.
  static let defaultMonitors: [String: Monitor] = [
    "battery": Monitor(
      value: "#{flash.plugin.sysinfo.power_percent}%%", message: "Battery low", warning: 20,
      error: 10,
      direction: .below),
    "disk": Monitor(
      value: "#{flash.plugin.sysinfo.disks_percent}%%", message: "Startup disk almost full",
      warning: 90, error: 97),
    "memory": Monitor(
      value: "#{flash.memory_pressure}%%", message: "Memory pressure high", warning: 85,
      error: 95),
    "plugin_errors": Monitor(
      value: "#{flash.plugin.error_count}", message: "Failing plugins",
      detail: "#{flash.plugin.errors}", warning: 1),
    "plugin_spawn": Monitor(
      value: "#{flash.plugin.spawn_ms} ms", message: "Slow process launch",
      detail: "#{flash.plugin.spawn_id} #{flash.plugin.spawn_ms} ms", warning: 1000,
      error: 5000),
  ]

  /// Plugin id → the manifest status names the given templates read.
  static func statusSegments(in templates: [FlashStatusBarTemplate]) -> [String: Set<String>] {
    var segments: [String: Set<String>] = [:]
    for compiled in templates {
      for variable in compiled.variables {
        if case .plugin(.statusSegment(let pluginID, let name)) = variable.source {
          segments[pluginID, default: []].insert(name)
        }
      }
    }
    return segments
  }
  struct Mode: Equatable {
    struct AppMappings: Equatable {
      var all: [ModeMapping] = []
      var normal: [ModeMapping] = []
      var insert: [ModeMapping] = []
      var terminal: [ModeMapping] = []
      var command: [ModeMapping] = []
      var hyper: [ModeMapping] = []
      var hold: [ModeMapping] = []
      var text: [ModeMapping] = []
      var visual: [ModeMapping] = []
      var unmapped: [ModeScope: Set<String>] = [:]
      /// `[mode.apps."<bundle>".text] enabled`: whether NORMAL may engage a field in
      /// this app, over the plugins' `own_text_editing` declarations; nil
      /// leaves it to them (`TextScope.Policy`).
      var engagesText: Bool?

      func mappings(for scope: ModeScope) -> [ModeMapping] {
        switch scope {
        case .all: return all
        case .normal: return normal
        case .insert: return insert
        case .terminal: return terminal
        case .command: return command
        case .hyper: return hyper
        case .hold: return hold
        case .text: return text
        case .visual: return visual
        }
      }

      mutating func set(_ mapping: ModeMapping, in scope: ModeScope) {
        let sameKey: (ModeMapping) -> Bool = {
          $0.key == mapping.key
            || (mapping.nativeHotkey != nil && $0.nativeHotkey == mapping.nativeHotkey)
        }
        if let removed = unmapped[scope] {
          let remaining = removed.filter {
            $0 != mapping.key
              && (mapping.nativeHotkey == nil
                || ModeMapping.parseNativeHotkey($0) != mapping.nativeHotkey)
          }
          unmapped[scope] = remaining.isEmpty ? nil : remaining
        }
        switch scope {
        case .all:
          all.removeAll(where: sameKey)
          all.insert(mapping, at: 0)
        case .normal:
          normal.removeAll(where: sameKey)
          normal.insert(mapping, at: 0)
        case .insert:
          insert.removeAll(where: sameKey)
          insert.insert(mapping, at: 0)
        case .terminal:
          terminal.removeAll(where: sameKey)
          terminal.insert(mapping, at: 0)
        case .command:
          command.removeAll(where: sameKey)
          command.insert(mapping, at: 0)
        case .hyper:
          hyper.removeAll(where: sameKey)
          hyper.insert(mapping, at: 0)
        case .hold:
          hold.removeAll(where: sameKey)
          hold.insert(mapping, at: 0)
        case .text:
          text.removeAll(where: sameKey)
          text.insert(mapping, at: 0)
        case .visual:
          visual.removeAll(where: sameKey)
          visual.insert(mapping, at: 0)
        }
      }

      mutating func remove(_ key: String, in scope: ModeScope) {
        let chord = ModeMapping.parseNativeHotkey(key)
        let matches: (ModeMapping) -> Bool = {
          $0.key == key || (chord != nil && $0.nativeHotkey == chord)
        }
        unmapped[scope, default: []].insert(key)
        switch scope {
        case .all: all.removeAll(where: matches)
        case .normal: normal.removeAll(where: matches)
        case .insert: insert.removeAll(where: matches)
        case .terminal: terminal.removeAll(where: matches)
        case .command: command.removeAll(where: matches)
        case .hyper: hyper.removeAll(where: matches)
        case .hold: hold.removeAll(where: matches)
        case .text: text.removeAll(where: matches)
        case .visual: visual.removeAll(where: matches)
        }
      }
    }

    struct Labels: Equatable {
      var normal: String = "NORMAL"
      var insert: String = "INSERT"
      var command: String = "COMMAND"
      var terminal: String = "TERMINAL"
      var hyper: String = "HYPER"
      var hold: String = "HOLD"
      var visual: String = "VISUAL"
      var visualLine: String = "V-LINE"

      var longestCount: Int {
        max(
          normal.count, insert.count, command.count, terminal.count, hyper.count, hold.count,
          visual.count, visualLine.count)
      }
    }

    var all: [ModeMapping] = [
      ModeMapping(key: "cmd+ctrl+h", action: .flashCommand(.holdMode(.primary)))
    ]
    var normal: [ModeMapping] = Self.defaultNormalMappings
    var insert: [ModeMapping] = []
    var terminal: [ModeMapping] = Self.defaultTerminalMappings
    var command: [ModeMapping] = []
    /// Keys read while the NORMAL leader is held. Not merged with `[mode.all]`:
    /// a hyper binding replaces NORMAL for that key for the duration of the hold.
    var hyper: [ModeMapping] = Self.defaultHyperMappings
    /// Keys read before NORMAL in HOLD (a held button dragging). A key with
    /// no entry here is NORMAL's.
    var hold: [ModeMapping] = Self.defaultHoldMappings
    /// Keys read before NORMAL's while a field is engaged (`TextScope`):
    /// Vim's motions. A key with no entry here is NORMAL's.
    var text: [ModeMapping] = Self.defaultTextMappings
    /// VISUAL's own keys: its operators, read before the text table's
    /// motions. VISUAL reads nothing else but `[mode.all]`.
    var visual: [ModeMapping] = Self.defaultVisualMappings
    /// Exact focused-app bundle identifier to per-scope additions/removals.
    var appMappings: [String: AppMappings] = [:]

    /// `[mode.layers.<name>]`: a user-defined key table, entered by
    /// `mode layer --name=<name>` and left by Escape or `mode leave`.
    struct Layer: Equatable {
      /// The pill text; nil shows the name in capitals.
      var label: String?
      /// Stay after a mapping runs (the default); false leaves after one.
      var sticky = true
      /// The layer's own mappings, in file order.
      var mappings: [ModeMapping] = []
      /// Keys a `false` entry took out of what the layer inherits: an
      /// `[mode.all]` key, or `<escape>`'s implicit `mode leave`.
      var unmapped: Set<String> = []

      func removes(_ mapping: ModeMapping) -> Bool {
        if unmapped.contains(mapping.key) { return true }
        guard let chord = mapping.nativeHotkey else { return false }
        return unmapped.contains { ModeMapping.parseNativeHotkey($0) == chord }
      }

      mutating func set(_ mapping: ModeMapping) {
        unmapped = unmapped.filter {
          $0 != mapping.key
            && (mapping.nativeHotkey == nil
              || ModeMapping.parseNativeHotkey($0) != mapping.nativeHotkey)
        }
        mappings.removeAll { $0.key == mapping.key }
        mappings.append(mapping)
      }

      mutating func remove(_ key: String) {
        let chord = ModeMapping.parseNativeHotkey(key)
        unmapped.insert(key)
        mappings.removeAll { $0.key == key || (chord != nil && $0.nativeHotkey == chord) }
      }
    }

    /// The declared layers by name. Plugins and `[mode.apps]` add nothing
    /// here: a layer is the user's own table.
    var layers: [String: Layer] = [:]

    /// A layer name: lowercase letters, digits, `_` and `-`, at most 32.
    static func isValidLayerName(_ name: String) -> Bool {
      (1...32).contains(name.count)
        && name.unicodeScalars.allSatisfy {
          ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
    }

    /// Names a layer cannot take: Flash's own modes and mapping scopes.
    /// `flash resident status` reports a layer by name in the same `mode`
    /// field, so the two never read alike.
    static let reservedLayerNames: Set<String> = [
      "all", "command", "disabled", "hold", "hyper", "insert", "normal", "terminal", "text",
      "visual",
    ]

    /// Escape leaves every layer unless its table maps or removes
    /// `<escape>`.
    static let layerEscapeMapping = ModeMapping(
      key: NormalModeInterpreter.canonicalizeMappingKey("<escape>") ?? "escape",
      action: .flashCommand(.leaveMode))

    /// What a layer reads: its own entries, then Escape's `mode leave` and
    /// the all-mode ones it leaves alone. An unknown name (a layer a reload
    /// removed) still reads Escape, so it can always be left.
    func layerMappings(_ name: String) -> [ModeMapping] {
      let layer = layers[name] ?? Layer()
      let inherited = ([Self.layerEscapeMapping] + all).filter { !layer.removes($0) }
      return Self.resolveMappings(layer.mappings + inherited)
    }

    /// The pill text for a layer.
    func layerLabel(_ name: String) -> String {
      layers[name]?.label ?? name.uppercased()
    }

    /// Every layer's own mappings, by layer name.
    var layerMappingEntries: [ModeMapping] {
      layers.sorted { $0.key < $1.key }.flatMap(\.value.mappings)
    }

    /// Keys a `"<key>" = false` entry removed, per table, after every layer.
    /// A later layer mapping the key again takes it back out. Plugin
    /// mappings on these keys are dropped too (`EffectiveMappings.merge`).
    /// The text table starts without the NORMAL keys that would lose what was
    /// typed (`defaultTextUnmapped`).
    var unmapped: [ModeScope: Set<String>] = [
      .text: Mode.defaultTextUnmapped, .hold: Mode.defaultHoldUnmapped,
    ]

    /// NORMAL keys that do nothing in text: `r` / `R` reload the page, which
    /// loses what was typed in the field. `x` is not among them: the tab
    /// closes in a field too, as asked.
    static let defaultTextUnmapped: Set<String> = Set(
      ["r", "R"].compactMap(NormalModeInterpreter.canonicalizeMappingKey))

    /// NORMAL keys that do nothing while a button is held: `x` would close
    /// the tab under the drag.
    static let defaultHoldUnmapped: Set<String> = Set(
      ["x"].compactMap(NormalModeInterpreter.canonicalizeMappingKey))

    /// Whether a `false` entry in `scope` removed `mapping`'s key, compared
    /// by physical chord so `cmd+shift+]` also removes `cmd+shift+}`.
    func removes(_ mapping: ModeMapping, in scope: ModeScope) -> Bool {
      guard let keys = unmapped[scope], !keys.isEmpty else { return false }
      if keys.contains(mapping.key) { return true }
      guard let chord = mapping.nativeHotkey else { return false }
      return keys.contains { ModeMapping.parseNativeHotkey($0) == chord }
    }

    /// The proportional layouts `window move` mappings apply, in any scope.
    var declaredWindowLayouts: [WindowLayout] {
      var layouts: [WindowLayout] = []
      let appEntries = appMappings.sorted { $0.key < $1.key }.flatMap { entry in
        let app = entry.value
        return app.all + app.normal + app.insert + app.terminal + app.command + app.hyper
      }
      for mapping in all + normal + insert + terminal + command + hyper + appEntries
        + layerMappingEntries
      {
        guard case .flashCommand(.moveWindow(let params)) = mapping.action,
          case .proportional? = params.layout, let layout = params.layout,
          !layouts.contains(layout)
        else { continue }
        layouts.append(layout)
      }
      return layouts
    }
    var normalLeader: String? = Self.defaultNormalLeader
    var labels = Labels()
    /// How long the interpreter waits for the next key in a pending
    /// sequence before resolving the longest matching prefix.
    /// Vim's `timeoutlen`. Lower → faster commits, more two-key
    /// collisions; higher → slower commits, fewer surprises.
    var sequenceTimeoutMs: Int = Self.defaultSequenceTimeoutMs
    /// How long a NORMAL prefix (`g`, `]`, `<leader>`) waits before the
    /// which-key palette lists what can follow it; 0 never shows it.
    var whichKeyMs: Int = 500
    /// Pixels per horizontal h/l scroll step.
    var scrollStep: Int = 60
    /// Mouse-wheel lines per `scroll up` / `scroll down`: `j` / `k` where
    /// they scroll. `ctrl+e` / `ctrl+y` scroll one line (`scroll line_down`).
    var scrollStepLines: Int = 3
    /// Mouse-wheel lines per ctrl+d/ctrl+u scroll step.
    var scrollPageLines: Int = 20
    /// `[mode.text] enabled`: whether NORMAL engages a field at all. False
    /// leaves every field to the app (kindaVim, SketchyVim): `v` / `V` do
    /// nothing and the text table is never read (`TextScope.Policy`).
    var textEnabled = true
    /// Arrows per ctrl+d/ctrl+u half page where they move a caret or a
    /// selection (`move half_page_down`); ctrl+f/ctrl+b send twice as many.
    var movePageLines: Int = Self.defaultMovePageLines
    /// About half of a typical text or list view's visible rows (30): Vim's
    /// ctrl+d moves half a window, and a list overshot by too many arrows is
    /// harder to follow than one that needs a second press.
    static let defaultMovePageLines = 15
    /// Spread each vertical line scroll over this many milliseconds as
    /// several smaller line events (`SmoothScroll`); 0 posts it at once.
    var scrollSmoothMs: Int = 0
    /// Mouse-down→up hold on synthesized clicks; some apps need a
    /// non-zero press to register.
    var clickHoldMs: Int = 18
    /// Delay between chords of a multi-key `key sequence` — terminals and
    /// remote-desktop apps drop chords sent back-to-back.
    var sendKeyIntervalMs: Int = 35
    /// Matches Neovim's `timeoutlen` default so multi-key sequences feel the
    /// same as in the editor users already have muscle memory for.
    static let defaultSequenceTimeoutMs = 1000

    /// Single-atom key form, parsed via `NormalModeInterpreter.parseKeySequence`.
    /// Use `\` bare or `<backslash>` — both resolve to the same key.
    static let defaultNormalLeader = "\\"
    /// `mode.normal.hyper`, in mapping-key syntax. `"<leader>"` follows
    /// `normalLeader` and resolves to nothing when the leader is unset.
    static let defaultHyperKey = "<leader>"
    var hyperKey: String = Self.defaultHyperKey
    /// The physical key that enters HYPER, after `<leader>` substitution.
    /// Nil when `hyperKey` is `"<leader>"` and no leader is set.
    private(set) var resolvedHyperKey: String?
    /// `resolvedHyperKey` prepared for the per-key test: its chord and the
    /// characters that may spell it, parsed once here rather than per key.
    private(set) var resolvedHyperMatcher: HyperKeyMatcher?
    /// `normalLeader` in mapping-atom form, translated once per load.
    private(set) var resolvedLeaderAtom: String?

    static let defaultNormalMappings: [ModeMapping] = makeDefaultNormalMappings()

    /// Apple function row while HYPER is held: `1`–`9`, `0`, `-`, `=`.
    /// Shift plus the same key sends F1–F12.
    static let defaultHyperMappings: [ModeMapping] = {
      let bindings: [(String, URLCommand)] = [
        ("1", .systemKey(.brightnessDown)),
        ("2", .systemKey(.brightnessUp)),
        ("3", .systemSurface(SystemSurfaceCommand(.missionControl, .toggle))),
        ("4", .systemKey(.spotlight)),
        ("5", .systemKey(.dictation)),
        ("6", .systemKey(.focus)),
        ("7", .systemKey(.mediaPrevious)),
        ("8", .systemKey(.mediaPlay)),
        ("9", .systemKey(.mediaNext)),
        ("0", .systemKey(.mute)),
        ("-", .systemKey(.volumeDown)),
        ("=", .systemKey(.volumeUp)),
        ("shift+1", .functionKey(1)),
        ("shift+2", .functionKey(2)),
        ("shift+3", .functionKey(3)),
        ("shift+4", .functionKey(4)),
        ("shift+5", .functionKey(5)),
        ("shift+6", .functionKey(6)),
        ("shift+7", .functionKey(7)),
        ("shift+8", .functionKey(8)),
        ("shift+9", .functionKey(9)),
        ("shift+0", .functionKey(10)),
        ("shift+-", .functionKey(11)),
        ("shift+=", .functionKey(12)),
      ]
      return bindings.map { key, command in
        guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(key) else {
          preconditionFailure("invalid default hyper mapping: \(key)")
        }
        return ModeMapping(key: canonical, action: .flashCommand(command))
      }
    }()

    /// HOLD moves what the held button grabbed: `h` `j` `k` `l` nudge it,
    /// `H` `J` `K` `L` further, a picked target is where it goes, Return
    /// drops it and Escape puts it back. `y` copies a text selection and `p`
    /// pastes over it; nothing cuts, since Flash never edits text. The page
    /// keys scroll under the held button, as they always did in HOLD, so the
    /// selection follows them; NORMAL's `move` would send arrows in text.
    /// `cmd+ctrl+h` enters or leaves it.
    static let defaultHoldMappings: [ModeMapping] = makeDefaultMappings(
      "hold",
      [
        ("y", .selection(.copy)),
        ("p", .selection(.paste)),
        ("w", .mouseJump(.nextWord)),
        ("b", .mouseJump(.previousWord)),
        ("e", .mouseJump(.wordEnd)),
        ("0", .mouseJump(.lineStart)),
        ("$", .mouseJump(.lineEnd)),
        ("h", .mouseNudge(.left, distance: 16)),
        ("j", .mouseNudge(.down, distance: 16)),
        ("k", .mouseNudge(.up, distance: 16)),
        ("l", .mouseNudge(.right, distance: 16)),
        ("H", .mouseNudge(.left, distance: 96)),
        ("J", .mouseNudge(.down, distance: 96)),
        ("K", .mouseNudge(.up, distance: 96)),
        ("L", .mouseNudge(.right, distance: 96)),
        ("ctrl+d", .scroll(.halfPageDown)),
        ("ctrl+u", .scroll(.halfPageUp)),
        ("ctrl+f", .scroll(.pageDown)),
        ("ctrl+b", .scroll(.pageUp)),
        ("gg", .scroll(.top)),
        ("G", .scroll(.bottom)),
        ("f", .mouseTarget(.move)),
        ("F", .mouseGrid(.init(.move))),
        ("s", .mouseBigram(.move)),
        ("<return>", .mouseButton(.init(state: .release, button: .primary, hold: .hold))),
        ("<esc>", .mouseButton(.init(state: .cancel, button: .primary, hold: .hold))),
      ])

    /// NORMAL while a field is engaged (`TextScope`): Vim's motions, read
    /// before NORMAL's keys, which answer the rest; Escape disengages. `H`, `L` and `t`
    /// are Vim's here (screen lines, till) and keep their Flash meaning
    /// (history back and forward, a new tab) everywhere else; `f` and `F`
    /// stay the hints. `j` `k` `h` `l` and the page keys are NORMAL's
    /// `move`, which already moves the caret in text.
    static let defaultTextMappings: [ModeMapping] = makeDefaultMappings(
      "text",
      [
        ("w", .cursor(.motion(.nextWord(big: false)))),
        ("W", .cursor(.motion(.nextWord(big: true)))),
        ("b", .cursor(.motion(.previousWord(big: false)))),
        ("B", .cursor(.motion(.previousWord(big: true)))),
        ("e", .cursor(.motion(.wordEnd(big: false)))),
        ("E", .cursor(.motion(.wordEnd(big: true)))),
        ("ge", .cursor(.motion(.previousWordEnd(big: false)))),
        ("gE", .cursor(.motion(.previousWordEnd(big: true)))),
        ("0", .cursor(.motion(.lineStart))),
        ("^", .cursor(.motion(.firstNonBlank))),
        ("$", .cursor(.motion(.lineEnd))),
        ("g_", .cursor(.motion(.lastNonBlank))),
        ("|", .cursor(.motion(.column))),
        ("gg", .cursor(.motion(.firstLine))),
        ("G", .cursor(.motion(.lastLine))),
        ("%", .cursor(.motion(.matchingBracket))),
        ("{", .cursor(.motion(.previousParagraph))),
        ("}", .cursor(.motion(.nextParagraph))),
        ("(", .cursor(.motion(.previousSentence))),
        (")", .cursor(.motion(.nextSentence))),
        ("<plus>", .cursor(.motion(.nextLineFirstNonBlank))),
        ("<return>", .cursor(.motion(.nextLineFirstNonBlank))),
        ("-", .cursor(.motion(.previousLineFirstNonBlank))),
        ("_", .cursor(.motion(.lineFirstNonBlank))),
        ("H", .cursor(.motion(.screenTop))),
        ("M", .cursor(.motion(.screenMiddle))),
        ("L", .cursor(.motion(.screenBottom))),
        ("t", .cursor(.findCharacter(.tillNextChar, nil))),
        ("T", .cursor(.findCharacter(.tillPreviousChar, nil))),
        (";", .cursor(.repeatCharacterSearch(reversed: false))),
        (",", .cursor(.repeatCharacterSearch(reversed: true))),
        ("zt", .scrollCursor(.top)),
        ("zz", .scrollCursor(.middle)),
        ("zb", .scrollCursor(.bottom)),
        // Display lines are what the arrows already move by.
        ("gj", .move(.down)),
        ("gk", .move(.up)),
        // Vim's `p` puts after the cursor, `P` at it.
        ("p", .paste(register: nil, after: true)),
        ("P", .paste(register: nil)),
        // `gv` selects the last VISUAL range of this field again.
        ("gv", .visualReselect),
        // Escape hands the keys back to NORMAL's own (`TextScope`).
        ("<esc>", .leaveMode),
      ])

    /// VISUAL's own keys, read before the text table's motions (`move`,
    /// `cursor`, `scroll`), which grow the selection; every other key is
    /// swallowed. `y` copies, `p` and `P` paste over it, Command-C and -V
    /// likewise, `o` swaps its ends, and Escape or `v` / `V` again deselect.
    /// Nothing cuts, deletes or changes it: Flash never edits text.
    static let defaultVisualMappings: [ModeMapping] = makeDefaultMappings(
      "visual",
      [
        ("y", .selection(.copy)),
        ("p", .selection(.paste)),
        ("P", .selection(.paste)),
        ("o", .selection(.swapEnds)),
        ("v", .visualMode(.charwise)),
        ("V", .visualMode(.linewise)),
        ("<esc>", .leaveMode),
      ])

    private static func makeDefaultMappings(
      _ table: String, _ bindings: [(String, URLCommand)]
    ) -> [ModeMapping] {
      bindings.map { key, command in
        guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(key) else {
          preconditionFailure("invalid default \(table) mapping: \(key)")
        }
        return ModeMapping(key: canonical, action: .flashCommand(command))
      }
    }

    static let defaultTerminalMappings: [ModeMapping] = {
      let bindings: [(String, URLCommand)] = [
        ("cmd+q", .popupQuit(name: nil)),
        ("cmd+r", .popupRestart(name: nil)),
        ("cmd+w", .leaveMode),
      ]
      return bindings.map { key, command in
        guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(key) else {
          preconditionFailure("invalid default terminal mapping: \(key)")
        }
        return ModeMapping(key: canonical, action: .flashCommand(command))
      }
    }()

    private static func makeDefaultNormalMappings() -> [ModeMapping] {
      let raw: [(String, MappingCommand)] = [
        // vim's movement keys move what has focus (`move`): the caret in
        // editable text, the selection in a list, and the view, by scrolling,
        // in a page or a terminal. `ctrl+e` / `ctrl+y` always scroll, one
        // line, as vim's scroll the view without moving the cursor.
        ("h", .flashCommand(.move(.left))),
        ("l", .flashCommand(.move(.right))),
        ("j", .flashCommand(.move(.down))),
        ("k", .flashCommand(.move(.up))),
        ("ctrl+d", .flashCommand(.move(.halfPageDown))),
        ("ctrl+u", .flashCommand(.move(.halfPageUp))),
        ("ctrl+f", .flashCommand(.move(.pageDown))),
        ("ctrl+b", .flashCommand(.move(.pageUp))),
        ("gg", .flashCommand(.move(.top))),
        ("G", .flashCommand(.move(.bottom))),
        ("ctrl+e", .flashCommand(.scroll(.lineDown))),
        ("ctrl+y", .flashCommand(.scroll(.lineUp))),
        // The vim keys that bind modes and the command line. Only `i` enters
        // INSERT, the explicit entry of AGENTS.md rule 9. Vim's `I` `a` `A`
        // `o` `O` `S` `C` stay unbound, and so swallowed: Flash never edits
        // text (rule 11), and `s` is the letter jump. `:` opens the command
        // line.
        (":", .flashCommand(.commandMode)),
        ("i", .flashCommand(.insertMode)),
        // VISUAL in the focused field, which `v` and `V` engage; nothing
        // where no field is focused.
        ("v", .flashCommand(.visualMode(.charwise))),
        ("V", .flashCommand(.visualMode(.linewise))),
        // The macOS clipboard chords act on what the app selects, as they do
        // outside NORMAL, through each app's `clipboard` bindings. Command-X
        // stays unbound: Flash cuts nothing.
        // `gi` focuses an input and keeps NORMAL.
        ("gi", .flashCommand(.focusInput)),
        ("[a", .flashCommand(.appPrev)),
        ("]a", .flashCommand(.appNext)),
        ("[w", .flashCommand(.focusWindow(.app(.previous)))),
        ("]w", .flashCommand(.focusWindow(.app(.next)))),
        ("[t", .flashCommand(.tabPrev)),
        ("]t", .flashCommand(.tabNext)),
        ("t", .flashCommand(.tabNew)),
        ("g1", .flashCommand(.tabSelect(index: 1))),
        ("g2", .flashCommand(.tabSelect(index: 2))),
        ("g3", .flashCommand(.tabSelect(index: 3))),
        ("g4", .flashCommand(.tabSelect(index: 4))),
        ("g5", .flashCommand(.tabSelect(index: 5))),
        ("g6", .flashCommand(.tabSelect(index: 6))),
        ("g7", .flashCommand(.tabSelect(index: 7))),
        ("g8", .flashCommand(.tabSelect(index: 8))),
        ("g9", .flashCommand(.tabSelect(index: 9))),
        ("g0", .flashCommand(.tabFirst)),
        ("g^", .flashCommand(.tabFirst)),
        ("g$", .flashCommand(.tabLast)),
        ("[m", .flashCommand(.tabMovePrev)),
        ("]m", .flashCommand(.tabMoveNext)),
        // vim's tab keys, and Vimium's: `gt` / `gT` and `K` / `J` switch, `<<` /
        // `>>` reorder. `<` and `>` are the key syntax's markers, so the
        // reference file spells them `<less>` and `<greater>`.
        ("gt", .flashCommand(.tabNext)),
        ("gT", .flashCommand(.tabPrev)),
        ("J", .flashCommand(.tabPrev)),
        ("K", .flashCommand(.tabNext)),
        ("<less><less>", .flashCommand(.tabMovePrev)),
        ("<greater><greater>", .flashCommand(.tabMoveNext)),
        // `ZZ` saves and quits, `ZQ` quits.
        ("ZZ", .flashCommand(.saveAndQuit(force: false))),
        ("ZQ", .flashCommand(.quitApp(force: false))),
        // `ctrl+w` is vim's window prefix: a chord followed by a key is a
        // sequence to the key syntax, read by the interpreter, never Carbon.
        ("ctrl+w h", .flashCommand(.focusWindow(.direction(.left)))),
        ("ctrl+w j", .flashCommand(.focusWindow(.direction(.down)))),
        ("ctrl+w k", .flashCommand(.focusWindow(.direction(.up)))),
        ("ctrl+w l", .flashCommand(.focusWindow(.direction(.right)))),
        ("ctrl+w w", .flashCommand(.focusWindow(.app(.next)))),
        ("ctrl+w q", .flashCommand(.windowClose)),
        ("ctrl+w c", .flashCommand(.windowClose)),
        ("ctrl+w W", .flashCommand(.focusWindow(.app(.previous)))),
        ("ctrl+w n", .flashCommand(.windowNew(private: false))),
        // vim's previous window: the one focused before this one.
        ("ctrl+w p", .flashCommand(.windowLast)),
        // vim moves the window to that edge; here it takes that half.
        (
          "ctrl+w H",
          .flashCommand(.moveWindow(MoveWindowParams(layout: .position(.leftHalf), screen: 0)))
        ),
        (
          "ctrl+w J",
          .flashCommand(.moveWindow(MoveWindowParams(layout: .position(.bottomHalf), screen: 0)))
        ),
        (
          "ctrl+w K",
          .flashCommand(.moveWindow(MoveWindowParams(layout: .position(.topHalf), screen: 0)))
        ),
        (
          "ctrl+w L",
          .flashCommand(.moveWindow(MoveWindowParams(layout: .position(.rightHalf), screen: 0)))
        ),
        (
          "ctrl+w o",
          .flashCommand(.moveWindow(MoveWindowParams(layout: .position(.maximized), screen: 0)))
        ),
        (
          "ctrl+w =",
          .flashCommand(.moveWindow(MoveWindowParams(layout: .position(.centered), screen: 0)))
        ),
        ("ctrl+w s", .flashCommand(.paneSplitHorizontal)),
        ("ctrl+w v", .flashCommand(.paneSplitVertical)),
        ("ctrl+o", .flashCommand(.movementBack)),
        ("ctrl+i", .flashCommand(.movementForward)),
        ("H", .flashCommand(.historyBack)),
        ("L", .flashCommand(.historyForward)),
        // The app's own zoom (Surfingkeys, Tridactyl); `gs` is Vimium's page
        // source.
        ("zi", .flashCommand(.zoomIn)),
        ("zo", .flashCommand(.zoomOut)),
        ("z0", .flashCommand(.zoomReset)),
        ("gs", .flashCommand(.viewSource)),
        // `gm`, go to a monitor: every display shows its number, and the
        // pointer and keyboard focus go to the one typed. `2gm` goes to
        // display 2 at once. (vim's `gm` goes to the middle of the screen
        // line; this lands in the middle of a display.)
        ("gm", .flashCommand(.mouseScreens(.init(focus: true)))),
        // A mouse action is a prefix and a finisher. Prefixes are none,
        // `m` (move), `d` (double) and `c` (context, the right-click).
        // Finishers are `f` (a discovered target), `F` (the grid) and `s`
        // (one visible letter, then its hint). `c` is the operator Vim and
        // Vimium leave free; `r` is reload. Modifiers on the final hint key
        // (`hints.magic_modifiers`) still ride the click.
        //
        // Every prefix letter must be free of a mapping of its own. The
        // interpreter parks a key that is both an exact mapping and the prefix
        // of a longer one until `sequence_timeout_ms` elapses, so binding `t`
        // here would make a bare `t` (new tab) wait a full second. Triple
        // click is deliberately unbound for that reason — add `"tf"` in your
        // own config if you want it, and remove `t` with `"t" = false`.
        // `s` starts no other mapping, so the EasyMotion jump fires at once.
        ("f", .flashCommand(.mouseTarget(.click(.leftClick, modifiers: [])))),
        ("F", .flashCommand(.mouseGrid(.init(.click(.leftClick, modifiers: []))))),
        ("s", .flashCommand(.mouseBigram(.click(.leftClick, modifiers: [])))),
        ("mf", .flashCommand(.mouseTarget(.move))),
        ("mF", .flashCommand(.mouseGrid(.init(.move)))),
        ("ms", .flashCommand(.mouseBigram(.move))),
        ("df", .flashCommand(.mouseTarget(.click(.doubleClick, modifiers: [])))),
        ("dF", .flashCommand(.mouseGrid(.init(.click(.doubleClick, modifiers: []))))),
        ("ds", .flashCommand(.mouseBigram(.click(.doubleClick, modifiers: [])))),
        ("cf", .flashCommand(.mouseTarget(.click(.rightClick, modifiers: [])))),
        ("cF", .flashCommand(.mouseGrid(.init(.click(.rightClick, modifiers: []))))),
        ("cs", .flashCommand(.mouseBigram(.click(.rightClick, modifiers: [])))),
        // Vimium's `<a-f>`: a click chain, labels again after every click
        // until Escape. Command held on a label opens a link in a new tab.
        ("alt+f", .flashCommand(.mouseTarget(.multi(.leftClick, modifiers: [])))),
        ("u", .flashCommand(.undo)),
        ("ctrl+r", .flashCommand(.redo)),
        ("x", .flashCommand(.tabClose)),
        ("X", .flashCommand(.tabReopen)),
        ("r", .flashCommand(.reload(force: false))),
        ("R", .flashCommand(.reload(force: true))),
        ("y", .flashCommand(.yankSelection(register: nil))),
        // Outside text there is no cursor to put after or before: `p` and
        // `P` both paste at the app's insertion point. The text table puts
        // `p` after the cursor, as Vim does.
        ("p", .flashCommand(.paste(register: nil))),
        ("P", .flashCommand(.paste(register: nil))),
        ("/", .flashCommand(.find)),
        // `n` / `N` step through Find's matches (Cmd-G / Cmd-Shift-G by
        // convention): app actions like `/`, so NORMAL stays.
        ("n", .flashCommand(.findNext)),
        ("N", .flashCommand(.findPrevious)),
        ("?", .flashCommand(.showMappings)),
        // Escape is the app's own cancel (a popover, a dialog, a search);
        // hints, a half-typed key and an engaged field's Escape come first.
        ("<esc>", .flashCommand(.appCancel)),
        // `.` runs the last command again (a count before it replaces the
        // count it ran with); `q{reg}` and `@{reg}` record and play macros
        // while no mapping takes `q` or `@`.
        (".", .flashCommand(.macro(.repeatLast(count: nil)))),
      ]
      // Every built-in bracket-pair mapping follows vim-unimpaired repetition:
      // after `[x` or `]x`, additional presses of `x` repeat the action.
      let repeatableKeys = Set(
        raw.lazy.map(\.0).filter { $0.hasPrefix("[") || $0.hasPrefix("]") })
      return raw.map { (key, action) in
        guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(key) else {
          preconditionFailure("default mapping key \"\(key)\" failed canonicalization")
        }
        return ModeMapping(
          key: canonical,
          action: action,
          repeatsOnFinalKey: repeatableKeys.contains(key))
      }
    }

    func mappings(for mode: FlashMode) -> [ModeMapping] {
      switch mode {
      case .normal:
        return Self.resolveMappings(normal + all)
      case .insert:
        return Self.resolveMappings(insert + all)
      }
    }

    /// Scope-specific entries precede all-mode fallbacks. Chord aliases share
    /// one winner across the interpreter and native hotkey dispatcher.
    static func resolveMappings(_ mappings: [ModeMapping]) -> [ModeMapping] {
      var keys: Set<String> = []
      var chords: Set<ParsedHotkey> = []
      return mappings.filter { mapping in
        guard keys.insert(mapping.key).inserted else { return false }
        guard let chord = mapping.nativeHotkey else { return true }
        return chords.insert(chord).inserted
      }
    }

    /// O(1)-lookup view used on every keystroke. Refreshed by
    /// `prepareDerivedValues()` after every config load / reload.
    private(set) var compiledNormal = CompiledMappings()
    private(set) var compiledInsert = CompiledMappings()
    private(set) var compiledTerminal = CompiledMappings()
    private(set) var compiledHyper = CompiledMappings()
    /// The table the interpreter reads in HOLD (`heldMappings`).
    private(set) var compiledHold = CompiledMappings()
    /// The table the interpreter reads in NORMAL while it acts on the
    /// focused text (`textMappings`).
    private(set) var compiledText = CompiledMappings()
    /// The table the interpreter reads in VISUAL (`visualMappings`).
    private(set) var compiledVisual = CompiledMappings()
    /// The table the interpreter reads in each layer (`layerMappings`).
    private(set) var compiledLayers: [String: CompiledMappings] = [:]

    /// The interpreter's table for a layer; an undeclared one reads Escape
    /// and `[mode.all]` alone.
    func compiledLayer(_ name: String) -> CompiledMappings {
      compiledLayers[name] ?? CompiledMappings(layerMappings(name), readsVimKeys: false)
    }

    /// What a held-button mode reads: its own entries, then the NORMAL and
    /// all-mode ones it leaves alone. An own key hides every NORMAL key it
    /// starts, so it never waits on a longer NORMAL sequence, and `false` in
    /// its table removes a NORMAL key there.
    func heldMappings(_ purpose: ButtonHold) -> [ModeMapping] {
      assert(purpose == .hold)
      let scope: ModeScope = .hold
      let own = hold
      let separator = String(NormalModeInterpreter.keyAtomSeparator)
      let inherited = mappings(for: .normal).filter { base in
        !removes(base, in: scope)
          && !own.contains { base.key == $0.key || base.key.hasPrefix($0.key + separator) }
      }
      return Self.resolveMappings(own + inherited)
    }

    /// What NORMAL reads while a field is engaged: the text table's
    /// own entries, then the NORMAL and all-mode ones it leaves alone. An own
    /// key hides every NORMAL key it starts, and `false` in its table removes
    /// a NORMAL key there.
    func textMappings() -> [ModeMapping] {
      let scope: ModeScope = .text
      let own = text
      let separator = String(NormalModeInterpreter.keyAtomSeparator)
      let inherited = mappings(for: .normal).filter { base in
        !removes(base, in: scope)
          && !own.contains { base.key == $0.key || base.key.hasPrefix($0.key + separator) }
      }
      return Self.resolveMappings(own + inherited)
    }

    /// What VISUAL reads: its own keys (the operators, `v`, `V`, `o`,
    /// Escape), then the motions of the text table and NORMAL it leaves
    /// alone (`move`, `cursor`, `scroll`), then `[mode.all]`. Any other key
    /// is swallowed: tabs, hints and app commands are not VISUAL's.
    func visualMappings() -> [ModeMapping] {
      let scope: ModeScope = .visual
      let own = visual
      let separator = String(NormalModeInterpreter.keyAtomSeparator)
      let motions = textMappings().filter { base in
        Self.isMotion(base.action) && !removes(base, in: scope)
          && !own.contains { base.key == $0.key || base.key.hasPrefix($0.key + separator) }
      }
      let allMode = all.filter { !removes($0, in: scope) }
      return Self.resolveMappings(own + motions + allMode)
    }

    /// A command that moves the cursor or the view, which VISUAL inherits.
    static func isMotion(_ action: MappingCommand) -> Bool {
      guard case .flashCommand(let command) = action else { return false }
      switch command {
      case .move, .cursor, .scroll, .scrollCursor: return true
      default: return false
      }
    }

    var effectiveTerminalMappings: [ModeMapping] {
      var claimed = Set<String>()
      let explicit = terminal.filter {
        claimed.insert(CompiledMappings.physicalIdentity(for: $0.key)).inserted
      }
      var insertClaimed = Set<String>()
      let inherited = mappings(for: .insert).filter {
        let identity = CompiledMappings.physicalIdentity(for: $0.key)
        return insertClaimed.insert(identity).inserted
          && ($0.action.command == .normalMode || $0.action.command == .leaveMode)
          && !removes($0, in: .terminal)
          && claimed.insert(identity).inserted
      }
      return explicit + inherited
    }

    mutating func recompileMappings() {
      compiledNormal = CompiledMappings(mappings(for: .normal))
      compiledInsert = CompiledMappings(mappings(for: .insert))
      compiledTerminal = CompiledMappings(effectiveTerminalMappings)
      compiledHyper = CompiledMappings(Self.resolveMappings(hyper))
      compiledHold = CompiledMappings(heldMappings(.hold))
      compiledText = CompiledMappings(textMappings())
      compiledVisual = CompiledMappings(
        visualMappings(), readsVimKeys: false, stopsRecording: true)
      compiledLayers = Dictionary(
        uniqueKeysWithValues: layers.keys.map {
          ($0, CompiledMappings(layerMappings($0), readsVimKeys: false))
        })
    }

    /// One mapping-key atom, or nil. `"<leader>"` becomes the leader atom, and
    /// stays nil when the leader itself is unset. Any other single key is
    /// used as written (`"a"`, `"<space>"`, `"cmd+space"`).
    static func resolveHyperKey(_ raw: String, leader: String?) -> String? {
      guard let canonical = NormalModeInterpreter.canonicalizeMappingKey(raw) else { return nil }
      let atoms = NormalModeInterpreter.keyAtoms(from: canonical)
      guard atoms.count == 1, let atom = atoms.first else { return nil }
      if atom == "<leader>" {
        guard let leader else { return nil }
        return NormalModeInterpreter.translateLeader(leader)
      }
      return atom
    }

    mutating func refreshLeaderDerivedDefaults() {
      resolvedHyperKey = Self.resolveHyperKey(hyperKey, leader: normalLeader)
      resolvedHyperMatcher = resolvedHyperKey.map(HyperKeyMatcher.init(atom:))
      resolvedLeaderAtom = normalLeader.flatMap(NormalModeInterpreter.translateLeader)
      guard let leaderRaw = normalLeader,
        let leaderInternal = NormalModeInterpreter.translateLeader(leaderRaw)
      else { return }
      func resolvingLeader(_ mapping: ModeMapping) -> ModeMapping {
        guard mapping.key.contains("<leader>") else { return mapping }
        return ModeMapping(
          key: mapping.key.replacingOccurrences(of: "<leader>", with: leaderInternal),
          action: mapping.action,
          repeatsOnFinalKey: mapping.repeatsOnFinalKey,
          origin: mapping.origin)
      }
      normal = normal.map(resolvingLeader)
      hold = hold.map(resolvingLeader)
    }

    var containsNormalModeMapping: Bool {
      let appEntries = appMappings.values.flatMap {
        $0.all + $0.normal + $0.insert + $0.terminal + $0.command
      }
      return (all + normal + insert + command + terminal + appEntries).contains { mapping in
        mapping.action.command == .normalMode || mapping.action.command == .leaveMode
      }
    }

    var containsAdvancedModeMapping: Bool {
      (all + appMappings.values.flatMap(\.all)).contains { mapping in
        mapping.action.command == .normalMode || mapping.action.command == .leaveMode
      }
    }
  }

  var hints = Hints()
  var app = App()
  var keyboard = Keyboard()
  var clipboard = Clipboard()
  /// `[calendar]`: the events `#{flash.calendar.next…}` and the `calendar`
  /// commands count.
  var calendar = CalendarSettings()
  /// `[tiling]`: tiling and workspaces, off by default (docs/tiling.md).
  var tiling = TilingSettings()
  var overlay = Overlay()
  var plugins = Plugins()
  var statusBar = StatusBar()
  var widgets: [String: Widget] = [:]
  var monitors: [String: Monitor] = Self.defaultMonitors
  var popupStyle = PopupStyle()
  /// `[popup.<name>]`: one namespace for text and terminal popups.
  var popups: [String: Popup] = Self.defaultPopups
  /// Names whose latest declaration was invalid. A reload keeps such a
  /// terminal popup's running session on its last good definition.
  var invalidPopupNames: Set<String> = []
  /// The defining layer of each text popup.
  var popupSourceURLs: [String: URL] = [:]
  var mode = Mode()
  var windowRules: [WindowPlacementRule] = []
  var debug = Debug()
  var telemetry = Telemetry()
  var flashlight = Flashlight()
  var startup = Startup()
  var diagnostics: [ConfigDiagnostic] = []
  /// Plain-string view over `diagnostics`. Existed as a parallel
  /// mutable field; collapsed to a computed projection so the two
  /// can't drift.
  var warnings: [String] { diagnostics.map(\.message) }
  var valueLocations: [String: ConfigLocation] = [:]
  /// Winning writer for each authored path. The bundled default layer does
  /// not record one, so a missing path is still the default configuration.
  var valueSources: [String: ConfigValueSource] = [:]
  /// Set for the layer currently being applied. `recordLocation` stamps it
  /// onto `valueSources`.
  var activeValueSource: ConfigValueSource?
  /// Prepared from `hints.keys` by `ConfigLoader` after TOML/env
  /// precedence has settled. Activation should use this stored value
  /// instead of re-parsing layout selectors.
  private(set) var resolvedAlphabet: Alphabet.Resolved = Alphabet.resolve(Alphabet.defaultKeys)
  /// The mouse grid's keys: `hints.mouse_grid_keys`, or the left-hand block of
  /// the resolved `hints.keys` layout. Derived after overrides so a user's
  /// layout wins over the default layer's empty value.
  private(set) var resolvedMouseGridKeys: [[Character]] = Alphabet.gridKeys(layoutName: nil)

  /// The widgets to show: enabled, with a template (a missing one is
  /// diagnosed at load).
  var enabledWidgets: [String: Widget] {
    widgets.filter { $0.value.enabled && !$0.value.template.template.isEmpty }
  }

  /// The monitors to evaluate: enabled and complete (a problem is diagnosed
  /// at load).
  var enabledMonitors: [String: Monitor] {
    monitors.filter { $0.value.enabled && $0.value.problem == nil }
  }

  /// Every monitor, compiled for the status controller; a disabled or
  /// incomplete one is listed but never evaluated.
  /// The value monitors the status controller evaluates.
  var monitorSpecs: [String: StatusMonitorSpec] {
    Dictionary(
      uniqueKeysWithValues: monitors.filter { $0.value.event.isEmpty }.map {
        ($0.key, $0.value.spec(name: $0.key))
      })
  }

  /// The enabled event monitors that can run, by name.
  var eventMonitorSpecs: [String: EventMonitorSpec] {
    monitors.compactMapValues { monitor in
      guard monitor.enabled, monitor.problem == nil else { return nil }
      return monitor.eventSpec()
    }
  }

  /// `mode terminal` without `--name` opens this popup.
  static let defaultPopupName = "terminal"
  /// The built-in popups, mirrored by `config.default.toml`: a fresh login
  /// shell in the home directory. `$SHELL` and `~` expand at launch.
  static let defaultPopups: [String: Popup] = [
    defaultPopupName: .terminal(Terminal(command: ["$SHELL", "-l"], workingDirectory: "~"))
  ]

  /// The text popups' compiled status formats.
  var textPopups: [String: FlashStatusBarTemplate] {
    popups.compactMapValues { popup in
      if case .text(let template) = popup { return template }
      return nil
    }
  }

  /// The terminal popups' definitions.
  var terminalPopups: [String: Terminal] {
    popups.compactMapValues { popup in
      if case .terminal(let terminal) = popup { return terminal }
      return nil
    }
  }

  /// The popup names the bar gives a hover region with no text body: every
  /// terminal popup, and every invalid name that is not a text popup (a
  /// reload keeps such a terminal's session on its last good definition).
  var terminalPopupNames: Set<String> {
    let text = textPopups
    return Set(terminalPopups.keys).union(invalidPopupNames.filter { text[$0] == nil })
  }

  /// Every popup name a user can open: the enabled bar's markers (template
  /// and text popup bodies) and `[statusbar.click]` commands, and
  /// `mode terminal` in every mapping scope, where no name means
  /// `terminal`.
  var referencedPopupNames: Set<String> {
    var names: Set<String> = []
    func collect(_ command: MappingCommand) {
      if case .flashCommand(.terminalMode(let name)) = command {
        names.insert(name ?? Self.defaultPopupName)
      }
    }
    if statusBar.enabled {
      names.formUnion(statusBar.shownPopupNames)
      for template in textPopups.values {
        names.formUnion(StatusFormatDocument.popupNames(in: template.template))
      }
      for case .command(let command) in statusBar.clickActions.values { collect(command) }
    }
    let appEntries = mode.appMappings.values.flatMap {
      $0.all + $0.normal + $0.insert + $0.terminal + $0.command
    }
    for mapping in mode.all + mode.normal + mode.insert + mode.terminal + mode.command + appEntries
      + mode.layerMappingEntries
    {
      collect(mapping.action)
    }
    return names
  }

  /// The fresh terminal popups kept started ahead of their opening, so
  /// showing one attaches to a live process: the referenced ones.
  var prewarmedPopupNames: Set<String> {
    let terminals = terminalPopups
    return referencedPopupNames.filter { name in
      guard let terminal = terminals[name], terminal.lifecycle == .fresh else { return false }
      return !terminal.readsHoveredLink
    }
  }

  /// Plugin id → the status segments a live surface shows: the enabled bar
  /// (template and text popups), every enabled widget not in
  /// `hiddenWidgets` (fully covered) and every enabled monitor, which
  /// watches whether anything shows it. The ids keep status-bound plugins
  /// resident; the segments are what `core:status.observed` reports to each
  /// plugin.
  func observedStatusSegments(hiddenWidgets: Set<String> = []) -> [String: Set<String>] {
    var segments =
      statusBar.enabled
      ? Self.statusSegments(in: [statusBar.template] + Array(textPopups.values)) : [:]
    let shown = enabledWidgets.filter { !hiddenWidgets.contains($0.key) }
    for (id, names) in Self.statusSegments(in: shown.values.map(\.template)) {
      segments[id, default: []].formUnion(names)
    }
    for spec in monitorSpecs.values where spec.enabled {
      for (id, names) in spec.pluginSegments {
        segments[id, default: []].formUnion(names)
      }
    }
    return segments
  }

  /// The monitors a received metric can fire, by name: the enabled value
  /// monitors with a `run` whose `value` reads a `#{flash.otel…}` value. The
  /// receiver listens on loopback, which every local program shares, so
  /// these are what `[telemetry.receiver] token` guards (`resident doctor`).
  func monitorsRunOnReceivedMetrics() -> [String] {
    monitorSpecs.filter { _, spec in
      spec.enabled && spec.fires != .never
        && spec.value.program.dependencies.values.contains(where: TelemetryQuery.isTelemetryKey)
    }.keys.sorted()
  }

  static let `default`: Config = {
    var config = Config()
    config.prepareDerivedValues()
    return config
  }()
  static let ambiguousShiftMagicModifierWarningPrefix = "hints.magic_modifiers includes \"shift\""

  mutating func recordLocation(path: String, location: ConfigLocation?) {
    valueLocations[path] = location
    if let activeValueSource {
      valueSources[path] = activeValueSource
    }
  }

  mutating func addDiagnostic(
    _ message: String, location: ConfigLocation? = nil, file: String? = nil
  ) {
    diagnostics.append(ConfigDiagnostic(message: message, location: location, file: file))
  }

  mutating func removeDiagnostics(where predicate: (String) -> Bool) {
    diagnostics.removeAll { predicate($0.message) }
  }

  /// The layout hint positions use: an explicit `hints.keys` selector, else
  /// the letters of `[keyboard] layout` when `hints.keys` is still the bundled
  /// QWERTY home-and-top default. `<colemak>` is that layout's home, top and
  /// bottom rows, so naming the layout is enough.
  func effectiveHintKeys() -> String {
    let layout = Alphabet.layouts[keyboard.layout] == nil ? "qwerty" : keyboard.layout
    guard valueSources["hints.keys"] == nil, hints.keys == Alphabet.defaultKeys, layout != "qwerty"
    else { return hints.keys }
    return "<\(layout)>"
  }

  /// Layout for keys that have no selector of their own. A resolved hint
  /// alphabet that names a layout wins, so `<dvorak>` and `layout = "colemak"`
  /// keep hint positions, the grid and arrows on Dvorak.
  var positionLayoutName: String {
    if let name = resolvedAlphabet.layoutName, Alphabet.layouts[name] != nil { return name }
    if Alphabet.layouts[keyboard.layout] != nil { return keyboard.layout }
    return "qwerty"
  }

  mutating func prepareDerivedValues() {
    mode.refreshLeaderDerivedDefaults()
    let alphabet = Alphabet.resolve(effectiveHintKeys())
    removeDiagnostics { $0.hasPrefix(Self.unknownKeyPriorityWarningPrefix) }
    let unknownPriority = alphabet.unknownPriorityKeys(hints.keyPriority)
    if !unknownPriority.isEmpty {
      addDiagnostic(
        Self.unknownKeyPriorityWarningPrefix
          + " \(String(unknownPriority)) is not in hints.keys \(effectiveHintKeys()); ignored",
        location: valueLocations["hints.key_priority"])
    }
    resolvedAlphabet = alphabet.prioritizing(hints.keyPriority)
    resolvedMouseGridKeys = MouseGridKeys.resolve(
      hints.mouseGridKeys, layoutName: resolvedAlphabet.layoutName)
    diagnoseAmbiguousShiftMagicModifier()
    installLayoutArrows()
    mode.recompileMappings()
  }

  /// HYPER plus the physical QWERTY ESDF keys posts an arrow, spelled as the
  /// letters those keys type on `[keyboard] layout`. F is the home-row
  /// index-finger mark, and it is right. Derived, so a qwerty default and a
  /// colemak file agree without listing the keys in `config.default.toml`.
  /// A mapping or `false` already on the key wins. Shift uses that same
  /// letter (`shift+s` is Colemak down). A key that types punctuation uses
  /// the character Shift types there (`>` is Dvorak up): the key code's ANSI
  /// name can be another arrow's letter. Idempotent: a second pass drops
  /// only the arrows this installed.
  private mutating func installLayoutArrows() {
    mode.hyper.removeAll { mapping in
      guard mapping.origin == ModeMapping.defaultOrigin else { return false }
      if case .flashCommand(.arrow(_, _)) = mapping.action { return true }
      return false
    }
    let cluster = Alphabet.navigation(layoutName: positionLayoutName).esdf
    let directions: [(Alphabet.Key, WindowFocusDirection)] = [
      (cluster.left, .left), (cluster.down, .down), (cluster.up, .up),
      (cluster.right, .right),
    ]
    for (key, direction) in directions {
      let shifted =
        key.character.isLetter
        ? "shift+\(key.character)"
        : Self.shiftedPunctuation[key.character] ?? "shift+\(key.ansi)"
      for (raw, shift) in [
        (String(key.character), false), (shifted, true),
      ] {
        guard let mappingKey = Self.arrowMappingKey(raw) else { continue }
        let action = MappingCommand.flashCommand(.arrow(direction: direction, shift: shift))
        let mapping = ModeMapping(key: mappingKey, action: action)
        if mode.hyper.contains(where: { $0.key == mappingKey }) { continue }
        if mode.removes(mapping, in: .hyper) { continue }
        mode.hyper.append(mapping)
      }
    }
  }

  /// US ANSI shift of a punctuation key, in mapping syntax. `<` and `>` are
  /// not bare mapping characters.
  private static let shiftedPunctuation: [Character: String] = [
    ".": "<greater>", ",": "<less>", "/": "?", ";": ":", "'": "\"",
    "[": "{", "]": "}", "-": "_", "=": "<plus>", "`": "~", "\\": "|",
  ]

  /// ASCII keys go through the mapping canonicalizer. A layout letter outside
  /// ASCII (Bépo `é`, and `shift+é`) is still the character that key types.
  private static func arrowMappingKey(_ raw: String) -> String? {
    if let key = NormalModeInterpreter.canonicalizeMappingKey(raw) { return key }
    let shifted = raw.hasPrefix("shift+")
    let body = shifted ? String(raw.dropFirst("shift+".count)) : raw
    guard let character = body.first, body.dropFirst().isEmpty, character.isLetter else {
      return nil
    }
    return shifted ? "shift+\(character)" : String(character)
  }

  /// `hints.magic_modifiers` for target hints. Shift is dropped when the
  /// resolved `hints.keys` holds a non-letter (a literal alphabet may use `;`
  /// or `'`), because a shifted key then types a different character. The
  /// layout presets are letters only, so they keep Shift. The mouse grid reads
  /// the unshifted key itself, so its digits and punctuation never need this.
  var effectiveMagicModifiers: [String] {
    guard resolvedAlphabet.chars.contains(where: { !$0.isLetter }) else {
      return hints.magicModifiers
    }
    return hints.magicModifiers.filter { $0.lowercased() != "shift" }
  }

  static let unknownKeyPriorityWarningPrefix = "hints.key_priority:"

  private mutating func diagnoseAmbiguousShiftMagicModifier() {
    removeDiagnostics { $0.hasPrefix(Self.ambiguousShiftMagicModifierWarningPrefix) }
    guard effectiveMagicModifiers.count != hints.magicModifiers.count else { return }
    addDiagnostic(
      "hints.magic_modifiers includes \"shift\", but resolved hints.keys "
        + "contains non-letter characters (\(String(resolvedAlphabet.chars))); "
        + "removed \"shift\" because shifted-character input is ambiguous",
      location: valueLocations["hints.keys"] ?? valueLocations["hints.magic_modifiers"]
    )
  }

  /// JSON object string of the `[plugins.<id>]` settings for `pluginID`,
  /// suitable for `FLASH_PLUGIN_CONFIG`. Returns `{}` when the plugin has
  /// no settings.
  func pluginConfigJSON(for pluginID: String) -> String {
    let table = plugins.settings[pluginID]?.mapValues(\.jsonValue) ?? [:]
    guard
      let data = try? JSONSerialization.data(withJSONObject: table, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return json
  }

  /// A monitor's `usb` filter as the page and `config show` present it.
  static func usbFilterJSON(_ filter: USBDeviceFilter) -> [String: Any] {
    var object: [String: Any] = [:]
    if let vendorID = filter.vendorID { object["vendor_id"] = vendorID }
    if let productID = filter.productID { object["product_id"] = productID }
    if let name = filter.name { object["name"] = name }
    return object
  }

  var resolvedConfigJSON: String {
    let modeJSON: [String: Any] = [
      "all": mode.all.map(Self.mappingJSONValue),
      "apps": mode.appMappings.mapValues { app in
        [
          "all": app.all.map(Self.mappingJSONValue),
          "normal": app.normal.map(Self.mappingJSONValue),
          "insert": app.insert.map(Self.mappingJSONValue),
          "terminal": app.terminal.map(Self.mappingJSONValue),
          "command": app.command.map(Self.mappingJSONValue),
          "hyper": app.hyper.map(Self.mappingJSONValue),
          "hold": app.hold.map(Self.mappingJSONValue),
          "text": app.text.map(Self.mappingJSONValue),
          "visual": app.visual.map(Self.mappingJSONValue),
          "unmapped": app.unmapped.reduce(into: [String: [String]]()) { result, entry in
            result[entry.key.rawValue] = entry.value.sorted()
          },
          "text_enabled": app.engagesText.map { $0 as Any } ?? NSNull(),
        ]
      },
      "command": mode.command.map(Self.mappingJSONValue),
      "insert": mode.insert.map(Self.mappingJSONValue),
      "terminal": mode.effectiveTerminalMappings.map(Self.mappingJSONValue),
      "labels": [
        "command": mode.labels.command,
        "hyper": mode.labels.hyper,
        "insert": mode.labels.insert,
        "normal": mode.labels.normal,
        "terminal": mode.labels.terminal,
        "hold": mode.labels.hold,
        "visual": mode.labels.visual,
        "visual_line": mode.labels.visualLine,
      ],
      "hyper": mode.hyper.map(Self.mappingJSONValue),
      "hold": mode.hold.map(Self.mappingJSONValue),
      "text": mode.text.map(Self.mappingJSONValue),
      "visual": mode.visual.map(Self.mappingJSONValue),
      "layers": mode.layers.mapValues { layer in
        [
          "label": layer.label ?? NSNull(),
          "sticky": layer.sticky,
          "mappings": layer.mappings.map(Self.mappingJSONValue),
          "unmapped": layer.unmapped.sorted(),
        ] as [String: Any]
      },
      "hyper_key": mode.hyperKey,
      "hyper_key_atom": mode.resolvedHyperKey ?? NSNull(),
      "normal": mode.normal.map(Self.mappingJSONValue),
      "normal_leader": mode.normalLeader ?? NSNull(),
      "scroll_smooth_ms": mode.scrollSmoothMs,
      "text_enabled": mode.textEnabled,
    ]
    return compactJSON([
      "debug": [
        "hints_bounds_bg": debug.hintsBoundsBG,
        "hints_bounds_fg": debug.hintsBoundsFG,
        "http_inspector_enabled": debug.httpInspectorEnabled,
        "http_inspector_host": debug.httpInspectorHost,
        "http_inspector_port": debug.httpInspectorPort,
        "log_level": debug.logLevel.name,
        "show_hints_bounds": debug.showHintsBounds,
      ],
      "keyboard": ["layout": keyboard.layout],
      "hints": [
        "adjust_digits": hints.adjustDigits.rawValue,
        "key_priority": hints.keyPriority,
        "keys": effectiveHintKeys(),
        "label_order": hints.labelOrder.rawValue,
        "magic_modifiers": effectiveMagicModifiers,
        "min_length": hints.minLength,
        "pointer_acceleration": hints.pointerAcceleration,
        "pointer_follows_focus": hints.pointerFollowsFocus,
        "pointer_max_step": hints.pointerMaxStep,
        "pointer_step": hints.pointerStep,
        "position_history_scope": hints.positionHistoryScope.rawValue,
        "position_history_size": hints.positionHistorySize,
        "mouse_grid_cursor_follow": hints.mouseGridCursorFollow,
        "mouse_grid_keys": resolvedMouseGridKeys.map { String($0) },
        "mouse_grid_opacity": hints.mouseGridOpacity,
        "mouse_grid_preview": hints.mouseGridPreview,
        "mouse_grid_steps": hints.mouseGridSteps,
        "restore_pointer": hints.restorePointer,
      ],
      "flashlight": [
        "aliases": flashlight.aliases,
        "bangs": flashlight.bangs.mapValues {
          ["url": $0.url, "description": $0.description] as [String: Any]
        },
        "ignored_apps": flashlight.ignoredApps,
        "precedence": flashlight.precedence,
        "precedence_alive_bonus": flashlight.precedenceAliveBonus,
        "suggestion_count": flashlight.suggestionCount,
      ],
      "mode": modeJSON,
      "overlay": [
        "click_feedback": overlay.clickFeedback,
        "dark": [
          "hint_bg_bottom": overlay.dark.hintBGBottom,
          "hint_bg_top": overlay.dark.hintBGTop,
          "hint_border": overlay.dark.hintBorder,
          "hint_fg": overlay.dark.hintFG,
          "important_hint_bg_bottom": overlay.dark.importantHintBGBottom,
          "important_hint_bg_top": overlay.dark.importantHintBGTop,
          "important_hint_border": overlay.dark.importantHintBorder,
          "important_hint_fg": overlay.dark.importantHintFG,
        ],
        "font_size": overlay.fontSize,
        "hint_bg_bottom": overlay.hintBGBottom,
        "hint_bg_top": overlay.hintBGTop,
        "hint_border": overlay.hintBorder,
        "hint_fg": overlay.hintFG,
        "hint_placement": overlay.hintPlacement.rawValue,
      ],
      "plugins": [
        "disabled": plugins.disabled.sorted(),
        "third_party": plugins.thirdParty.map(\.raw),
        "watching_enabled": plugins.watchingEnabled,
        // Diagnostics/inspector JSON is intentionally value-free: per-plugin
        // settings can contain API tokens and are delivered only to that
        // plugin through FLASH_PLUGIN_CONFIG.
        "configured": plugins.settings.keys.sorted(),
      ],
      "clipboard": ["history_size": clipboard.historySize],
      "calendar": [
        "calendars": calendar.calendars, "all_day": calendar.allDay,
        "declined": calendar.declined, "lookahead_hours": calendar.lookaheadHours,
      ],
      "tiling": [
        "enabled": tiling.enabled, "persist": tiling.persist, "layout": tiling.layout.rawValue,
        "orientation": tiling.orientation?.rawValue ?? "auto",
        "accordion_padding": Int(tiling.accordionPadding), "workspaces": tiling.workspaces,
        "rules": tiling.rules.count,
      ] as [String: Any],
      // Kinds, lifecycles and sizes only: commands and environments can
      // carry credentials.
      "popup": [
        "bg": popupStyle.background, "border": popupStyle.borderColor,
        "border_size": popupStyle.borderWidth, "corner_radius": popupStyle.cornerRadius,
        "fg": popupStyle.foreground, "max_width": popupStyle.maxWidth,
        "min_width": popupStyle.minWidth,
        "offset": popupStyle.offset, "padding": popupStyle.padding,
        "popups": popups.mapValues { popup -> [String: Any] in
          switch popup {
          case .text: return ["kind": "text"]
          case .terminal(let terminal):
            return [
              "kind": "terminal", "persistent": terminal.lifecycle == .persistent,
              "pause_hidden": terminal.pauseHidden, "size": terminal.size.description,
            ]
          }
        },
      ] as [String: Any],
      "statusbar": [
        "enabled": statusBar.enabled,
        "template": statusBar.template.template,
        "sources": statusBar.sources.keys.sorted(),
      ],
      "widgets": widgets.mapValues { widget in
        [
          "enabled": widget.enabled, "template": widget.template.template,
          "anchor": widget.anchor.rawValue, "columns": widget.columns,
          "interval": widget.intervalSeconds,
        ] as [String: Any]
      },
      "monitors": monitors.mapValues { monitor in
        [
          "enabled": monitor.enabled, "value": monitor.value, "message": monitor.message,
          "warning": monitor.warning as Any? ?? NSNull(),
          "error": monitor.error as Any? ?? NSNull(),
          "direction": monitor.direction.rawValue, "interval": monitor.intervalSeconds,
          "event": monitor.event, "app": monitor.app, "alert": monitor.alert,
          "usb": monitor.usb.map(Self.usbFilterJSON) ?? NSNull(),
          "run": monitor.run.isEmpty ? NSNull() : monitor.run.map(\.argv) as Any,
          "timeout": monitor.timeout, "cooldown": monitor.cooldown,
        ] as [String: Any]
      },
      // Header names only: their values are credentials.
      "telemetry": [
        "receiver": [
          "enabled": telemetry.receiver.enabled, "port": telemetry.receiver.port,
          "max_series": telemetry.receiver.maxSeries, "max_points": telemetry.receiver.maxPoints,
          "max_logs": telemetry.receiver.maxLogs, "max_spans": telemetry.receiver.maxSpans,
          // Whether one is set, never its value.
          "token": !telemetry.receiver.token.isEmpty,
        ],
        "exporter": [
          "endpoint": telemetry.exporter.endpoint,
          "protocol": telemetry.exporter.encoding.rawValue,
          "compression": telemetry.exporter.gzip ? "gzip" : "none",
          "headers": telemetry.exporter.headers.keys.sorted(),
          "service_name": telemetry.exporter.serviceName,
          "signals": telemetry.exporter.signals.sorted().map(\.rawValue),
          "interval": telemetry.exporter.intervalSeconds,
        ] as [String: Any],
      ],
      "startup": [
        "run": startup.run.map(\.argv), "timeout": startup.timeoutSeconds,
      ] as [String: Any],
      "warnings": warnings,
    ])
  }

  private static func mappingJSONValue(_ mapping: ModeMapping) -> [String: Any] {
    [
      "command": mapping.action.configValue,
      "key": mapping.key,
      "repeat": mapping.repeatsOnFinalKey,
    ]
  }

  /// Sparse tree parallel to `resolvedConfigJSON`. A node's `"$"` is
  /// `{ "layer", "where" }` for the writer that overrode the default. Mapping
  /// arrays are keyed by mapping key; other arrays of names are keyed by the
  /// name. Paths the JSON renames (`mode.normal.leader`, named popups) are
  /// translated onto the JSON shape.
  func resolvedConfigSources() -> [String: Any] {
    var tree: [String: Any] = [:]
    for (path, source) in valueSources {
      Self.insert(source, at: Self.jsonPath(for: path), into: &tree)
    }
    insertMappingSources(into: &tree)
    if var mode = tree["mode"] as? [String: Any],
      let hyper = mode["hyper_key"] as? [String: Any],
      let mark = hyper["$"]
    {
      var atom = mode["hyper_key_atom"] as? [String: Any] ?? [:]
      atom["$"] = mark
      mode["hyper_key_atom"] = atom
      tree["mode"] = mode
    }
    return tree
  }

  private static let popupStyleJSONKeys: Set<String> = [
    "fg", "bg", "border", "border_size", "corner_radius", "padding", "min_width", "max_width",
    "offset",
  ]

  private static func jsonPath(for tomlPath: String) -> [String] {
    switch tomlPath {
    case "mode.normal.leader": return ["mode", "normal_leader"]
    case "mode.normal.hyper": return ["mode", "hyper_key"]
    default: break
    }
    var parts = tomlPath.split(separator: ".").map(String.init)
    if parts.count >= 2, parts[0] == "popup", !popupStyleJSONKeys.contains(parts[1]) {
      parts.insert("popups", at: 1)
    }
    return parts
  }

  private static func insert(
    _ source: ConfigValueSource, at path: [String], into node: inout [String: Any]
  ) {
    guard let head = path.first else { return }
    var child = node[head] as? [String: Any] ?? [:]
    if path.count == 1 {
      child["$"] = ["layer": source.layer, "where": source.detail]
    } else {
      insert(source, at: Array(path.dropFirst()), into: &child)
    }
    node[head] = child
  }

  private static func source(forMappingOrigin origin: String) -> ConfigValueSource? {
    if origin.isEmpty || origin == ModeMapping.defaultOrigin { return nil }
    let parts = origin.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
      return ConfigValueSource(layer: origin, detail: origin)
    }
    return ConfigValueSource(layer: parts[0], detail: parts[1])
  }

  private func insertMappingSources(into tree: inout [String: Any]) {
    func add(_ mappings: [ModeMapping], at path: [String]) {
      for mapping in mappings {
        guard let source = Self.source(forMappingOrigin: mapping.origin) else { continue }
        Self.insert(source, at: path + [mapping.key], into: &tree)
      }
    }
    add(mode.all, at: ["mode", "all"])
    add(mode.normal, at: ["mode", "normal"])
    add(mode.insert, at: ["mode", "insert"])
    add(mode.effectiveTerminalMappings, at: ["mode", "terminal"])
    add(mode.command, at: ["mode", "command"])
    add(mode.hyper, at: ["mode", "hyper"])
    add(mode.hold, at: ["mode", "hold"])
    add(mode.text, at: ["mode", "text"])
    add(mode.visual, at: ["mode", "visual"])
    for (name, layer) in mode.layers {
      add(layer.mappings, at: ["mode", "layers", name, "mappings"])
    }
    for (bundle, app) in mode.appMappings {
      for scope in ModeScope.allCases {
        add(app.mappings(for: scope), at: ["mode", "apps", bundle, scope.rawValue])
      }
    }
  }

  var resolvedHintsKeysJSON: String {
    let scores = Dictionary(
      uniqueKeysWithValues: resolvedAlphabet.keyScores.map { (String($0.key), $0.value) }
    )
    return compactJSON([
      "chars": String(resolvedAlphabet.chars),
      "chars_array": resolvedAlphabet.chars.map(String.init),
      "default": Alphabet.defaultKeys,
      "key_scores": scores,
      "layout": resolvedAlphabet.layoutName ?? NSNull(),
      "left_hand": String(resolvedAlphabet.leftHand.sorted()),
      "raw": hints.keys,
      "warning": resolvedAlphabet.warning ?? NSNull(),
    ])
  }

  var loadingDiagnostics: [ConfigDiagnostic] {
    var diagnostics = self.diagnostics
    if let warning = resolvedAlphabet.warning {
      diagnostics.append(
        ConfigDiagnostic(
          message: warning,
          location: valueLocations["hints.keys"]))
    }
    return diagnostics
  }

  var loadingErrorAlertMessage: String? {
    let diagnostics = loadingDiagnostics
    guard !diagnostics.isEmpty else { return nil }
    let visibleDiagnostics = diagnostics.prefix(3).map { "- \($0.alertLine)" }
    var lines = ["[Flash]", diagnostics.count == 1 ? "Config error" : "Config errors"]
    lines.append(contentsOf: visibleDiagnostics)
    let remaining = diagnostics.count - visibleDiagnostics.count
    if remaining > 0 {
      lines.append("- \(remaining) more config issue\(remaining == 1 ? "" : "s")")
    }
    return lines.joined(separator: "\n")
  }

  private func compactJSON(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return json
  }
}

extension URLCommand {
  /// Argv of an in-process command:
  /// `["flash", "<topic>", "<action>", "--k=v", ...]`. Bool flags render only
  /// when on. Value flags use hyphenated `--name=value`. A value that contains
  /// a space stays one element.
  var argv: [String] {
    /// `name` is `"<topic> <action>"`.
    func named(_ name: String, _ args: [String] = []) -> [String] {
      ["flash"] + name.split(separator: " ").map(String.init) + args
    }
    /// Bool-flag arg: `--name` (when on). Off bool flags don't render.
    func flag(_ name: String) -> String { "--\(name)" }
    /// Value arg: `--name=value`. The internal key is snake_case; surface
    /// the hyphenated form so the rendered string can be pasted back into
    /// a shell or config without translation.
    func kv(_ name: String, _ value: Any) -> String {
      let key = name.replacingOccurrences(of: "_", with: "-")
      return "--\(key)=\(value)"
    }
    func percentage(_ value: Double) -> String {
      value.rounded() == value ? "\(Int(value))%" : "\(value)%"
    }
    switch self {
    case .mouseTarget(let command):
      return named("mouse target", command.argTokens)
    case .mouseBigram(let command):
      return named("mouse bigram", command.argTokens)
    case .mouseTargetScreen(let command):
      return named("mouse target", ["--scope=screen"] + command.argTokens)
    case .mouseTargetWords(let command):
      return named("mouse target", ["--words"] + command.argTokens)
    case .mouseScreens(let request): return named("mouse screens", request.argTokens)
    case .mouseWarp(let request): return named("mouse warp", request.argTokens)
    case .mouseStep(let direction):
      return named("mouse step", ["--direction=\(direction.rawValue)"])
    case .mouseJump(let jump): return named("mouse step", ["--to=\(jump.rawValue)"])
    case .selection(let action, let register):
      return named("selection \(action.rawValue)", register.map { [kv("register", $0)] } ?? [])
    case .mouseNudge(let direction, let distance):
      return named("mouse nudge", ["--direction=\(direction.rawValue)", "--distance=\(distance)"])
    case .mousePosition(let request): return named("mouse position", request.argTokens)
    case .mouseGrid(let command):
      return named("mouse grid", command.argTokens)
    case .mouseRepeat: return named("mouse repeat")
    case .mousePointer: return named("mouse pointer")
    case .mouseButton(let request): return named("mouse button", request.argTokens)
    case .holdMode(let button):
      switch button {
      case .primary: return named("mode hold")
      case .secondary: return named("mode hold", [flag("secondary")])
      case .middle: return named("mode hold", [flag("middle")])
      }
    case .focusInput: return named("input focus")
    case .inputMotion(let motion): return named("input \(motion.rawValue)")
    case .move(let move): return named("move \(move.rawValue)")
    case .cursor(let command):
      return named("cursor \(command.argvTail[0])", Array(command.argvTail.dropFirst()))
    case .scrollCursor(let position): return named("scroll \(position.rawValue)")
    case .visualMode(let kind):
      return kind == .linewise ? named("mode visual", [flag("line")]) : named("mode visual")
    case .visualReselect: return named("mode visual", [flag("reselect")])
    case .scrollTarget: return named("scroll target")
    case .mouseDock: return named("mouse dock")
    case .mouseMenuBar: return named("mouse menubar")
    case .mouseNotifications: return named("mouse notifications")
    case .normalMode: return named("mode normal")
    case .leaveMode: return named("mode leave")
    case .popupRestart(let name):
      return named("popup restart", name.map { ["--name=\($0)"] } ?? [])
    case .popupQuit(let name):
      return named("popup quit", name.map { ["--name=\($0)"] } ?? [])
    case .insertMode: return named("mode insert")
    case .commandMode: return named("mode command")
    case .terminalMode(let name):
      return named("mode terminal", name.map { ["--name=\($0)"] } ?? [])
    case .layerMode(let name): return named("mode layer", ["--name=\(name)"])
    case .scroll(let kind):
      switch kind {
      case .left: return named("scroll left")
      case .right: return named("scroll right")
      case .up: return named("scroll up")
      case .down: return named("scroll down")
      case .lineUp: return named("scroll line_up")
      case .lineDown: return named("scroll line_down")
      case .halfPageUp: return named("scroll half_page_up")
      case .halfPageDown: return named("scroll half_page_down")
      case .pageUp: return named("scroll page_up")
      case .pageDown: return named("scroll page_down")
      case .top: return named("scroll top")
      case .bottom: return named("scroll bottom")
      }
    case .reload(let force):
      return force ? named("app reload", [flag("force")]) : named("app reload")
    case .undo: return named("app undo")
    case .redo: return named("app redo")
    case .archive: return named("resource archive")
    case .resourceNext: return named("resource next")
    case .resourcePrevious: return named("resource previous")
    case .tabClose: return named("tab close")
    case .find: return named("app find")
    case .findNext: return named("app find_next")
    case .findPrevious: return named("app find_previous")
    case .appSwitch: return named("app switch")
    case .flashlight(let query, let restoreMode):
      var args: [String] = []
      if let query { args.append(kv("query", query)) }
      if restoreMode { args.append(flag("restore-mode")) }
      return named("mode flashlight", args)
    case .enterCommand(let input, let restoreMode):
      var args = [kv("input", input)]
      if restoreMode { args.append(flag("restore-mode")) }
      return named("mode command", args)
    case .copyURL: return named("url copy")
    case .yankSelection(let register):
      if let register { return named("register yank", [kv("register", register)]) }
      return named("register yank")
    case .paste(let register, let after):
      let flags = after ? [flag("after")] : []
      if let register { return named("register paste", [kv("register", register)] + flags) }
      return named("register paste", flags)
    case .tabNext: return named("tab next")
    case .tabPrev: return named("tab previous")
    case .tabFirst: return named("tab first")
    case .tabLast: return named("tab last")
    case .tabSelect(let index):
      if let index { return named("tab select", [kv("index", index)]) }
      return named("tab select")
    case .tabMovePrev: return named("tab move_previous")
    case .tabMoveNext: return named("tab move_next")
    case .tabReopen: return named("tab reopen")
    case .paneNext: return named("pane next")
    case .panePrev: return named("pane previous")
    case .paneSplitVertical: return named("pane split_vertical")
    case .paneSplitHorizontal: return named("pane split_horizontal")
    case .paneClose: return named("pane close")
    case .historyBack: return named("history back")
    case .historyForward: return named("history forward")
    case .movementBack: return named("movement back")
    case .movementForward: return named("movement forward")
    case .appPrev: return named("app previous")
    case .appNext: return named("app next")
    case .quitApp(let force):
      return force ? named("app quit", [flag("force")]) : named("app quit")
    case .saveAndQuit(let force):
      return force ? named("app save_and_quit", [flag("force")]) : named("app save_and_quit")
    case .appClose: return named("app close")
    case .tabNew: return named("tab new")
    case .save: return named("app save")
    case .print: return named("app print")
    case .documentOpen: return named("document open")
    case .windowNew(let isPrivate):
      return isPrivate ? named("window new", [flag("private")]) : named("window new")
    case .windowCloseAll: return named("window close_all")
    case .windowZoom: return named("window zoom")
    case .documentSaveAs: return named("document save_as")
    case .documentExportPDF: return named("document export_pdf")
    case .documentRevert: return named("document revert")
    case .documentDuplicate: return named("document duplicate")
    case .documentRename: return named("document rename")
    case .documentPageSetup: return named("document page_setup")
    case .appSettings: return named("app settings")
    case .selectAll: return named("app select_all")
    case .appHelp: return named("app help")
    case .appCancel: return named("app cancel")
    case .appStop: return named("app stop")
    case .appDownloads: return named("app downloads")
    case .developerTools: return named("app developer_tools")
    case .appVisibility(let action): return named("app \(action.rawValue)")
    case .urlBookmark: return named("url bookmark")
    case .urlEdit: return named("url edit")
    case .historyShow: return named("history show")
    case .tabDuplicate: return named("tab duplicate")
    case .tabPin: return named("tab pin")
    case .tabMute: return named("tab mute")
    case .tabDetach: return named("tab detach")
    case .menuPress(let path): return named("menu press", [kv("path", path.joined(separator: ","))])
    case .windowClose: return named("window close")
    case .windowSwitch: return named("window switch")
    case .windowLast: return named("window last")
    case .tile(let command):
      switch command {
      case .move(let direction): return named("tile move", [kv("direction", direction.rawValue)])
      case .swap(let direction): return named("tile swap", [kv("direction", direction.rawValue)])
      case .join(let direction): return named("tile join", [kv("direction", direction.rawValue)])
      case .layout(let request): return named("tile layout", [kv("type", request.rawValue)])
      case .resize(let dimension, let amount):
        return named("tile resize", [kv("dimension", dimension.rawValue), kv("amount", amount)])
      case .balance: return named("tile balance")
      case .flatten: return named("tile flatten")
      case .float: return named("tile float")
      case .fullscreen: return named("tile fullscreen")
      }
    case .workspace(let command):
      switch command {
      case .switchTo(let name): return named("workspace switch", [kv("name", name)])
      case .next: return named("workspace next")
      case .previous: return named("workspace previous")
      case .backAndForth: return named("workspace back_and_forth")
      case .moveWindow(let name): return named("workspace move_window", [kv("name", name)])
      case .moveToMonitor(let step):
        return named(
          "workspace move_to_monitor", [kv("direction", step > 0 ? "next" : "previous")])
      case .list: return named("workspace list")
      }
    case .clipboardCopy: return named("clipboard copy")
    case .clipboardPaste: return named("clipboard paste")
    case .clipboardHistory(let action, let id, let offset):
      var parts: [String] = []
      if let id { parts.append(kv("id", id)) }
      if let offset { parts.append(kv("offset", offset)) }
      return named("clipboard \(action)", parts)
    case .clipboardRestore(let id, let paste, let plain):
      var parts = [kv("id", id)]
      if paste { parts.append(flag("paste")) }
      if plain { parts.append(flag("plain")) }
      return named("clipboard restore", parts)
    case .lookUp: return named("app look_up")
    case .zoomIn: return named("app zoom_in")
    case .zoomOut: return named("app zoom_out")
    case .zoomReset: return named("app zoom_reset")
    case .viewSource: return named("app view_source")
    case .trackpadGesture(let fingers, let motion):
      return named("mouse gesture", ["--fingers=\(fingers)", "--motion=\(motion.rawValue)"])
    case .showAlert(let alert): return named("alert show", alert.argTokens)
    case .dismissAlert: return named("alert dismiss")
    case .confirm(let request):
      return named(
        "alert confirm", [kv("prompt", request.prompt), kv("command", request.commandText)])
    case .showUsage(let topic):
      if let topic, !topic.isEmpty { return named("help show", [kv("topic", topic)]) }
      return named("help show")
    case .showMappings:
      return named("mappings show")
    case .showPlugins: return named("plugins show")
    case .reloadPlugins: return named("plugins reload")
    case .showLogs: return named("logs show")
    case .showCommands: return named("commands show")
    case .showMonitors: return named("monitors show")
    case .showTelemetry: return named("telemetry show")
    case .showAbout: return named("about show")
    case .dismissHints: return named("hints dismiss")
    case .quit: return named("resident quit")
    case .openApp(let name): return named("app open", [kv("name", name)])
    case .pluginCommand(let command, let subcommand, let args):
      return ["flash", command, subcommand] + args
    case .moveWindow(let params):
      var parts: [String] = []
      switch params.layout {
      case .position(let position):
        parts.append(kv("position", position.rawValue))
      case .proportional(let frame):
        parts.append(kv("x", percentage(frame.xPercent)))
        parts.append(kv("y", percentage(frame.yPercent)))
        parts.append(kv("width", percentage(frame.widthPercent)))
        parts.append(kv("height", percentage(frame.heightPercent)))
      case nil:
        break
      }
      parts.append(kv("screen", params.screen))
      return named("window move", parts)
    case .windowState(let action):
      switch action {
      case .minimize: return named("window minimize")
      case .restore: return named("window restore")
      case .fullscreen(let state):
        return state == .toggle
          ? named("window fullscreen")
          : named("window fullscreen", [kv("state", state.rawValue)])
      }
    case .focusWindow(.direction(let direction)):
      return named("window focus", [kv("direction", direction.rawValue)])
    case .focusWindow(.cycle(let cycle)):
      return named("window focus", [kv("direction", cycle.rawValue)])
    case .focusWindow(.app(let cycle)):
      return named("window \(cycle.rawValue)")
    case .media(let command):
      return named(command.name.description, command.argTokens)
    case .caffeinate(let request):
      return named(request.name.description, request.argTokens)
    case .statusPush(let push):
      return named(push.name.description, push.argTokens)
    case .statusRefresh(let source):
      return named(StatusRefresh.name.description, ["--name=\(source)"])
    case .notify(let command):
      return named(command.name.description, command.argTokens)
    case .logWrite(let write):
      return named("logs write", write.argTokens)
    case .metricRecord(let record):
      return named("metrics record", record.argTokens)
    case .menuChoose(let file, let prompt):
      return named(
        MenuChoice.name.description, ["--file=\(file)"] + (prompt.map { ["--prompt=\($0)"] } ?? []))
    case .macro(let command):
      return named(command.name.description, command.argTokens)
    case .configReload:
      return named("config reload")
    case .configEdit:
      return named("config edit")
    case .startup(let command):
      return named(command.name.description)
    case .updates(let command):
      return named(command.name.description)
    case .appleCatalog(let command):
      return named(command.name.description)
    case .calendar(let command):
      return named(command.name.description)
    case .marks(let command):
      return named(command.name.description, command.argTokens)
    case .systemKey(let key):
      return named("key system", [kv("key", key.rawValue)])
    case .systemSurface(let command):
      return named(command.name.description)
    case .systemAction(let action):
      return named(action.name.description)
    case .processKill(let pid):
      return named("process kill", [kv("pid", Int(pid))])
    case .functionKey(let index):
      return named("key function", [kv("key", "f\(index)")])
    case .arrow(let direction, let shift):
      let args = [kv("direction", direction.rawValue)]
      return shift ? named("key arrow", args + [flag("shift")]) : named("key arrow", args)
    case .sendKey(let keys, _, _):
      return named("key send", [kv("keys", keys)])
    case .sendKeys(let keys, _, _):
      return named("key sequence", [kv("keys", keys)])
    }
  }

  /// Space-joined `argv` for help text, logs, and the mappings list.
  /// Never re-parsed: splitting it breaks a value that contains a space.
  var diagnosticDescription: String {
    argv.joined(separator: " ")
  }
}

extension MouseCommand {
  /// Arg tokens for `mouse target` / `mouse grid` in diagnostic form.
  /// Empty for a plain left-click, `["--secondary"]` for right-click,
  /// `["--middle"]` for middle-click, `["--double"]` / `["--triple"]` for
  /// multi-clicks, `["--move"]` for cursor-only move, with an optional
  /// `--modifiers=…` suffix for a preset modified click.
  var argTokens: [String] {
    switch self {
    case .move:
      return ["--move"]
    case .copyURL:
      return ["--copy-url"]
    case .copyText:
      return ["--copy-text"]
    case .gesture(let gesture):
      return ["--gesture=\(gesture.rawValue)"]
    case .drag(let modifiers):
      var tokens = ["--drag"]
      if !modifiers.isEmpty {
        tokens.append("--modifiers=\(modifiers.argumentValue)")
      }
      return tokens
    case .select(let modifiers):
      var tokens = ["--select"]
      if !modifiers.isEmpty {
        tokens.append("--modifiers=\(modifiers.argumentValue)")
      }
      return tokens
    case .multi(let action, let modifiers), .adjust(let action, let modifiers),
      .search(let action, let modifiers), .path(let action, let modifiers),
      .sticky(let action, let modifiers):
      let session: String
      switch self {
      case .multi: session = "--multi"
      case .adjust: session = "--adjust"
      case .path: session = "--path"
      case .sticky: session = "--sticky"
      default: session = "--search"
      }
      var tokens = [session]
      switch action {
      case .leftClick: break
      case .rightClick: tokens.append("--secondary")
      case .middleClick: tokens.append("--middle")
      case .doubleClick: tokens.append("--double")
      case .tripleClick: tokens.append("--triple")
      }
      if !modifiers.isEmpty {
        tokens.append("--modifiers=\(modifiers.argumentValue)")
      }
      return tokens
    case .click(let action, let modifiers):
      var tokens: [String]
      switch action {
      case .leftClick: tokens = []
      case .rightClick: tokens = ["--secondary"]
      case .middleClick: tokens = ["--middle"]
      case .doubleClick: tokens = ["--double"]
      case .tripleClick: tokens = ["--triple"]
      }
      if !modifiers.isEmpty {
        tokens.append("--modifiers=\(modifiers.argumentValue)")
      }
      return tokens
    }
  }
}
