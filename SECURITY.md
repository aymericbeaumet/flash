# Security policy

Flash holds the Accessibility permission, uses one session keyboard event
tap to decide which keys to swallow or pass through, and runs plugins as child
processes. Bugs in those areas deserve a private report.

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/aymericbeaumet/flash/security/advisories/new)
rather than a public issue.
Please include the Flash version (`flash resident status`), macOS version and steps to
reproduce. You will get an acknowledgement within a week.

## Trust model

- **The `flash` command is a full remote control, by design.** `flash
  <command>` runs exactly what `:<command>` runs, through the resident's
  local socket (`~/Library/Application Support/Flash/run/flash.sock`,
  [IPC protocol](docs/ipc-protocol.md)). Any program that can run `flash` as
  you, or connect to that socket as you, can make it click, type, read what
  Accessibility exposes, run a shell command (`flash '!…'`) or capture the
  screen through the screenshot plugin, with Flash's permissions, and can
  watch its event stream. Mappings and `[monitors] run` in your
  configuration file run commands as you too. Guard your account and
  `~/.config/flash` as you would Flash's permissions.
- **The socket answers only your account.** It is a Unix domain socket, never
  a network port, in a directory only you can enter (`0700`), itself `0600`;
  Flash checks every connecting process's user (`getpeereid`) and closes
  another account's, `root` included, before reading it. Sandboxed plugins
  are denied the socket even when they may use the network, so a plugin
  cannot leave its sandbox through Flash. Its event stream never carries
  keys, typed text, clipboard content or window titles.
- **The help server listens on the loopback address only**, once `:help` or
  `[debug] http_inspector_enabled` has started it. Every account and process
  on the Mac shares that address, so its data and every change answer only an
  access token kept in a file only your account can read
  (`~/Library/Application Support/Flash/help-token`): Flash opens the help
  with it, and another account, a system daemon or a web page never has it.
  The server also answers only requests that name its own host and port,
  which defeats DNS rebinding, refuses any change a browser marks as coming
  from another site, and forbids other sites from framing or embedding its
  pages. Programs running as you can read the token, as they can read
  Flash's files.
- **The OTLP receiver** (off by default) also listens on loopback, so any
  account can send it metrics, and a metric can drive a monitor whose `run`
  executes. `[telemetry.receiver] token` makes it refuse every sender
  without that secret; set it before running a command from a received
  metric ([telemetry](docs/telemetry.md#the-receiver)). The receiver stays
  opt-in and the token optional; `flash resident doctor` warns when the
  receiver runs without one while a monitor runs commands from a received
  metric.
- **Updates** come only from this repository's GitHub releases over HTTPS.
  Flash refuses an archive whose SHA-256 differs from the digest GitHub
  publishes, a bundle that is not `com.flash.app` at the release's version or
  fails a strict code-signature check, and any version not newer than the one
  running. A Developer ID build installs only a release signed by the same
  team. Current builds are ad-hoc signed: their updates are authenticated by
  GitHub alone, which is one reason Flash asks before installing one
  ([updates](docs/updates.md)).
- **Plugins** run under a deny-by-default sandbox unless their manifest opts
  out; [plugin isolation](docs/privacy.md#plugin-isolation) lists the bundled
  plugins that do. A sandboxed plugin can ask Flash to open web and app
  links, never a local file, so it cannot have macOS run a script or an app
  it wrote outside its sandbox. A third-party plugin is code you choose to
  run: Flash downloads it only at the full commit you pin.
- **Text other programs control** (window titles, app names, clipboard
  content, feed items, terminal output) is shown as text. It never becomes a
  status-bar style, range or link. A `#[link]` a plugin, a source or a
  program did write opens only `http`, `https` and `mailto` URLs, plus the
  schemes you list in `[statusbar] link_schemes`; a `file:` or custom-scheme
  link is refused, logged by its scheme alone and reported by
  `flash resident doctor`. Terminal popups open only `http` and `https`
  links, through the same door, and ignore clipboard writes; password and
  transient clipboard types never enter the clipboard history.

## In scope

- Keystrokes from other apps reaching a log, a file, a plugin or the network.
- A plugin escaping its declared capabilities or sandbox profile.
- Text from another app or a web page turning into a Flash command, style or
  link.
- A web page, another user account or a sandboxed plugin reaching Flash's
  commands or its event stream, its help server's data, or a change through
  it.
- An update installed without passing the checks above.
- Synthesized input landing in the wrong app or as stray terminal text.
- Flash reading screen pixels by any path. It is designed never to.

A program already running as you that drives Flash through the `flash`
command or its socket is the trust model above, not a vulnerability.

[Trust boundaries](docs/architecture.md#trust-boundaries) maps each of
these to the code that enforces it.
[docs/privacy.md](docs/privacy.md) is the public inventory of permissions,
network destinations and stored data; a discrepancy between that page and the
code is also a bug.

## Supported versions

The latest release and the latest nightly build.
