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

struct ConfigDiagnostic: Equatable {
  let message: String
  let location: ConfigLocation?

  var logMessage: String {
    guard let location else { return message }
    return "line \(location.line), col \(location.column): \(message)"
  }

  var alertLine: String { logMessage }
}

/// A single value inside a `[plugin.<id>]` settings table. Carries enough
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

struct Config {
  struct App {
    /// macOS menu-bar icon (see `StatusItemController.swift`, the single
    /// sanctioned status item) carrying About / Open Configuration / Quit.
    /// `[app] menu_bar_icon = false` hides it — Flash stays fully
    /// driveable through the CLI and mappings without it.
    var menuBarIcon: Bool = true
    /// Login-item registration through SMAppService, reconciled on every
    /// launch and config reload. `[app] autostart = false` unregisters.
    var autostart: Bool = true
  }
  struct Hints {
    var keys: String = Alphabet.defaultKeys
    var minLength: Int = 1
    var magicModifiers: [String] = ["cmd", "ctrl", "alt", "shift"]
    /// Number of selection steps for the `mouse_grid` verb. Larger values
    /// give finer precision but require more keystrokes per click.
    var mouseGridSteps: Int = 3
    /// Opacity (0.0..1.0) applied to every mouse-grid chip so the user
    /// can still see what's underneath the precision overlay. 1.0 is
    /// fully opaque, 0.0 invisible. Default 0.5 — the underlying window
    /// stays clearly visible through the precision grid.
    var mouseGridOpacity: Double = 0.5
  }
  struct Overlay {
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
    /// Seconds an `alert_show` toast stays up when the call passes no
    /// explicit --duration.
    var alertDuration: Double = 2.0
    /// Milliseconds a transient banner (command output, "Copied: …")
    /// stays up.
    var bannerDurationMs: Int = 700
  }
  /// Tunables for the `:flashlight` command-line surface.
  struct Flashlight {
    /// Number of command-bar suggestions shown for `:flashlight`,
    /// `:emojis`, source filters, bangs, and command completions.
    var suggestionCount: Int = 10
    /// Half-life in days of the frecency decay — the sticky-vs-fresh dial.
    /// Applied when the store is (re)constructed on load/reload.
    var frecencyHalfLifeDays: Double = 14
    /// Cap on the frecency boost added to the ranker score; 0 disables
    /// frecency outright.
    var frecencyMaxBoost: Int = 600
    /// Deadline for the aggregate warm-plugin catalog snapshot feeding the
    /// flashlight pool. A giant browser session may need more room.
    var snapshotTimeoutMs: Int = 150
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
    /// "@ft" = "@firefox.tabs"
    /// ```
    var aliases: [String: String] = [:]
    /// Source precedence override weights applied as the tiebreaker once
    /// match score ties. Keys are source labels (or parent prefixes —
    /// `"firefox"` covers `firefox.tabs`, `firefox.bookmarks`, …). Higher
    /// weight wins. Entries not listed use the source descriptor kind declared
    /// by the native source or plugin manifest: location sources > default.
    /// Weights cannot cross the location band's category ladder (tmux windows
    /// > running apps > installed apps > browser tabs > the rest) — that
    /// ordering is strict and compared before match score.
    ///
    /// Example:
    /// ```toml
    /// [flashlight.precedence]
    /// tmux           = 200
    /// "firefox.tabs" = 120
    /// ```
    var precedence: [String: Int] = [:]
    /// Bonus added to any candidate whose `pid != nil` so running
    /// processes outrank installed-but-not-running rows under the
    /// same source. With the `locations` source kind this gives active
    /// locations an effective rank of 60 vs. inactive 50.
    var precedenceAliveBonus: Int = 10
  }
  struct Debug {
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
    /// verbs (`:logs`, `:plugins`, `:commands`, `:help`, …) start the server
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
  struct Open {
    var ignoredApps: [String] = []
    /// Directories scanned (recursively) and watched for `.app` bundles —
    /// the flashlight's installed-app catalog and the `app_open` verb's
    /// search roots. `~` expands to the user home. The defaults cover
    /// every standard macOS install location, including the Sequoia+ app
    /// cryptex where Safari really lives.
    var appDirectories: [String] = Open.defaultAppDirectories

    static let defaultAppDirectories = [
      "/Applications",
      "/System/Applications",
      "/System/Applications/Utilities",
      "/System/Library/CoreServices",
      "/System/Cryptexes/App/System/Applications",
      "~/Applications",
    ]
  }
  struct Plugins {
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
    /// Handshake deadline: a plugin that warms a big catalog before
    /// answering initialize may need more than the default.
    var startupTimeoutSeconds: Int = 15
    /// Per-plugin user settings from `[plugin.<id>]` tables. Delivered to
    /// each plugin as a JSON object via `FLASH_PLUGIN_CONFIG`. Keyed by
    /// plugin id, then by setting name.
    var settings: [String: [String: PluginConfigValue]] = [:]
  }
  struct StatusBar {
    /// Which displays show the bar. `all` (default) puts it on every screen's
    /// top band; `primary` shows it only on the main (menu-bar) display.
    enum Monitor: String {
      case all
      case primary
    }

    /// Whether the persistent top status bar is shown. This is the *sole*
    /// condition for the bar's visibility — it is deliberately independent
    /// of advanced mode (the `enter_normal_mode` binding). Off by default;
    /// set `[statusbar] enabled = true` to opt in.
    var enabled: Bool = false
    /// Which monitors the bar renders on. `[statusbar] monitor = "primary"`
    /// limits it to the main display; `"all"` (default) covers every screen.
    var monitor: Monitor = .all
    /// Bar text size in points (the mode pill uses the same size).
    var fontSize: Double = 13
    /// Timeout in seconds for one command/script/cycle subprocess run;
    /// SIGTERM then SIGKILL past it, keeping the previous value.
    var commandTimeoutSeconds: Double = 6
    /// Points kept clear on each side of a notch (camera housing).
    var notchMargin: Double = 0
    /// Poll cadence in seconds for command/script/cycle template sections —
    /// tmux's `status-interval` analog (`[statusbar] interval`). A source
    /// can override it inline (`#{script=30:…}`, `#{cycle=60/300:…}`);
    /// cycles default to `max(rotation, interval)`. `0` disables periodic
    /// re-runs entirely (sections run once when the template loads).
    var refreshIntervalSeconds: Double = 5
    /// Single-string status-bar template using tmux-style format markers:
    ///   #[align=left|centre|right]  — switches which alignment region
    ///                                 subsequent text/variables accumulate
    ///                                 into (default: `left`).
    ///   #[fg=…,bold=true]          — inline text styling (passed through
    ///                                 to the renderer).
    ///   #[link=URL]…#[nolink]      — makes the wrapped run clickable; a
    ///                                 click opens URL. URL must be
    ///                                 whitespace/comma-free.
    ///   #{token}                    — template variable (mode, date,
    ///                                 tmux-compatible vars,
    ///                                 plugin:<count>,
    ///                                 plugin:<plugin>.<segment>,
    ///                                 script:<path>, command:<shell>).
    static let defaultTemplateString = "#[align=left]#{mode}#[align=right]#{date}"
    var template: FlashStatusBarTemplate = Self.defaultTemplate
    /// The config file that defined `template`, for resolving relative
    /// `#{script:…}` paths. With layered configs the defining layer may not
    /// be the last file parsed. Not user-facing.
    var templateSourceURL: URL?
    /// What a click on a `#[range=user|<name>]…#[norange]` span does —
    /// tmux's status-line mouse model: the span names an action, the
    /// binding lives outside the string. `[statusbar.click]` values are a
    /// URL string or a `["flash", "<verb>", …]` action array.
    enum ClickAction: Equatable {
      case url(String)
      case command(MappingCommand)
    }
    var clickActions: [String: ClickAction] = Self.defaultClickActions
    /// The bundled system plugin wraps its battery chip in
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
          token: "mode",
          source: .sdk(.modeLabel)),
        FlashStatusBarTemplateVariable(
          id: "statusbar.template.date",
          token: "date",
          source: .sdk(.date)),
      ])
  }
  struct Mode {
    struct Labels: Equatable {
      var normal: String = "NORMAL"
      var insert: String = "INSERT"
      var command: String = "COMMAND"

      var longestCount: Int {
        max(normal.count, insert.count, command.count)
      }
    }

    var all: [ModeMapping] = []
    var normal: [ModeMapping] = Self.defaultNormalMappings
    var insert: [ModeMapping] = []
    var normalLeader: String? = Self.defaultNormalLeader
    /// Keys and modifiers that make an unmapped keypress in NORMAL switch to
    /// INSERT and continue to the focused app or macOS unchanged. Explicit
    /// `[mode.normal.mappings]` and `[mode.all.mappings]` bindings still win.
    var normalPassthroughKeys = Self.defaultNormalPassthroughKeys
    var normalPassthroughModifiers = Self.defaultNormalPassthroughModifiers

    var normalPassthroughKeyCodes: Set<UInt32> {
      Set(normalPassthroughKeys.compactMap(HotkeySyntax.parseKey))
    }

    var labels = Labels()
    /// How long the interpreter waits for the next key in a pending
    /// sequence before resolving the longest matching prefix.
    /// Vim's `timeoutlen`. Lower → faster commits, more two-key
    /// collisions; higher → slower commits, fewer surprises.
    var sequenceTimeoutMs: Int = Self.defaultSequenceTimeoutMs
    /// Pixels per h/j/k/l (and ctrl+e/ctrl+y) scroll step.
    var scrollStep: Int = 60
    /// Fraction of the scrollable range moved by d/u (Vim's `scroll`).
    var scrollPageFraction: Double = 0.5
    /// Mouse-down→up hold on synthesized clicks; some apps need a
    /// non-zero press to register.
    var clickHoldMs: Int = 18
    /// Delay between chords of a multi-key send_key — terminals and
    /// remote-desktop apps drop chords sent back-to-back.
    var sendKeyIntervalMs: Int = 35
    /// Matches Neovim's `timeoutlen` default so multi-key sequences feel the
    /// same as in the editor users already have muscle memory for.
    static let defaultSequenceTimeoutMs = 1000
    static let defaultNormalPassthroughKeys = ["escape"]
    static let defaultNormalPassthroughModifiers = ["cmd", "ctrl", "shift", "alt"]

    /// Single-atom key form, parsed via `NormalModeInterpreter.parseKeySequence`.
    /// Use `\` bare or `<backslash>` — both resolve to the same key.
    static let defaultNormalLeader = "\\"

    static let defaultNormalMappings: [ModeMapping] = makeDefaultNormalMappings()

    private static func makeDefaultNormalMappings() -> [ModeMapping] {
      // Bare punctuation is allowed by the parser; defaults stay
      // concise. Use `<name>` only for keys that can't be typed bare
      // (`<leader>`, `<space>`) or for emphasis on a non-obvious key.
      var raw: [(String, MappingCommand)] = [
        ("h", .flashCommand(.scroll(.left))),
        ("j", sendKeyMapping("down")),
        ("k", sendKeyMapping("up")),
        ("l", .flashCommand(.scroll(.right))),
        ("ctrl+e", .flashCommand(.scroll(.down))),
        ("ctrl+y", .flashCommand(.scroll(.up))),
        ("ctrl+d", .flashCommand(.scroll(.halfPageDown))),
        ("ctrl+u", .flashCommand(.scroll(.halfPageUp))),
        // Vimium parity: bare `d` / `u` scroll a half page (the `ctrl+`
        // forms above stay as vim-style aliases). `d` is kept free of any
        // hint-mode prefix — double-click hints live on the `D` prefix
        // below — so the bare keystroke resolves instantly with no
        // sequence-timeout wait, the same reason right-click moved `r`→`s`.
        ("d", .flashCommand(.scroll(.halfPageDown))),
        ("u", .flashCommand(.scroll(.halfPageUp))),
        ("gg", .flashCommand(.scroll(.top))),
        ("G", .flashCommand(.scroll(.bottom))),
        // Vimium `H` / `L` — back / forward in history. (Lowercase
        // `h` / `l` scroll left / right, matching Vimium too.) `[h`/`]h` alias
        // these below, in the bracket-pair block.
        ("H", .flashCommand(.historyBack)),
        ("L", .flashCommand(.historyForward)),
        // Bracket-pair navigation borrows tpope/vim-unimpaired's `[X` =
        // previous, `]X` = next convention so muscle memory transfers
        // straight from Vim. Multi-letter aliases live alongside the
        // primary binding so users coming from `vim-unimpaired` find
        // their letters AND desktop users find an intuitive abbreviation.
        ("[t", .flashCommand(.tabPrev)),
        ("]t", .flashCommand(.tabNext)),
        // `[h`/`]h` — back / forward in history, the unimpaired-style alias for
        // `H`/`L`.
        ("[h", .flashCommand(.historyBack)),
        ("]h", .flashCommand(.historyForward)),
        // `]b` — Vim "buffer next". In a desktop context the closest
        // analogue is the next browser/terminal tab, so this aliases `]t`.
        ("]b", .flashCommand(.tabNext)),
        // `[B`/`]B` — Vim first/last buffer. Aliases `g^`/`g$` (tab
        // first/last).
        ("[B", .flashCommand(.tabFirst)),
        ("]B", .flashCommand(.tabLast)),
        // Move (reorder) the current tab. `m` for "move" stays as the
        // primary form because it's the desktop-intuitive abbreviation;
        // `[e`/`]e` (Vim "exchange") is the unimpaired-style alias.
        ("[m", .flashCommand(.tabMovePrev)),
        ("]m", .flashCommand(.tabMoveNext)),
        ("[e", .flashCommand(.tabMovePrev)),
        ("]e", .flashCommand(.tabMoveNext)),
        ("[a", .flashCommand(.appPrev)),
        ("]a", .flashCommand(.appNext)),
        // `[w`/`]w` — Vim's `:wprev`/`:wnext`: cycle the FOCUSED APP's windows
        // via the native macOS ⌘` / ⌘⇧` shortcuts, sent to the app so it works
        // wherever macOS window cycling does.
        ("[w", sendKeyMapping("cmd+shift+`")),
        ("]w", sendKeyMapping("cmd+`")),
        // Reopen the most recently closed tab. Vimium binds this to `X`
        // ("restore"); ⌘⇧T is the cross-browser standard the host
        // keystroke fallback delivers for any non-terminal app, and
        // terminals (no close-tab history) return `.unhandled`.
        ("X", .flashCommand(.tabReopen)),
        // No default ⌘-based bindings: the system/browser ⌘ chords
        // (⌘tab, ⌘1–9, ⌘R, ⌘[ / ⌘], ⌘⇧[ / ⌘⇧], ⌘T, ⌘W, ⌘N, ⌘F) are left to the
        // OS / focused app. Their vim-style siblings cover the same actions in
        // normal mode (`gt`/`gT`, `g1`–`g9`, `r`/`R`, `H`/`L`, `[t`/`]t`, `t`,
        // `x`, `/`, `[a`/`]a`).
        //
        // ⌃Tab / ⌃⇧Tab → next / previous tab — browser-native chords shadowed
        // in normal mode (scope-bound Carbon; insert mode releases them so the
        // focused app sees the native chord again).
        ("ctrl+tab", .flashCommand(.tabNext)),
        ("ctrl+shift+tab", .flashCommand(.tabPrev)),
        // First / last tab. Vim-style `g^` / `g$` borrowed from
        // line-extreme motions: `^` is the first non-blank, `$` is the
        // end of line. Browsers translate to ⌘1 / ⌘9 (the cross-vendor
        // convention for first / last tab); plugin sources receive the
        // `tab_first` / `tab_last` source action.
        ("g^", .flashCommand(.tabFirst)),
        ("g$", .flashCommand(.tabLast)),
        // Vimium `g0` — first tab (alias of `g^`).
        ("g0", .flashCommand(.tabFirst)),
        ("g1", .flashCommand(.tabSelect(index: 1))),
        ("g2", .flashCommand(.tabSelect(index: 2))),
        ("g3", .flashCommand(.tabSelect(index: 3))),
        ("g4", .flashCommand(.tabSelect(index: 4))),
        ("g5", .flashCommand(.tabSelect(index: 5))),
        ("g6", .flashCommand(.tabSelect(index: 6))),
        ("g7", .flashCommand(.tabSelect(index: 7))),
        ("g8", .flashCommand(.tabSelect(index: 8))),
        ("g9", .flashCommand(.tabSelect(index: 9))),
        ("ctrl+o", .flashCommand(.movementBack)),
        ("ctrl+i", .flashCommand(.movementForward)),
        ("gt", .flashCommand(.tabNext)),
        ("gT", .flashCommand(.tabPrev)),
        // Vimium `J` / `K` — one tab left (prev) / right (next), the
        // capital-letter siblings of `gT` / `gt`.
        ("J", .flashCommand(.tabPrev)),
        ("K", .flashCommand(.tabNext)),
        ("a", .flashCommand(.insertMode)),
        ("A", .flashCommand(.insertMode)),
        ("i", .flashCommand(.insertMode)),
        ("I", .flashCommand(.lockedInsertMode)),
        ("o", .flashCommand(.insertMode)),
        ("O", .flashCommand(.insertMode)),
        ("f", .flashCommand(.mouseTarget(.click(.leftClick, modifiers: [])))),
        // `F` requests the new-context link gesture. Firefox links add Command
        // to `f`, terminal links add Shift, and non-link targets stay plain.
        (
          "F",
          .flashCommand(.mouseTarget(.click(.leftClick, modifiers: [.command, .shift])))
        ),
        // Ctrl moves the same current/new-tab pair onto the precision grid.
        ("ctrl+f", .flashCommand(.mouseGrid(.click(.leftClick, modifiers: [])))),
        (
          "ctrl+shift+f",
          .flashCommand(.mouseGrid(.click(.leftClick, modifiers: [.command, .shift])))
        ),
        // `s` for "secondary click" (right-click). `r` was the old
        // prefix but it collided with the `r`→`R` reload pair: typing
        // `r` waited the full sequence-timeout before resolving as
        // reload, because right-click hint sequences also began with `r`.
        // `s` has no such pair so the keystroke fires instantly.
        ("sf", .flashCommand(.mouseTarget(.click(.rightClick, modifiers: [])))),
        // Double-click hints. `D` ("Double") rather than the natural `d`
        // prefix so the bare `d` half-page scroll above stays instant.
        ("Df", .flashCommand(.mouseTarget(.click(.doubleClick, modifiers: [])))),
        ("mf", .flashCommand(.mouseTarget(.move))),
        ("sF", .flashCommand(.mouseGrid(.click(.rightClick, modifiers: [])))),
        ("DF", .flashCommand(.mouseGrid(.click(.doubleClick, modifiers: [])))),
        ("mF", .flashCommand(.mouseGrid(.move))),
        // Undo lives on `u` in Vim, but Vimium reuses `u` for half-page
        // scroll-up (mapped above). Undo stays reachable via `:undo` /
        // `:u` and the app's native ⌘Z in insert mode.
        ("ctrl+r", .flashCommand(.redo)),
        ("e", .flashCommand(.archive)),
        // `x` sends the app's own close chord instead of a Flash-side
        // "smart close": every app already decides what ⌘W means (a
        // browser closes the tab, a terminal's own keybinding can route
        // it to a confirmed tmux kill-pane, …). Avoiding behavior
        // overrides keeps Flash predictable — the user's per-app
        // configuration stays the authority.
        ("x", sendKeyMapping("cmd+w")),
        // Vimium `n` / `N` cycle find matches. Flash drives the focused
        // app's native find-again (⌘G / ⌘⇧G) after `/` opens find. New
        // windows stay on ⌘N (below) — `n` is needed for find parity.
        ("n", sendKeyMapping("cmd+g")),
        ("N", sendKeyMapping("cmd+shift+g")),
        // `y` yanks (copies) the current selection; `p` pastes it back.
        // With no register prefix these use the system clipboard — `"ay` /
        // `"ap` route through the named register `a` instead (a-z, 0-9; an
        // uppercase name appends). `y` is a one-key prefix of `yy` below, so a
        // bare `y` commits after the sequence timeout — `yy` (yank URL) fires
        // immediately on the second key.
        ("y", .flashCommand(.yankSelection(register: nil))),
        ("p", .flashCommand(.paste(register: nil))),
        // `yy` yanks the current URL/location (Vimium `yy`).
        ("yy", .flashCommand(.copyURL)),
        ("t", .flashCommand(.tabNew)),
        ("/", .flashCommand(.find)),
        ("<leader><space>", .flashCommand(.enterCommand(input: "flashlight ", restoreMode: false))),
        ("r", .flashCommand(.reload(force: false))),
        ("R", .flashCommand(.reload(force: true))),
        ("?", .flashCommand(.showUsage(topic: nil))),
        (":", .flashCommand(.commandMode)),
      ]
      // Vim-style marks: `m<letter>` sets, `` `<letter> `` jumps.
      // Generated rather than hand-listed so the 52 mappings (26+26)
      // stay in sync if more letter ranges are added later.
      for letter in "abcdefghijklmnopqrstuvwxyz" {
        let l = String(letter)
        raw.append(
          (
            "m\(l)",
            .flashCommand(.pluginVerb(name: "set_mark", args: ["letter": l]))
          ))
        raw.append(
          (
            "`\(l)",
            .flashCommand(.pluginVerb(name: "jump_to_mark", args: ["letter": l]))
          ))
      }
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

    private static func sendKeyMapping(_ keys: String) -> MappingCommand {
      guard let action = parseMappingCommand(argv: ["flash", "send_key", "--keys=\(keys)"]) else {
        preconditionFailure("invalid default send_key mapping: \(keys)")
      }
      return action
    }

    func mappings(for mode: FlashMode) -> [ModeMapping] {
      switch mode {
      case .normal:
        return all + normal
      case .insert:
        return all + insert
      }
    }

    /// O(1)-lookup view used on every keystroke. Refreshed by
    /// `prepareDerivedValues()` after every config load / reload.
    private(set) var compiledNormal = CompiledMappings()
    private(set) var compiledInsert = CompiledMappings()

    mutating func recompileMappings() {
      compiledNormal = CompiledMappings(mappings(for: .normal))
      compiledInsert = CompiledMappings(mappings(for: .insert))
    }

    mutating func refreshLeaderDerivedDefaults() {
      let leaderRaw = normalLeader ?? Self.defaultNormalLeader
      guard let leaderInternal = NormalModeInterpreter.translateLeader(leaderRaw) else { return }
      for index in normal.indices where normal[index].key.contains("<leader>") {
        let mapping = normal[index]
        let resolved = mapping.key.replacingOccurrences(of: "<leader>", with: leaderInternal)
        normal[index] = ModeMapping(
          key: resolved,
          action: mapping.action,
          repeatsOnFinalKey: mapping.repeatsOnFinalKey)
      }
    }

    var containsNormalModeMapping: Bool {
      (all + normal + insert).contains { mapping in
        mapping.action.command == .normalMode
      }
    }

    var containsAdvancedModeMapping: Bool {
      all.contains { mapping in
        mapping.action.command == .normalMode
      }
    }
  }

  var hints = Hints()
  var app = App()
  var overlay = Overlay()
  var open = Open()
  var plugins = Plugins()
  var statusBar = StatusBar()
  var mode = Mode()
  var debug = Debug()
  var flashlight = Flashlight()
  var diagnostics: [ConfigDiagnostic] = []
  /// Plain-string view over `diagnostics`. Existed as a parallel
  /// mutable field; collapsed to a computed projection so the two
  /// can't drift.
  var warnings: [String] { diagnostics.map(\.message) }
  var valueLocations: [String: ConfigLocation] = [:]
  /// Prepared from `hints.keys` by `ConfigLoader` after TOML/env/CLI
  /// precedence has settled. Activation should use this stored value
  /// instead of re-parsing layout selectors.
  private(set) var resolvedAlphabet: Alphabet.Resolved = Alphabet.resolve(Alphabet.defaultKeys)

  static let `default`: Config = {
    var config = Config()
    config.prepareDerivedValues()
    return config
  }()
  static let ambiguousShiftMagicModifierWarningPrefix = "hints.magic_modifiers includes \"shift\""

  mutating func recordLocation(path: String, location: ConfigLocation?) {
    valueLocations[path] = location
  }

  mutating func clearLocation(path: String) {
    valueLocations.removeValue(forKey: path)
  }

  mutating func addDiagnostic(_ message: String, location: ConfigLocation? = nil) {
    diagnostics.append(ConfigDiagnostic(message: message, location: location))
  }

  mutating func removeDiagnostics(where predicate: (String) -> Bool) {
    diagnostics.removeAll { predicate($0.message) }
  }

  mutating func prepareDerivedValues() {
    mode.refreshLeaderDerivedDefaults()
    resolvedAlphabet = Alphabet.resolve(hints.keys)
    removeAmbiguousShiftMagicModifier()
    mode.recompileMappings()
  }

  private mutating func removeAmbiguousShiftMagicModifier() {
    guard resolvedAlphabet.chars.contains(where: { !$0.isLetter }) else {
      removeDiagnostics { $0.hasPrefix(Self.ambiguousShiftMagicModifierWarningPrefix) }
      return
    }
    let original = hints.magicModifiers
    hints.magicModifiers.removeAll { $0.lowercased() == "shift" }
    guard original.count != hints.magicModifiers.count else { return }
    removeDiagnostics { $0.hasPrefix(Self.ambiguousShiftMagicModifierWarningPrefix) }
    addDiagnostic(
      "hints.magic_modifiers includes \"shift\", but resolved hints.keys "
        + "contains non-letter characters (\(String(resolvedAlphabet.chars))); "
        + "removed \"shift\" because shifted-character input is ambiguous",
      location: valueLocations["hints.keys"] ?? valueLocations["hints.magic_modifiers"]
    )
  }

  /// JSON object string of the `[plugin.<id>]` settings for `pluginID`,
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

  var resolvedConfigJSON: String {
    let modeJSON: [String: Any] = [
      "all": mode.all.map(Self.mappingJSONValue),
      "insert": mode.insert.map(Self.mappingJSONValue),
      "labels": [
        "command": mode.labels.command,
        "insert": mode.labels.insert,
        "normal": mode.labels.normal,
      ],
      "normal": mode.normal.map(Self.mappingJSONValue),
      "normal_leader": mode.normalLeader ?? NSNull(),
      "normal_passthrough_keys": mode.normalPassthroughKeys,
      "normal_passthrough_modifiers": mode.normalPassthroughModifiers,
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
      "hints": [
        "keys": hints.keys,
        "magic_modifiers": hints.magicModifiers,
        "min_length": hints.minLength,
        "mouse_grid_opacity": hints.mouseGridOpacity,
        "mouse_grid_steps": hints.mouseGridSteps,
      ],
      "flashlight": [
        "aliases": flashlight.aliases,
        "precedence": flashlight.precedence,
        "precedence_alive_bonus": flashlight.precedenceAliveBonus,
        "suggestion_count": flashlight.suggestionCount,
      ],
      "mode": modeJSON,
      "open": [
        "ignored_apps": open.ignoredApps
      ],
      "overlay": [
        "font_size": overlay.fontSize,
        "hint_bg_bottom": overlay.hintBGBottom,
        "hint_bg_top": overlay.hintBGTop,
        "hint_border": overlay.hintBorder,
        "hint_fg": overlay.hintFG,
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
      "statusbar": [
        "enabled": statusBar.enabled,
        "template": statusBar.template.template,
      ],
      "warnings": warnings,
    ])
  }

  private static func mappingJSONValue(_ mapping: ModeMapping) -> [String: Any] {
    [
      "action": mapping.action.configValue,
      "key": mapping.key,
      "repeat": mapping.repeatsOnFinalKey,
    ]
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
  /// Human-readable form of an in-process verb: `flash <verb> [--k=v ...]`.
  /// Matches the syntax users type into the `flash` CLI and write into
  /// mapping arrays in `flash.toml`. Used for help text, log lines, and
  /// the inspector — never re-parsed.
  var diagnosticDescription: String {
    func verb(_ name: String, _ args: [String] = []) -> String {
      args.isEmpty ? "flash \(name)" : "flash \(name) " + args.joined(separator: " ")
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
    switch self {
    case .mouseTarget(let command):
      return verb("mouse_target", command.argTokens)
    case .mouseGrid(let command):
      return verb("mouse_grid", command.argTokens)
    case .normalMode: return verb("enter_normal_mode")
    case .insertMode: return verb("enter_insert_mode")
    case .lockedInsertMode: return verb("enter_locked_insert_mode")
    case .commandMode: return verb("enter_command_mode")
    case .scroll(let kind):
      switch kind {
      case .left: return verb("scroll_left")
      case .right: return verb("scroll_right")
      case .up: return verb("scroll_up")
      case .down: return verb("scroll_down")
      case .halfPageUp: return verb("scroll_half_page_up")
      case .halfPageDown: return verb("scroll_half_page_down")
      case .top: return verb("scroll_top")
      case .bottom: return verb("scroll_bottom")
      }
    case .reload(let force):
      return force ? verb("app_reload", [flag("force")]) : verb("app_reload")
    case .undo: return verb("app_undo")
    case .redo: return verb("app_redo")
    case .archive: return verb("resource_archive")
    case .resourceNext: return verb("resource_next")
    case .resourcePrevious: return verb("resource_previous")
    case .close: return verb("window_close")
    case .tabClose: return verb("tab_close")
    case .find: return verb("app_find")
    case .candidateFinder(let all):
      return all ? verb("app_open_finder", [flag("all")]) : verb("app_open_finder")
    case .enterCommand(let input, let restoreMode):
      var args = [kv("input", input)]
      if restoreMode { args.append(flag("restore-mode")) }
      return verb("enter_command_mode", args)
    case .copyURL: return verb("url_copy")
    case .yankSelection(let register):
      if let register { return verb("yank_selection", [kv("register", register)]) }
      return verb("yank_selection")
    case .paste(let register):
      if let register { return verb("paste", [kv("register", register)]) }
      return verb("paste")
    case .tabNext: return verb("tab_next")
    case .tabPrev: return verb("tab_previous")
    case .tabFirst: return verb("tab_first")
    case .tabLast: return verb("tab_last")
    case .tabSelect(let index):
      if let index { return verb("tab_select", [kv("index", index)]) }
      return verb("tab_select")
    case .tabMovePrev: return verb("tab_move_previous")
    case .tabMoveNext: return verb("tab_move_next")
    case .tabReopen: return verb("tab_reopen")
    case .paneNext: return verb("pane_next")
    case .panePrev: return verb("pane_previous")
    case .paneSplitVertical: return verb("pane_split_vertical")
    case .paneSplitHorizontal: return verb("pane_split_horizontal")
    case .paneClose: return verb("pane_close")
    case .historyBack: return verb("history_back")
    case .historyForward: return verb("history_forward")
    case .movementBack: return verb("movement_back")
    case .movementForward: return verb("movement_forward")
    case .appPrev: return verb("app_previous")
    case .appNext: return verb("app_next")
    case .quitApp(let force):
      return force ? verb("app_quit", [flag("force")]) : verb("app_quit")
    case .saveAndQuit(let force):
      return force ? verb("app_save_and_quit", [flag("force")]) : verb("app_save_and_quit")
    case .tabNew: return verb("tab_new")
    case .showAlert(let alert): return verb("alert_show", alert.argTokens)
    case .dismissAlert: return verb("alert_dismiss")
    case .showUsage(let topic):
      if let topic, !topic.isEmpty { return verb("help_show", [kv("topic", topic)]) }
      return verb("help_show")
    case .showPlugins: return verb("plugins")
    case .showAbout: return verb("about")
    case .dismissHints: return verb("hints_dismiss")
    case .quit: return verb("quit")
    case .openApp(let name): return verb("app_open", [kv("name", name)])
    case .pluginCommand(let command, let subcommand, let args):
      var tokens = [kv("command", command), kv("subcommand", subcommand)]
      if !args.isEmpty {
        tokens.append(kv("args", args.joined(separator: " ")))
      }
      return verb("plugin_command", tokens)
    case .moveWindow(let params):
      var parts: [String] = []
      if let position = params.position {
        parts.append(kv("position", position.rawValue))
      }
      parts.append(kv("screen", params.screen))
      return verb("window_move", parts)
    case .sendKey(let keys, _, _):
      return verb("send_key", [kv("keys", keys)])
    case .sendKeys(let keys, _, _):
      return verb("send_keys", [kv("keys", keys)])
    case .pluginVerb(let name, let args):
      let tokens = args.keys.sorted().map { key in kv(key, args[key] ?? "") }
      return verb(name, tokens)
    }
  }
}

extension MouseCommand {
  /// Arg tokens for `mouse_target` / `mouse_grid` in diagnostic form.
  /// Empty for a plain left-click, `["--secondary"]` for right-click,
  /// `["--middle"]` for middle-click, `["--double"]` / `["--triple"]` for
  /// multi-clicks, `["--move"]` for cursor-only move, with an optional
  /// `--modifiers=…` suffix for a preset modified click.
  var argTokens: [String] {
    switch self {
    case .move:
      return ["--move"]
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
    case .multi(let action, let modifiers):
      var tokens: [String]
      switch action {
      case .leftClick: tokens = ["--multi"]
      case .rightClick: tokens = ["--multi", "--secondary"]
      case .middleClick: tokens = ["--multi", "--middle"]
      case .doubleClick: tokens = ["--multi", "--double"]
      case .tripleClick: tokens = ["--multi", "--triple"]
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

extension Config {
  static let helpTopic = HelpTopic(
    name: "config",
    title: "Configuration",
    summary: "flash.toml sections, defaults, and live reload.",
    body: """
      # Configuration

      Flash reads `$XDG_CONFIG_HOME/flash/flash.toml`, then
      `~/.config/flash/flash.toml` when XDG is unset. The active file is
      watched and reloaded live.

      User-facing sections are:

      - `[hints]`
      - `[open]`
      - `[plugins]`
      - `[mode]`
      - `[mode.all.mappings]`
      - `[mode.normal]`
      - `[mode.normal.mappings]`
      - `[mode.insert.mappings]`
      - `[debug]`

      Mapping values are argv arrays. `["flash", "<verb>", "k=v", …]`,
      or the same form with a Flash executable path as the head, dispatches
      the verb in-process; any other head is executed as argv with `~`/env
      expansion. Relative argv paths containing `/` resolve from the config
      file location.

      `config.default.toml` is the canonical reference for all accepted keys.
      """)
}
