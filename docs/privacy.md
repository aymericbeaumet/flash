# Privacy and permissions

Flash needs the Accessibility permission and nothing else to show hints and
click. It never reads screen pixels, runs OCR, or records what you type in other
apps, and it has no telemetry, analytics, crash reporting, or update checks.

This page lists everything else Flash and its bundled plugins may ask for, read,
store, or send. Disable a plugin with `[plugins] disabled = ["<id>"]`, and inspect
running plugins with `:plugins`.

## Permission prompts

| Permission | Asked by | When |
| --- | --- | --- |
| Accessibility | Flash | First launch. Required. |
| Automation: Safari, Chrome, and other Chromium browsers | `browsers` | The first time it lists tabs while that browser runs. |
| Automation: Notes, Reminders, Contacts | `apple` | The first time it indexes that app. |
| Screen Recording | `screenshot` | The first `:screenshot`; macOS `screencapture` takes the picture. |
| Location | `network` | Only on an explicit `:network refresh`, to read the Wi-Fi name. |

Plugins are child processes of Flash, so macOS attributes their requests to
Flash.

## Network

Flash's core has no network features. Plugins that reach the network are
listed below. `answers` uses the host's `fetch`, which only reaches URLs
allowlisted in its manifest, so the plugin process itself stays network-denied;
the others make their own requests or run the CLI tools named here.

| Plugin | Destination | When | Default |
| --- | --- | --- | --- |
| `answers` | `www.ecb.europa.eu` (daily exchange rates) | At start, then every 6 hours | On |
| `github` | GitHub, through your `gh` CLI | Every 10 minutes, only if `gh` is installed and signed in | On |
| `feed` | The URL you configure | Every `refresh_interval` | Off until `url` is set |
| `aiproviders` | Anthropic's usage API with Claude Code's token; OpenAI through `codex app-server` | Every 60 seconds while the plugin runs | Starts only when your status bar shows an AI quota segment or you use a chat bang such as `!claude` |
| `tmux` | Noninteractive SSH to hosts running tmux | Every few seconds | Off: only hosts listed in `[plugin.tmux] ssh_hosts` |
| `spotify` | Spotify, through the `spotify_player` CLI | When you use it | On use |
| third-party plugins | GitHub (`git clone` of the pinned commit) | When listed in `[plugins] third_party` | Off |

## Data stored on your Mac

| Path | Contents |
| --- | --- |
| `~/.config/flash/flash.toml` | Your configuration. |
| `~/Library/Logs/Flash/` | Logs. They never contain keys typed in other apps. Commands Flash's command line cannot run are logged with their text; the `trace` level also logs every submitted command line and AX tree dumps. |
| `~/Library/Application Support/Flash/command-history.json` | The last 200 entries you submitted in Flash's command line, including flashlight queries. |
| `~/Library/Application Support/Flash/Plugins/clipboard/` | Clipboard history: the last 50 text items, up to 128 KiB each, readable only by you. Items that password managers mark as concealed, transient, or auto-generated are never recorded. |
| `~/Library/Application Support/Flash/Plugins/history/` | Copies of Chrome's `History` and Firefox's `places.sqlite`, refreshed every 5 minutes. They only feed explicit searches such as `@firefox.history`, never default results. |
| `~/Library/Application Support/Flash/` (other files) | Ranking data for search results and plugin caches, such as exchange rates. |

`brew uninstall --cask --zap flash@nightly` removes all of it.

## Data read from other apps

- **Browser tabs:** Safari and Chromium browsers through Apple Events
  (`browsers`); Firefox through an optional add-on you install yourself
  (`firefox`, see [Firefox extension](firefox-extension.md)).
- **Browser history and bookmarks:** local Chrome and Firefox profiles
  (`history`).
- **Notes, Reminders, Contacts:** through Apple Events (`apple`).
- **Files:** Spotlight queries (`files`).
- **Terminals:** tmux through the `tmux` CLI; kitty through its remote-control
  socket when you enable it in kitty.
- **AI provider quotas:** Claude Code's OAuth token from its Keychain item or
  `~/.claude/.credentials.json`, and the Codex CLI's session (`aiproviders`).
  Flash only reads the Claude token; when it expires, the quota shows as stale
  until Claude Code renews it. Set
  `[plugin.aiproviders] refresh_claude_code_credentials = true` to let Flash
  renew it, which rewrites Claude Code's stored token and can sign Claude Code
  out.

## Keyboard

Flash reads keys only while it owns input: a hint overlay, normal mode, or its
command line. A session event tap decides for each key whether Flash swallows
it or passes it to the app; the tap never stores or logs keys. Modified global
hotkeys use the standard macOS hotkey API. Flash does not request Input
Monitoring.

## Plugin isolation

Plugins are child processes that talk to Flash through JSON lines on stdin and
stdout, and Flash stops them when it quits. Most bundled plugins run under a
deny-by-default macOS sandbox profile declared in their manifest: they can read
their own data directory and the paths and executables they declare, and they
can never read `~/.ssh`, `~/.aws`, `~/.config/gh`, or your Keychains. Six plugins run
unsandboxed because they execute helpers the sandbox forbids: `aiproviders`,
`caffeinate`, `github`, `screenshot`, `shortcuts`, and `tmux`.

Third-party plugins load only when listed in `[plugins] third_party`, and GitHub
references must pin a full commit SHA.

## Local inspector

`:help`, `:logs`, `:plugins`, and `:commands` open a debug page in your browser.
Flash serves it on `localhost` (port 4242 by default) from the first such
command until Flash quits, or from launch when
`[debug] http_inspector_enabled = true`. It shows logs, plugin state, and recent
clipboard entries. It rejects requests addressed to other host names and sends
no CORS headers, so web pages cannot read it, but other programs on your Mac
can while it runs.
