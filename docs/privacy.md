# Privacy and permissions

Flash needs the Accessibility permission and nothing else to show hints and
click. It never reads screen pixels, runs OCR, or records what you type in other
apps, and it sends no analytics or crash reports. It checks GitHub for new
releases of itself, sending nothing but the request
([updates](updates.md); `[app] updates = "off"` stops it). Its
[OpenTelemetry](#opentelemetry) receiver and exporter are both off: nothing
listens for telemetry and nothing reports Flash's own until you configure it,
and then only to the endpoint you name.

This page lists everything else Flash and its bundled plugins may ask for, read,
store, or send. Disable a plugin with `[plugins] disabled = ["<id>"]`, and inspect
running plugins with `:plugins show`.

## At a glance

- **Optional features have their own access.** Browser and Apple-app plugins
  may request Automation to list their data. The screenshot plugin invokes
  macOS `screencapture`, which needs Screen Recording when used. An explicit
  `:sysinfo refresh` may request Location to read the Wi-Fi name. Showing
  the next meeting (`#{flash.calendar.next}`) or running `calendar join`
  requests Calendars. Your own calendar or other commands can request
  permissions too; macOS attributes
  child-process requests to Flash. Releasing a stuck secure-input flag can
  also request Automation of the holding app or System Events. A focused
  password field is left alone.
- **A status link opens only web and mail URLs.** A `#[link]` on the bar or
  in a popup is text a plugin, a source or a program wrote, so Flash hands
  macOS only `http`, `https` and `mailto` URLs, plus the schemes you list in
  `[statusbar] link_schemes`. Anything else is refused: the log records the
  scheme, never the URL, and `flash resident doctor` lists it
  ([status bar](statusbar.md#turn-a-label-into-an-action)).
- **Some plugins use the network:** exchange rates, the search bang list,
  configured feeds, GitHub, AI-provider quotas or explicitly configured remote
  tmux hosts. Quota segments read only while displayed, with what each
  provider's own CLI already stored: Claude Code's access token,
  `codex app-server`, the token in `~/.grok/auth.json`. Tokens go only to
  their provider and are never refreshed or written. Search bangs open the
  site directly rather than through a search engine's redirect. AI chat bangs
  can request System Events Automation to submit a query in the app they
  opened.
- **Flash checks GitHub for its own releases.** A minute after it starts and
  then daily it asks GitHub's releases API for the newest stable release,
  with nothing but a `Flash/<version>` user agent, and downloads a newer one
  to verify and install it ([updates](updates.md)). `[app] updates = "off"`
  stops both; a development build never checks.
- **Everything else stays on this Mac.** Logs live in `~/Library/Logs/Flash/`.
  Command history, ranking data, app marks, plugin caches and clipboard history live in
  `~/Library/Application Support/Flash/`. Clipboard history keeps text,
  images, formatted copies, and file paths, and ignores items marked
  concealed, transient, or auto-generated. Flash's own submitted commands can
  appear in command history and diagnostic logs.
- **The help server is local, and answers only your access token.** It
  listens on loopback and starts when a browser command needs it (or at
  launch if configured), until Flash quits. Every account and program on
  the Mac shares the loopback address, so its live state, logs, clipboard
  entries and configuration answer only a request carrying the access token
  Flash keeps in `~/Library/Application Support/Flash/help-token`, readable
  by your account only: Flash opens the help with it, other accounts and web
  pages never have it, and programs running as you can read it as they can
  read Flash's other files. The page shell and the bundled documentation need
  no token. Do not share a log or runtime export without reviewing its
  contents.
- **The `flash` command talks to Flash over a private socket.** It is a file
  in `~/Library/Application Support/Flash/run/`, a directory only your
  account can enter, never a network port; Flash answers only processes
  running as you, and sandboxed plugins cannot reach it. No Automation
  prompt is involved ([below](#the-flash-command-and-its-socket)).
- **Flash changes no macOS setting of its own accord** beyond the menu bar's
  auto-hide while its status bar is on. The
  [startup commands](#startup-commands) you list run once at each launch, as
  you, and change exactly what those commands change (a `defaults write`, a
  `killall Dock`); the default configuration lists none.
- **Plugins are sandboxed** deny-by-default unless their manifest opts out
  for credentialed or external helper access. The live [plugins](/plugins) page and
  [plugin isolation](#plugin-isolation) show those boundaries;
  `flash resident doctor` checks permissions, and the live [runtime](/state)
  page shows the current permission and input status.

## Permission prompts

| Permission | Asked by | When |
| --- | --- | --- |
| Accessibility | Flash | First launch. Required. |
| Automation: Safari, Chrome, and other Chromium browsers | Flash, for `browsers` | The first time it lists tabs while that browser runs. |
| Automation: the app holding a stuck secure-input flag, and System Events | Flash | The first time a stuck hold is released by blurring a browser or sending its address-bar shortcut. A real password field does not ask. |
| Automation: System Events, Finder | Flash | The first `system restart`, `system shutdown`, `system logout` or `appearance toggle` (System Events), or `trash empty` (Finder). |
| Automation: Shortcuts Events | Flash, for `shortcuts` | The first listing or invocation of a shortcut. |
| Automation: Notes | Flash | The first `@notes` search or `notes refresh` while Notes runs. |
| Reminders | Flash | The first `@reminders` search or `reminders refresh` while Reminders runs. |
| Contacts | Flash | The first `@contacts` search or `contacts refresh` while Contacts runs. |
| Calendars | Flash | The first time a status format (the bar, a text popup, a widget) or a monitor reads a `#{flash.calendar.next…}` value, or the first `calendar join` or `calendar next`. The default configuration reads none. |
| Automation: Spotify, Music, TV, Podcasts | Flash | The first `media status` while that app runs. Flash never asks an app that is not running. |
| Automation: System Events | Flash, for `aiproviders` | Sending Return after a chat bang pre-fills a query, while the opened app remains focused. |
| Notifications | Flash | The first `notify send`, or the first rise of a monitor with `notify = true`. Never at launch; refusing leaves `notify send` failing with a reason. |
| Screen Recording | `screenshot` | The first `:screenshot screen`; macOS `screencapture` takes the picture. |
| Location | `sysinfo` | Only on an explicit `:sysinfo refresh`, to read the Wi-Fi name. |
| Calendars, Reminders or Contacts before Flash asked | A command you configure yourself, such as `icalBuddy` in a status source | The command's first read. Flash itself asks only as above. |

Plugins are child processes of Flash, so macOS attributes their requests to
Flash. So are the commands you configure: a named source
(`[statusbar.sources.<name>]`), a `#()` job in a status format or widget, and
a terminal popup's command. A calendar CLI such as `icalBuddy` reads Calendar through
EventKit, so its first run makes macOS ask whether *Flash* may access your
calendars, and the grant then covers Flash and every command it runs. Deny it
to keep the command from reading Calendar; you can revoke it later in System
Settings › Privacy & Security › Calendars. Granting Flash Calendars for the
next meeting, or Reminders or Contacts for the flashlight, likewise lets those
commands read them. The
[clock and agenda example](examples/widgets/README.md) does this; `khal`,
which reads its own files, does not.

## Network

Flash serves its optional inspector, and its optional OpenTelemetry receiver,
only on loopback; the socket the `flash` command uses is a local file, not a
network port. Remote requests come from configured plugin installation,
plugin-declared host fetches, the OpenTelemetry exporter when you give it an
endpoint, or the plugins and CLI tools listed below. `answers` uses the host's `fetch`, which only reaches URLs
allowlisted in its manifest, so the plugin process itself stays network-denied;
the others make their own requests or run the CLI tools named here.

| Plugin | Destination | When | Default |
| --- | --- | --- | --- |
| Flash (updates) | `api.github.com/repos/aymericbeaumet/flash/releases/latest` (a GET with `If-None-Match` and a `Flash/<version>` user agent); for a newer release, its `Flash-<version>.zip` from `github.com`, which redirects to GitHub's release-asset storage | A minute after launch, then daily, an hour after a failure; on `updates check`, `updates install` and the About window's button | On; `[app] updates = "off"` stops the automatic ones; never for a development build |
| `answers` | `www.ecb.europa.eu` (daily exchange rates) | At start, then every 6 hours | On |
| `feed` | The URL you configure | Every `refresh_interval` | Off until `url` is set |
| `terminals` | Noninteractive SSH to hosts running tmux | Every few seconds | Off: only hosts listed in `[plugins.terminals] ssh_hosts` |
| `searchproviders` list | `duckduckgo.com/bang.js`, DuckDuckGo's public bang list; no query is sent | When the flashlight opens and the cached copy is missing or a week old; after a failure, at most once an hour | On |
| `searchproviders` bangs | The site the bang names, in your browser; DuckDuckGo only for its own searches such as `!i` | When you invoke a search bang; the query is in the URL | On use |
| `aiproviders` quotas | `api.anthropic.com/api/oauth/usage` (Anthropic's usage endpoint, a read-only GET) with the access token Claude Code already stored; Codex's own service through `codex app-server --stdio`; `cli-chat-proxy.grok.com/v1/billing` (Grok's billing endpoint, a read-only GET) with the access token already in Grok's auth file | While the `claude`, `codex` or `grok` segment is observed; a reading is reused for 2 minutes, and a failed fetch waits 5 | Off until quota segments are displayed |
| `aiproviders` chat bangs | The chat provider the bang names (`chatgpt.com`, `claude.ai`, `duck.ai` and `duckduckgo.com`, `chat.mistral.ai`, …; the full list is in [flashlight bangs](flashlight.md#bangs)) in your browser | When you invoke the provider's bang; a nonempty query is put in the URL where the provider takes one, and then Return is sent only while that app remains focused | On use |
| third-party plugins | GitHub (`git clone` of the pinned commit) | When listed in `[plugins] third_party` | Off |
| Flash (exporter) | The OTLP/HTTP `[telemetry.exporter] endpoint` you configure, with the headers you configure | While something new was recorded, at most every `interval` seconds | Off until `endpoint` is set |

## Data stored on your Mac

| Path | Contents |
| --- | --- |
| `~/.config/flash/flash.toml` | Your configuration. What you wrote there, nothing Flash observed: a `[monitors.<name>] usb` filter holds the USB vendor and product ids and product name you authored. |
| `~/Library/Logs/Flash/` | Logs. They never contain keys typed in other apps. Commands Flash's command line cannot run are logged with their text; the `trace` level also logs every submitted command line and AX tree dumps. Each [startup command](#startup-commands) is logged with its text, and one that fails with the end of its output. Lines `logs write` adds carry the text and fields a script gave them, with `user` as their source. |
| Notification Center (kept by macOS) | The notifications `notify send` and monitors with `notify = true` posted: title, subtitle, body, and a click's URL or Flash command, until you dismiss them or `notify clear` removes them. |
| `~/Library/Application Support/Flash/run/flash.sock` | The socket the `flash` command and your scripts reach Flash through, while Flash runs: no data, in a directory only you can enter (mode `0700`), itself `0600`. Flash removes it when it quits and replaces one a crash left. |
| `~/Library/Application Support/Flash/help-token` | The help server's access token: 32 random bytes, created the first time the server starts, readable only by you (mode `0600`). A file anyone else could read is replaced. |
| `~/Library/Application Support/Flash/command-history.json` | The last 200 entries you submitted in Flash's command line, including flashlight queries. |
| `~/Library/Application Support/Flash/tiling.json` | With tiling enabled and `tiling.persist = true` (the default), workspace trees, split weights, display UUIDs, bundle IDs, window numbers, frames, and truncated SHA-256 title hashes used to match windows after restart. No raw window titles; hashes can still reveal predictable titles. Owner-readable only (`0600`). Set `persist = false` to stop saving and remove the file. |
| `~/Library/Application Support/Flash/monitor-runs.json` | When each [monitor](monitors.md#running-commands)'s `run` last started, so its `cooldown` outlives a restart. Nothing the commands printed; their output stays in memory and the log. |
| `~/Library/Application Support/Flash/marks.json` | Up to 36 named app marks (`mark set`): each saved app's process ID and bundle identifier. Flash migrates existing marks from `Plugins/marks/share/` on first launch. |
| `~/Library/Application Support/Flash/clipboard/` | Clipboard history: up to 1000 entries by default (`[clipboard] history_size`, 1–10000), readable only by you. Flash migrates existing history and images from `Plugins/clipboard/share/` on first launch. This is a retention ceiling; Flash cannot recover copies made before it recorded them. The help page loads retained entries in bounded pages. Plain text is kept up to 128 KiB. Formatted HTML is kept up to 64 KiB. One image (PNG, JPEG, GIF, WebP, or a TIFF stored as PNG) is kept up to 4 MiB, including a preview when you copy a single image file of that size. A file copy records up to 20 paths. Each image entry also records its pixel size, read from the image file's header (entries recorded before Flash kept sizes learn theirs once, on launch). Pinned entries carry a pin flag; they count toward the limit but are never trimmed. Items that password managers mark as concealed, transient, or auto-generated are never recorded. Pasting or restoring an entry from the flashlight puts it back on the system clipboard, marked with Flash's own `com.flash.app.clipboard-entry` type holding the entry's id, so the entry moves to the top instead of being recorded again. |
| `~/Library/Application Support/Flash/Plugins/browsers/cache/` | Copies of Chrome's `History` and Firefox's `places.sqlite`, refreshed when the flashlight opens or you leave the browser, at most once a minute and only when the originals changed. They only feed explicit searches such as `@history`, never default results. |
| `~/Library/Application Support/Flash/Plugins/aiproviders/quotas.json` | Each quota's last percentage and reset time, with its fetch and retry times; readable only by you (mode 0600). No credential tokens or raw provider responses are kept here. |
| `~/Library/Application Support/Flash/Plugins/searchproviders/duckduckgo-bangs.tsv` | DuckDuckGo's public bang list: triggers, site names, categories, usage ranks and URL templates. Nothing you typed. |
| `~/Library/Application Support/Flash/Plugins/<id>/` | Each plugin's private data directory (`FLASH_PLUGIN_DATA_DIR`), the only place a sandboxed plugin may write. |
| `~/Library/Application Support/Flash/Plugins/github/<owner>-<repository>-<commit>/` | The checkout of each third-party plugin pinned in `[plugins] third_party`; its install step's output goes to `~/Library/Logs/Flash/plugin-install/`. |
| `~/Library/Application Support/Flash/` (other files) | Ranking data for search results, the single-resident lock and plugin caches, such as exchange rates. |
| `~/Library/Application Support/Flash/Updates/` | `state.json` (GitHub's ETag, the newest release seen with its asset URL and SHA-256, when it was checked, the version downloaded, announced and last installed) and, while one waits, the downloaded release unpacked as `<version>/Flash.app`. After an install the replaced bundle waits here until the new version has started. |
| `~/Library/Preferences/com.flash.app.plist` | One flag, whether Flash hid the native menu bar for its status bar, so that disabling the bar restores only what Flash changed. The hide itself is the global "Automatically hide and show the menu bar" preference. |

`brew uninstall --cask --zap flash` removes these default paths; use
`flash@nightly` instead if that is the cask you installed. Without `--zap`,
your files remain. Custom configuration paths selected through `FLASH_CONFIG`
or `XDG_CONFIG_HOME` are outside the cask's cleanup list and remain for you
to remove separately.

Named yank registers stay in Flash process memory and are exposed to the local
inspector's Clipboard view while Flash runs. The unnamed (`"`) and system
clipboard (`+`) registers read the current macOS pasteboard; they are not
stored as separate register files.

## Data read from other apps

- **Browser tabs** (`browsers`): Safari and Chromium browsers through Apple
  Events. Firefox, which needs no add-on, through its tab strip in the
  Accessibility tree, which Flash walks on the plugin's behalf, and the
  session file Firefox keeps in each installation's default profile under
  `~/Library/Application Support/Firefox` (named by `installs.ini`; every
  profile under `Profiles/` when that file names none):
  `sessionstore-backups/recovery.jsonlz4`, which lists every open window's
  tabs with their URLs and titles. The file is read in place and decoded in
  memory, never copied or stored.
- **Browser history and bookmarks:** local Chrome and Firefox profiles
  (`browsers`).
- **Notes, Reminders, Contacts:** while each app runs, Flash lists the
  titles of its notes (AppleScript run inside Flash, since Notes has no
  framework), of its open reminders with their list names (EventKit), and
  the names on its contact cards (the Contacts framework). It relists one
  when its app launches, when you leave the app, when you run its
  `<app> refresh` command, and when the flashlight opens if the app is focused or
  its list is a minute old; a quit app's rows are dropped. The rows stay in
  Flash's memory, only a flashlight query scoped to them (`@notes`,
  `@reminders`, `@contacts`) shows them, and none of it is
  written to disk. Flash reads none of them before macOS grants it access,
  and asks only when you first scope a query to one or run its refresh
  command; a refused access leaves it empty, without a message.
- **Calendar events:** only while a status format or a monitor reads a
  `#{flash.calendar.next…}` value, and when you run `calendar join` or
  `calendar next`, Flash reads the events of your calendars (all of them, or
  those `[calendar] calendars` names) from now to twice
  `[calendar] lookahead_hours` (48 hours by default) through EventKit, in
  process; never reminders. It keeps each event's title, start and end,
  all-day, declined and cancelled flags, its calendar's title and the
  meeting link found in its URL, location or notes, in memory only: the
  location and notes are scanned for that link and dropped. Nothing is
  written to disk, and the log names only the meeting service, or the link's
  host, that a `calendar join` opened; what a monitor shows of the event is
  on the local inspector's monitors page, like any monitor's value. It
  reads again when the calendar database changes and once a look-ahead has
  passed. Flash reads nothing before macOS grants access; a refusal leaves
  the values empty.
- **Files:** Spotlight file-name queries that Flash runs itself, only for a
  flashlight query scoped to files (`!f` or `@files`).
- **The focused text:** when you run an `input` command, Flash reads the
  focused element's role, its DOM classes and label (which tell a web
  terminal apart) and whether its text can be edited through
  Accessibility. For `h` and `l` in text it also reads the selection, the
  length and the text, to measure the cursor's line. A secure field gives
  only its length: its text is never read. For Vim's motions in
  text (`w`, `b`, `$`, `%`, `t` and the rest of `[mode.text.mappings]`) it
  reads the selection, the length and the text, never a secure field's
  text, and for `H`, `M` and `L` the visible range; `zt`, `zz` and `zb`
  also read the bounds of the caret's character and the frame of its scroll
  area. The motions change only the selection, set to a caret, `zt`, `zz`
  and `zb` only post a scroll, and `p` in text reads where the cursor is
  and the character after it. [VISUAL](visual-mode.md) (`v`,
  `V`) reads the same as the motions, the selection, the length and the
  text, never a secure field's, when it starts and for each motion or
  operator that measures the text; it changes only the selection, through
  `AXSelectedTextRange`, and copies and pastes with the app's own Copy and
  Paste, never by writing text through Accessibility. Flash never deletes,
  changes or inserts text
  ([what Flash does not do with text](vim.md#what-flash-does-not-do-with-text)).
  While it lasts it
  keeps the selection's offsets, never its text, and a named register it
  fills (`"ay`) holds the selected text like any yank. Each
  of these reads happens once per keypress and keeps nothing. After every
  focus change in the focused app, Flash also reads the focused element's
  kind as above, the roles of its first three ancestors and the frame of
  the scroll area around it, so `h` `j` `k` `l` and the page keys know
  whether they move a caret, a list's selection or the page; it keeps only
  that classification and frame, in memory, until the next change. For the
  field you engaged ([engage a field](normal-mode.md#engage-a-field)),
  Flash keeps the element's identity, its app's process ID and a hash, in
  memory only and until the engagement ends, and nothing of its text; the
  debug log notes the engagement with its reason and the app's bundle,
  never the text.
- **Terminals:** tmux through the `tmux` CLI. While one of your clients is attached
  to a local tmux server, the `terminals` plugin keeps one control-mode client of
  its own attached to it, on the session your last-used client shows, to hear
  about session and window changes. It asks for no pane output, never resizes
  a window, never applies `update-environment`, and leaves when your last
  client does. The commands Flash runs on that server — switching windows,
  reading pane text for hints and letter search, listing sessions and
  windows — go through that client too, rather than a new `tmux` process
  each time. tmux counts
  it like any client: `list-clients` shows it with the `control-mode` and
  `no-output` flags, `client-attached` and `client-detached` hooks run for
  it, hooks that follow a command (`after-*`) run in its context, and until
  your next keystroke a tmux command that names no client, run from a script
  outside tmux, may resolve to it.
- **Menu bar and Notification Center:** `mouse menubar` reads the focused
  app's menu titles through Accessibility, and where the status items sit from
  WindowServer geometry. `mouse notifications` reads the banners, alerts and
  Notification Center panel on screen through Accessibility: their roles,
  positions and labels, which can include a notification's text. Both read
  only when you run them, keep what they read for that hint session only, and
  write none of it to disk. While the hints are up, the local inspector's
  state lists them like any other hints.
- **System panels in front of your app:** when you press `f` while
  Notification Center's panel, Control Center, a menu extra's popover,
  Spotlight, a Dock stack, a system agent's dialog or the screenshot toolbar
  sits in front of the app, Flash reads that window's Accessibility tree
  instead (roles, positions and labels, which can include a notification's or
  a widget's text), the same way and for as long as it reads an app's. It
  picks the window from WindowServer metadata alone (owner, level, size). A
  password or Touch ID prompt (SecurityAgent, LocalAuthentication) is never
  read, labelled or clicked.
- **Mission Control:** when you press `f` while Mission Control or App
  Exposé is up, Flash reads that view's part of the Dock's Accessibility tree
  (roles, positions and labels, which include the titles of the windows it
  shows and the names of your desktops), keeps it for that hint session only
  and writes none of it to disk. It knows the view is open from the Dock's
  own reports below, never from the screen.
- **System surfaces:** to make `missioncontrol`, `desktop`, `appwindows`,
  `launchpad`, `notificationcenter` and `controlcenter` show or hide only
  when needed, Flash observes from launch which of the Dock's views is open
  (the notifications the Dock posts as Mission Control, App Exposé or Show
  Desktop opens and closes), and, when you run one, reads whether Notification
  Center, Control Center or Spotlight shows its panel (the kind of their
  windows, nothing in them) and which status item of the menu bar is the
  clock or Control Center, all through Accessibility. Flash keeps only which
  view or panel is open, in memory.
- **Window titles:** for `window switch` and the flashlight's `@windows`, Flash reads every regular app's
  windows through Accessibility (title, whether minimized) and its name and
  icon, and remembers the order you focused windows in. It reads them at
  launch, when the active Space changes and when an app's windows change,
  keeps them in memory only, drops a quit app's, and writes none of it to
  disk.
- **Picture in Picture and Stage Manager:** `mouse target --scope=screen`
  finds players and the Stage Manager strip from WindowServer geometry (which
  app owns a window, its level and bounds, never its contents) and reads
  their controls through Accessibility, like any other hint target. The
  system player and Stage Manager belong to macOS agents
  (`com.apple.PIPAgent`, `com.apple.WindowManager`), whose controls Flash then
  reads too. Nothing is kept past that hint session.
- **Idle time and USB devices:** only while an event monitor or a plugin
  listens to `core:user.idle` / `core:user.active` or `core:usb.*`. For the
  first, Flash reads how many seconds ago the last keyboard, mouse or
  trackpad input happened, never what it was. For the second, IOKit reports
  each USB device connected or removed, and Flash passes on its vendor and
  product ids and product name, never its serial number. Neither is
  written to disk; a monitor's `usb` filter compares them with the ids and
  name you wrote in your configuration.
- **Appearance:** [`[overlay.dark]`](config:overlay.dark) follows whether macOS is in dark mode.
- **AI-provider quotas** (`aiproviders`): only while a quota's status
  segment is observed. The Claude quota reads the OAuth access token and its
  expiry from the credentials Claude Code stored: its login Keychain item
  `Claude Code-credentials`, read through `/usr/bin/security` (macOS may ask
  once to allow it), else `~/.claude/.credentials.json`. It sends that token
  only to Anthropic's usage endpoint, on `curl`'s standard input, never its
  arguments. Flash never writes the item or the file and never uses the
  refresh token; an expired token keeps the last reading until running
  `claude` renews it. The Codex quota runs the installed
  `codex app-server --stdio`, which uses Codex's existing sign-in. The Grok
  quota reads each entry's access token (`key`) and expiry (`expires_at`) in
  `~/.grok/auth.json` (`grok_auth_file`) and sends the latest valid token
  only to Grok's billing endpoint, on `curl`'s standard input, never its
  arguments. Flash never writes that file
  and never uses its refresh token; an expired token keeps the last reading
  until running `grok` renews it. Tokens are never logged or stored. Chat
  bangs and plugin startup alone do not start quota reads. Query URLs opened
  by chat and search bangs can remain in your browser history.
- **Commands you configure:** status sources and `#()` jobs run with your
  login-shell environment and read whatever they read. Flash keeps their
  latest output, and a source's numeric `history`, in memory to draw the bar,
  popups and widgets, and sends none of it anywhere; a popup showing it goes
  through the private pager snapshot described in [popups](popups.md).
  A quota command you configure yourself, such as tokscale, makes its own
  requests independently of the bundled `aiproviders` quota segments, and
  its output is kept like any other source.

## Keyboard

Flash reads keys only while it owns input: a hint overlay, normal mode, or its
command line. A session event tap decides for each key whether Flash swallows
it or passes it to the app as it comes; the tap never holds, stores or logs
keys. A click asks Accessibility nothing about where it landed.
Modified global
hotkeys use the standard macOS hotkey API. Flash does not request Input
Monitoring. While a yank is in flight, Flash briefly compares hardware
key-down, click, drag and scroll event counts to cancel stale selection work.
These transient counters contain no key values and are never logged or persisted.

While a password field has focus, macOS turns on secure input and hides keys
from the tap. Flash respects it: a hint session started then takes Flash's own
key window instead, so the labels you type go to Flash and never to the
password field. `[app] keyboard_layout` reads which input source is selected
and its key layout, to match keys to hint labels; it records neither.

Secure input sometimes stays on after that field is gone, usually because a
browser or a password manager enabled it in the background. Flash polls the
flag (it cannot see keys while the flag is on) and, when the focused element
is not a password field, asks the holding app to release it. A Chromium
browser is told, through AppleScript, to blur the focused element in its open
windows; the script does not read the field. If the flag remains, or the
holder is Firefox or Safari, Flash brings that browser forward and sends the
address-bar shortcut (the letter l with Command) via System Events, then
returns to the app you were in. Any other holding app is activated and then
left, which is what makes a background password manager drop the hold. The
first of these can ask for Automation. Flash does not lock the screen, show a
dialog, or read what you type. The log line names the app's bundle id.

## Startup commands

Flash runs the commands you list in [`[startup] run`](startup.md) once each
time it starts, and again when you run `flash startup run`; the default
configuration lists none. Each runs as you, with your login environment,
outside any sandbox, exactly like the same command in a terminal or a
monitor's `run`: a `defaults write` changes your preferences, `killall Dock`
restarts the Dock, and a command that reaches the network does so on its
own. Flash adds nothing to them and asks for no permission. It keeps the
last 16 KiB of each command's output in memory for `flash startup run`'s
reply, and writes a failed command's output to the log.

Development builds had a `[macos]` section that wrote preferences itself and
kept the values they replaced in
`~/Library/Application Support/Flash/macos-settings.plist`. Flash no longer
reads or writes that file: it holds only those earlier preference values
(`plutil -p` shows them), and you can delete it.

## Screen capture

`[app] hide_from_capture = true` asks macOS to leave every Flash window out
of screenshots, recordings and screen sharing: hints, the grid, the command
line, the flashlight, alerts and the focus border, the status bar, popups,
widgets and About. It is off by default. Flash sets `NSWindow.sharingType` to
`.none`, which Apple documents as a legacy constant and not a way to protect
content from capture. The window server honours it for captures that read
windows one by one; most capture today reads the composed display, below
that level:

| Capture | Flash's windows |
| --- | --- |
| Apps reading the legacy window list (`CGWindowListCreateImage`, built before the macOS 15 SDK) | Left out |
| ⇧⌘3, ⇧⌘4 and `screencapture` stills, `:screenshot` included | Usually left out; not guaranteed, as `screencapture` can also capture through ScreenCaptureKit |
| ⇧⌘5 and QuickTime Player recordings | Shown |
| Zoom, Google Meet in Chrome, Microsoft Teams, FaceTime and OBS on macOS 15 and later | Shown: they capture through ScreenCaptureKit. Some older Zoom capture modes left them out |
| AirPlay mirroring, Sidecar, Screen Sharing (VNC) and Apple Remote Desktop | Shown: they mirror the display |

Turning it on applies at once, and to every window Flash creates later.
Turning it off reaches the windows created from then on: the window server
keeps an open window out of capture once asked (on macOS 26 a later
`.readOnly` reads back as `.none`), so the others show again when Flash
restarts. `[widgets.<name>] hide_from_capture` hides one widget on its own.
The menu-bar bolt and its menu live in macOS's menu bar, and notifications
in Notification Center; neither is covered. The setting needs no permission
and reads or stores nothing.

## The flash command and its socket

`flash <command>` in a terminal, a script or a hotkey daemon reaches the
running Flash through a Unix domain socket,
`~/Library/Application Support/Flash/run/flash.sock`, that only processes
running as you can use: the directory is yours alone (`0700`), the socket
`0600`, and Flash checks each connecting process's user and closes any other
account's, `root` included, before reading a byte. It is never a network
port. Sandboxed plugins are denied it, even those allowed the network, so no
plugin can run commands outside its sandbox through Flash. Nothing asks for
Automation: the socket replaced the Apple Event the CLI used to send, which
needed macOS's consent for each app that ran `flash`. When Flash is not
running, `flash` opens the app it belongs to, in the background, and waits
for the socket ([IPC protocol](ipc-protocol.md)).

`flash resident status` and `flash resident doctor` print the reply in your
terminal as text or, with `--json`, JSON. The reply describes Flash itself: its version, mode, permissions,
key-capture path, input source ID, config path and diagnostic lines, plugin
health, per-app hint counts and timings keyed by bundle ID (kept in memory for
the last 50 activations of the 32 most recent apps, never on disk), and, for
`resident doctor`, the name and process ID of an app holding secure input and whether
Screen Recording is granted. It never contains clipboard
contents, typed keys, window titles or hint targets, and nothing is sent over
a network or written to disk. `flash config check` runs entirely in the
`flash` process and does not contact the resident.

`flash events watch` prints the events a script subscribes to, as they
happen: mode changes, the focused app's name, bundle ID and process ID,
configuration reloads, hint sessions starting and ending (their kind and
label count, never a target, its text or its label), monitor names and
levels (never their values), tiling workspace names, display names, USB
device names and IDs (never a serial number), sleep, the lock screen and the
time. It never carries keys, typed text, clipboard content or window titles,
nor the Accessibility notifications an app posts on every keystroke. Nothing
is kept: an event goes to the scripts subscribed when it happens, and to no
one when none is.

The socket carries every command, and Flash does not ask which of your
programs sent one: a program that can run `flash` as you can make Flash click,
type, read what Accessibility exposes or capture the screen with its
permissions.
[SECURITY.md](https://github.com/aymericbeaumet/flash/blob/main/SECURITY.md#trust-model)
states that trust model and what is in scope for a report.

## Plugin isolation

Plugins are child processes that talk to Flash through JSON lines on stdin and
stdout, and Flash stops them when it quits. Every plugin process runs under a
deny-by-default macOS sandbox profile built from its manifest, unless the
manifest opts out with `"sandbox": false`. A sandboxed plugin may read files
broadly, but never
`~/.ssh`, `~/.aws`, `~/.config/gh`, your Keychains, or another plugin's data;
it writes only to its own data directory, runs no executable but its own (or
the interpreter its manifest names), and reaches the network only when it
declares it. A plugin allowed to open URLs never opens a local file through
Flash (`file:`), so it cannot have a script or an app it wrote run outside its
sandbox.

Three bundled plugins opt out: `screenshot` and `terminals` execute helpers
(the system screenshot utility, tmux and ssh), while `aiproviders` reads the
provider credentials and runs the installed Codex app-server, `security` and
`curl` for quota reads. AppleScript for `browsers`, `shortcuts` and
`aiproviders` runs inside Flash through a declared `apple_events` capability
and `apple_events_targets` allowlist. `browsers` and `shortcuts` remain
sandboxed; no plugin process loads an AppleScript runtime. macOS attributes
Automation prompts to Flash. The RPC accepts only named operations with fixed host templates and escaped
string values; it accepts no script source, shell command or file operation.
Each operation checks its target against the declared app IDs. Chat submission
can send Return only to a supported browser that is still frontmost. Credentials for
AI-provider quotas remain within its explicitly unsandboxed plugin; granting
Apple Events does not grant a sandboxed plugin those credential files or CLI
helpers.

Third-party plugins load only when listed in `[plugins] third_party`, and GitHub
references must pin a full commit SHA. They get the same sandbox: one runs
unsandboxed only when its manifest declares `"sandbox": false`.
`[plugins.<id>] sandbox = false` in your configuration turns any plugin's
sandbox off.

## OpenTelemetry

Both directions are off by default; see [telemetry](telemetry.md).

**Recorded** (`flash metrics record`): a measurement a script gives, with
its name and attributes, kept in memory beside received metrics and sent
only by the exporter you configure.

**Received** (`[telemetry.receiver] enabled = true`): Flash listens on
`127.0.0.1` (port 4318) for OTLP/HTTP metrics, logs and traces that programs
on your Mac send it, such as Claude Code with telemetry enabled. Any account
on the Mac can reach that address; `[telemetry.receiver] token` makes Flash
refuse every sender that does not present it. That data
can name sessions, models, accounts or email addresses, and log records can
carry whatever the sender put in them. Flash keeps it in memory only, never
on disk, bounded by `max_series` series of `max_points` points each,
`max_logs` log records and `max_spans` spans (1000, 60, 1000 and 1000 by
default), evicting the oldest first; turning the receiver off or quitting
Flash forgets it. It reaches your status bar, widgets and monitors through
the `#{flash.otel…}` values you write, and the local inspector's telemetry
page and `/api/telemetry` show it, like the rest of the inspector. The
receiver answers only requests addressed to it on loopback, refuses requests
a web page could send (another origin, form encodings) and sends no CORS
headers. Any program on your Mac can send it data while it runs, and a
received metric can fire a monitor's `run`: `flash resident doctor` warns
when the receiver is on without a token while such a monitor runs commands.

**Exported** (`[telemetry.exporter] endpoint` set): Flash sends its own
telemetry and the metrics `metrics record` recorded (with the names and
attributes you gave them), and nothing it received, to that endpoint. Flash's
own, by default, are
metrics and traces, whose attributes are plugin ids, request methods,
outcomes, the hint surface and app class (`native`, `browser`, `electron`),
the input kind (`key`, `hotkey`, `cli`) and monitor names and values; never
an app's bundle identifier or name, a window title, a key, a hint target's
text, clipboard contents or anything you typed. Resource attributes are the
service name and version, a random per-launch instance id, the process id and
`os.type`; no host or user name. Log records are exported only when
`signals` includes `"logs"`: they are the log file's lines at
`[debug] log_level`, which can name app bundle identifiers and commands
Flash's command line could not run; plugin stderr is never exported. Headers
you configure are sent only to that endpoint (redirects are refused), never
logged, and the inspector shows only their names.

## Local inspector

`:help`, `?`, `:mappings`, `:logs`, `:plugins show`, and `:commands` open
Flash's help and runtime pages in your browser.
Flash serves it on `localhost` (port 4242 by default) from the first such
command until Flash quits, or from launch when
`[debug] http_inspector_enabled = true`. It shows the documentation bundled with
the app (the pages load nothing from the network),
app version and uptime, Accessibility/capture state, the configuration path and
diagnostics, effective mappings for the focused app, logs, plugin state, monitor
values and states, and recent clipboard entries (their kind, one-line preview
and file paths in the state snapshot; the text, formatted HTML and images
through the history and image endpoints below). The help remembers which pages of the documentation this browser has
opened, which of its notices you dismissed, and each page whether its help was left open, in that browser's
`localStorage` only; Flash does not receive any of them. The page keeps the access
token there too, per origin, and sends it with its data requests. A loopback
client holding the token can read
the full retained clipboard history in pages, delete, pin or unpin one entry, or fetch one stored image.
It can also read the configuration file Flash loaded and, on Save, replace
that file. Purge defaults returns text and does not write. The server writes
only that file, and only after the text parses as TOML. Runtime snapshots redact
plugin setting values; the configuration editor returns the complete file,
including any credentials you placed in it. It rejects requests addressed to other host names and sends
no CORS headers, so web pages cannot read it, and prevents other sites from
embedding its pages in a frame. Its runtime data replies are marked
`no-store`, so the browser keeps none of them in its cache; it caches only
the page and the bundled documentation, which carry no data of yours. Other programs on your Mac can read it while
it runs.
