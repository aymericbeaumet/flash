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
  struct Startup: Equatable, Sendable {
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
  /// value Flash already has: a `sysinfo` plugin segment or a core
  /// plugin-health value.
  static let defaultMonitors: [String: Monitor] = [
    // The charge only while the Mac runs on its battery: charging, full or on
    // the adapter, the value is empty and nothing alerts.
    "battery": Monitor(
      value:
        "#{?#{==:#{flash.plugin.sysinfo.power_state},discharging},"
        + "#{flash.plugin.sysinfo.power_percent}%%,}",
      message: "Battery low", warning: 20, error: 10, direction: .below),
    "disk": Monitor(
      value: "#{flash.plugin.sysinfo.disks_percent}%%", message: "Startup disk almost full",
      warning: 90, error: 97),
    "memory": Monitor(
      value: "#{flash.plugin.sysinfo.memory_pressure}%%", message: "Memory pressure high",
      warning: 85, error: 95),
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

  var hints = Hints()
  var app = App()
  var keyboard = Keyboard()
  var clipboard = Clipboard()
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

  /// Plugin id → the status segments the configuration's surfaces read: the
  /// enabled bar (template and text popups, open or not), every enabled
  /// widget not in `hiddenWidgets` (covered for a while) and every enabled
  /// monitor, which watches whether anything shows it. The ids keep
  /// status-bound plugins resident, so opening a popup spawns nothing. What
  /// each plugin hears as observed (`core:status.observed`) is narrower: the
  /// segments a surface shows now, which the status controller reports
  /// (`PluginManager.setShownStatusSegments`).
  func statusSegmentsRead(hiddenWidgets: Set<String> = []) -> [String: Set<String>] {
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
}
