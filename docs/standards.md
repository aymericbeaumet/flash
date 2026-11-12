# Standards

Flash follows one rule for formats and protocols:

- **What Flash defines, it defines once, in one modern standard.** One
  configuration format (TOML), one key notation, one color notation, one
  telemetry protocol. No parallel spelling of the same thing: a second format
  splits examples, documentation and tooling, and every user pays for it.
- **What Flash consumes from other tools, it accepts the way those tools
  already write it.** A status script written for SwiftBar, i3blocks or
  waybar runs unchanged; a tmux status format keeps tmux's color names.
  Tolerance applies to input that already exists elsewhere, never to new
  spellings of Flash's own settings.

This page records each decision: adopted, tolerated as input, rejected, or
waiting for a decision. The checks that keep them true are tests (the
configuration schema, the completion scripts, the command table) rather than
review.

## Configuration

| Standard | Decision | Notes |
| --- | --- | --- |
| [TOML 1.0](https://toml.io/en/v1.0.0) | Adopted, the only format | `flash.toml`; no JSON, YAML or plist configuration. |
| [JSON Schema](https://json-schema.org) (draft-07) | Adopted | `docs/schema/flash.schema.json`, built from the loader's own key tables and the defaults; `flash config schema` prints the running version's ([editor support](configuration.md#editor-support)). `docs/schema/ipc/` describes every message of the [IPC protocol](ipc-protocol.md#schemas), pinned by tests against the messages Flash encodes. |
| [Taplo](https://taplo.tamasfe.dev) `#:schema` directive and `.taplo.toml` | Adopted | The starter config carries the directive; Tombi and Even Better TOML read it too. |
| [XDG Base Directory](https://specifications.freedesktop.org/basedir-spec/latest/) for configuration | Adopted | `$XDG_CONFIG_HOME/flash/flash.toml`, which defaults to `~/.config/flash/flash.toml`: dotfiles stay portable. |
| XDG for data, state and logs | Rejected | Data stays in `~/Library/Application Support/Flash` and logs in `~/Library/Logs/Flash`, where macOS tools (Console, Time Machine exclusions, MDM) expect them. One location each. |
| Environment overrides (`FLASH_<SECTION>_<KEY>`) | Adopted | One naming rule, validated like the file ([environment overrides](configuration.md#environment-overrides)). |

## Command line

| Standard | Decision | Notes |
| --- | --- | --- |
| GNU long options (`--name=value`, `--flag`) | Adopted | The only option syntax, for the CLI, the command line and mappings alike. |
| Exit status 0 / 1 / 2 | Adopted | Ran / failed / not a command, as POSIX utilities use 2 for usage errors. [sysexits](https://man.freebsd.org/cgi/man.cgi?sysexits) is rejected: scripts need three outcomes, not fifteen. |
| [`NO_COLOR`](https://no-color.org) | Holds by construction | The CLI writes no escape sequences, so there is nothing to turn off. Any future color must honor `NO_COLOR` and a non-terminal stdout. |
| Machine-readable output | Adopted where it reports | `--json` on `resident status` and `resident doctor`; `config schema` is JSON. Commands that act report through the exit status and one line of text. |
| Shell completions (zsh, bash, fish) | Adopted | Generated from the command table (`flash cli completion --shell=`), installed by the Homebrew cask. PowerShell is rejected: not a macOS shell. |
| Man page (`man 1 flash`) | Adopted | Generated from the same table (`flash cli manpage`), installed by the cask. |

## Observability

| Standard | Decision | Notes |
| --- | --- | --- |
| [OpenTelemetry](https://opentelemetry.io) OTLP/HTTP (protobuf or JSON) | Adopted | The one telemetry protocol, in and out ([telemetry](telemetry.md)). |
| OpenTelemetry semantic conventions | Adopted for new names | Dotted lowercase names, units in [UCUM](https://ucum.org) (`ms`, `By`), `service.name`. |
| Prometheus / OpenMetrics exposition | Rejected | A second metrics model; an OpenTelemetry Collector already turns OTLP into a Prometheus endpoint. |
| JSON Lines logs | Adopted | `~/Library/Logs/Flash/flash.log`, one object per line ([observability](observability.md)). |

## Status bar and widgets

| Standard | Decision | Notes |
| --- | --- | --- |
| tmux status format | Adopted for templates | `#{…}` values, `#[fg=…]` styles, tmux's color names, so tmux users read it at once ([status format](status-format.md)). |
| SwiftBar / xbar, i3blocks and waybar JSON output | Tolerated as input | `output = "xbar"`, `"i3blocks"`, `"waybar"` on a status source runs those scripts unchanged. |
| [i3bar JSON protocol](https://i3wm.org/docs/i3bar-protocol.html) (streaming) | Not yet | A streaming source would keep a process alive per segment; waybar's one-shot JSON covers the common case. Revisit if a user brings an i3status-style generator. |
| strftime | Adopted | Date and time formats in templates, as tmux and `date(1)` write them. |

## Keys, colors, durations and text

| Standard | Decision | Notes |
| --- | --- | --- |
| Flash's key syntax (`cmd+shift+a`, `<leader>`, `<esc>`) | Adopted, the only notation | Vim's angle names for special keys, `+` for chords ([mapping syntax](mappings.md)). Vim's `<C-a>`, Emacs' `C-a` and Karabiner's JSON are not accepted as second spellings. |
| CSS hex colors (`#RRGGBB`, `#RRGGBBAA`) | Adopted, the only notation in `flash.toml` | `rgb()`, `hsl()` and named colors are rejected for configuration; tmux color names stay valid inside status templates, where they are tmux's own. |
| Durations | Adopted: integer seconds, or `_ms` for milliseconds | One unit per key, named by its suffix. [ISO 8601 durations](https://en.wikipedia.org/wiki/ISO_8601#Durations) (`PT1.5S`) are rejected as harder to read and write in a config file. |
| URLs ([RFC 3986](https://www.rfc-editor.org/rfc/rfc3986)) | Adopted | Links and click actions are URLs opened by macOS. A `#[link]` is text a plugin, a source or a program wrote, so it opens only `http`, `https`, `mailto` and the schemes in `[statusbar] link_schemes` ([status bar](statusbar.md#turn-a-label-into-an-action)); a `[statusbar.click]` URL is the user's own and opens any scheme macOS opens. |
| Emoji data | Unicode names, shortcodes and CLDR keywords | The emojis plugin searches Unicode character names, gemoji-style shortcodes and the English keywords of [CLDR annotations](https://cldr.unicode.org/translation/characters/short-names-and-keywords) (Unicode License v3, a pinned release refreshed by `mise run update:emoji-keywords`). A keyword is searchable where no name or shortcode carries the word already, so the emoji named by a word stays first. Other locales are not adopted. |
| Calendar join links | Tolerated as input | Meeting links are read from the event's URL, location and notes, as Zoom, Meet and Teams write them. |

## System integration

| Standard | Decision | Notes |
| --- | --- | --- |
| `SMAppService` login items | Adopted | The only autostart mechanism ([architecture](architecture.md)). |
| A Unix domain socket speaking NDJSON | Adopted, the only external entry | The resident's IPC socket: every `flash` command and the event stream, versioned, its messages pinned by JSON Schemas ([IPC protocol](ipc-protocol.md)). The kernel names the peer, so it needs no Automation consent and no token. |
| Apple Events as the CLI's transport | Retired | Replaced by the IPC socket: each sending app needed Automation consent, there was no event stream, and a busy or missing resident failed as an opaque `OSStatus`. Apple Events stay for what Flash and its plugins send other apps. |
| Native notifications (`UNUserNotificationCenter`) | Adopted | Any notification Flash posts goes through the system's notification center, never a homemade one. |
| Shortcuts / App Intents | Rejected | A second external entry point beside the IPC socket, which hard constraint 4 keeps to one. Shortcuts reach Flash through the `flash` CLI in a Run Shell Script action ([below](#shortcuts)). |
| AppleScript dictionary (`sdef`) | Rejected | The CLI already exposes every command; a scripting dictionary would be a second command surface to keep in sync. |

## Plugins

| Standard | Decision | Notes |
| --- | --- | --- |
| NDJSON over stdio | Adopted | One JSON object per line, stdin EOF for shutdown ([plugin protocol](plugin-protocol.md)). |
| JSON-RPC 2.0 framing | Rejected | Flash's messages look like JSON-RPC (`id`, `method`, `params`) but reply `{"ok": …}`; aligning would rewrite every message across the host, the Rust SDK and every bundled plugin, with no compatibility path and nothing a user gains. |
| JSON Schema for `manifest.json` | Candidate | Would give plugin authors the same editor checks `flash.toml` has; generated from the manifest decoder like the configuration schema. |
| [SPDX](https://spdx.org/licenses/) license identifiers | Adopted | `license = "MIT"` in every crate. |

## Repository and releases

| Standard | Decision | Notes |
| --- | --- | --- |
| [Semantic Versioning](https://semver.org) | Adopted | Release tags and `CFBundleShortVersionString`. |
| [Conventional Commits](https://www.conventionalcommits.org) | Adopted | Every commit message. |
| [Keep a Changelog](https://keepachangelog.com) | Adopted in spirit | `CHANGELOG.md` keeps an Unreleased section and one section per version, newest first; its upgrade notes come first because a rename without them breaks configurations. |
| [EditorConfig](https://editorconfig.org) | Adopted | `.editorconfig` states each language's indentation; the formatters (swift-format, rustfmt) remain the authority. |
| Homebrew cask conventions | Adopted | `auto_updates`, `zap`, `manpage` and `*_completion` stanzas. |

## Shortcuts

Flash has no App Intents: they would be a second external entry point
beside the IPC socket, and hard constraint 4 keeps that to one. A Shortcut
runs the `flash` CLI in a **Run Shell Script** action instead, which reaches
the same socket as any other program running as you:

```sh
# Run Shell Script, shell: /bin/zsh
# Homebrew links flash; a download leaves it inside the app.
flash mode flashlight
# or, without Homebrew:
/Applications/Flash.app/Contents/MacOS/flash window move --position=maximized
```

Every command, query and the event stream are available this way, with the
CLI's exit status as the action's ([commands](commands.md)). Siri and
Spotlight reach the Shortcut, so they reach Flash too.
