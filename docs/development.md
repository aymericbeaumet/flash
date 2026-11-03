# Development

The `flash` executable is both the resident app and its CLI. CLI commands
arrive over the resident's Unix domain socket ([IPC protocol](ipc-protocol.md));
native mappings dispatch the same command definitions in process. The host owns discovery, overlays and committed mouse
events. Plugins are managed children communicating through JSON lines on
stdin and stdout.

The maintained contracts:

- [Architecture](architecture.md): ownership, coordinates and deterministic hints.
- [Prepared model](prepared-model.md): cache validity and refresh scheduling.
- [Normal mode](normal-mode.md): input routing, latency and mode transitions.
- [Plugin cookbook](plugin-cookbook.md): build a small plugin.
- [Protocol](plugin-protocol.md) and [Rust SDK](plugin-rust-sdk.md): wire contract and SDK examples.
- [IPC protocol](ipc-protocol.md): the socket the CLI and scripts speak, and its JSON Schemas.
- [Plugin performance](plugin-performance.md): subprocess, scheduling and resource guidance.
- [Contributor guide](https://github.com/aymericbeaumet/flash/blob/main/AGENTS.md): repository constraints and required checks.

The live [runtime](/state), [plugins](/plugins) and [logs](/logs) pages
describe the installed process; the loopback server also exposes
`/api/state`, `/api/logs`, `/api/traces` and the `/api/events` stream
([observability](observability.md)), to requests carrying the access token in
`~/Library/Application Support/Flash/help-token` as
`Authorization: Bearer <token>` ([routes](help-internals.md#routes-and-ownership)). `flash resident status` and
`flash resident doctor` return local CLI diagnostics over the same socket,
and `flash events watch` streams the host events. A plugin's help belongs in its manifest; everything else Flash
documents is this documentation.

## Build from source

Development is verified on macOS 26 with Xcode 26.6 and mise; the built app
targets macOS 13+ ([the macOS floor](release.md#the-macos-floor)). mise is
the single developer environment: the repository's
`mise.toml` pins Python, Rust with rustfmt and clippy, Node, pnpm, Zig and
cargo-about, sets the shared environment, and defines every entry point as a
task. `mise run <task>` runs a task from the repository root with the pinned
tools first on PATH, whatever the shell's PATH holds, so a different Zig or
Node installed elsewhere never leaks into a build. `mise tasks ls` lists the
tasks; arguments follow `--`.

Every task works on its own from a fresh checkout: it installs the pinned
tools it is missing (`mise.toml` turns task auto-install on, even where a
global mise configuration turned it off) and runs the tasks and builds it
depends on. Outside mise, a build needs only Xcode; the browser fixtures also
need Firefox.

```bash
git clone https://github.com/aymericbeaumet/flash.git
cd flash
mise trust
mise run install:dev
```

Before the first build: install Xcode (the Swift toolchain and `swift
format` come from it; Xcode 26.6 is the verified version, older ones are
untested) and [mise](https://mise.jdx.dev). A task downloads the pinned
tools it needs (Python, Rust, Node, pnpm, Zig, cargo-about) on first use; the
first build compiles libghostty-vt from Ghostty's pinned revision with Zig,
which takes several minutes and keeps a few hundred megabytes of sources and
per-architecture outputs under `build/ghostty`. Plugin crates build into
`build/plugin-target`. Nothing is installed outside the checkout and mise's
own tool directory. `mise run setup` does both ahead of time.

The installer builds and signs the app, installs it as
`/Applications/Flash 🧪.app`, starts the resident process, and walks through
the one-time Accessibility grant.
`mise run install:release` installs a clean universal build as
`/Applications/Flash.app` instead; it is never for development.

## Tasks

The implementations live in `Scripts/`; call the task, not the script. There
is no Makefile, justfile, Taskfile or wrapper script: a new entry point is a
task in `mise.toml` with a description, and the guardrails reject anything
else.

| Task | Runs | When |
| --- | --- | --- |
| `setup` | `mise install`, then `build:ghostty` | Optional: fetch every tool and build libghostty-vt ahead of time |
| `check` | `fmt`, `lint`, `guardrails`, `test:plugins`, `test`, in order | Before every commit: the required checks |
| `fmt` | `swift format format --in-place` over `Sources`, `Tests` and `Package.swift` | Format Swift sources |
| `lint` | `swift format lint --strict` over the same paths | Lint Swift sources |
| `guardrails` | `Scripts/check-guardrails.sh` | The hard-constraint guardrails, this environment's rules included |
| `test` | `swift test`, after `build:ghostty` and `build:plugins` | The Swift suite against real plugin binaries; `-- --filter <name>` narrows it |
| `test:plugins` | `Scripts/test-plugins.sh` | The plugin gate; `-- --lane lint`, `units`, `build` or `all` (the default) |
| `test:plugin` | `cargo test --workspace --locked` in `Plugins/<id>` | One crate while iterating: `mise run test:plugin terminals` |
| `test:inspector` | `pnpm check` and `node --test *.test.ts` in `Inspector/` | Help UI changes |
| `test:status-format` | `Scripts/test-status-format-oracle.py`, after `build:tmux-oracle` | Status-language changes; `-- --record` updates the corpus |
| `test:integration` | `test:integration:native`, `:browser`, `:electron`, in turn | Hint discovery or commit changes |
| `test:integration:native` | `Scripts/test-integration-native.sh`, after `install:dev` | AppKit fixture: real host clicks |
| `test:integration:browser` | `Scripts/test-integration-browser.sh`, after `install:dev` | Firefox fixtures: AX targets against reference DOM markers |
| `test:integration:electron` | `Scripts/test-integration-electron.sh`, after `install:dev` | Electron fixture: real host clicks |
| `test:ghostty` | `Scripts/test-build-ghostty.sh` | Ghostty pin changes: a cold bootstrap in a tagged repository |
| `test:app-bundle` | `Scripts/test-app-bundle.py` | Release bundle validator changes |
| `test:notices` | `Scripts/test-third-party-notices.py`, `Scripts/test-ghostty-notices.py` | Notice inventory changes |
| `test:publish` | `Scripts/test-publish-github-release.sh` | Release publication changes |
| `test:cask` | `Scripts/test-update-homebrew-cask.sh` | Homebrew cask changes |
| `test:hints-summary` | `Scripts/test-hints-latency-summary.py` | Latency parser changes |
| `test:log-summary` | `Scripts/test-log-summary.py` | Log summary changes |
| `build` | `swift build`, after `build:ghostty` | A debug build of the package, with the resident's modules optimized (`optimizedInDebug` in `Package.swift`) |
| `build:ghostty` | `Scripts/build-ghostty.sh` | libghostty-vt for this Mac; `-- --release` builds it universal |
| `build:plugins` | `Scripts/build-plugins.sh dev` | Dev plugin binaries; `-- <id>` builds only that plugin |
| `build:inspector` | `Scripts/build-inspector.sh` | Frontend edits: rebuild the committed `inspector.html` |
| `build:schema` | `ConfigSchemaTests` with `FLASH_WRITE_SCHEMA=1` | Config key or default changes: rewrite the committed `docs/schema/flash.schema.json` |
| `build:site` | `Scripts/build-site.sh` | Docs changes: the published documentation and its link check |
| `build:tmux-oracle` | `Scripts/build-tmux-oracle.sh` | The pinned tmux the status-format tests compare against |
| `build:release` | `Scripts/build.sh --release` | The universal release package, as CI builds it |
| `install:dev` | `Scripts/install.sh --dev` | Deploy every verified iteration |
| `install:release` | `Scripts/install.sh --release` | A clean universal release install; never for development |
| `install:fixture-collector` | `Scripts/install-firefox-fixture-collector.sh` | Collecting browser fixtures from Firefox |
| `bench:hints` | `Scripts/benchmark-hints.sh`, after `install:dev` | Hint latency per app class ([performance](performance.md)) |
| `bench:hints-summary` | `Scripts/hints-latency-summary.py` | Latency from any log: `-- --by-bundle ~/Library/Logs/Flash/flash.log*` |
| `bench:log-summary` | `Scripts/log-summary.py` | The first step of performance work: every distribution an audit reads, from the resident's logs ([performance](performance.md#start-with-the-log)) |
| `bench:plugins` | `Scripts/benchmark-plugins.py --build` | Plugin startup, ping, RSS and threads ([plugin performance](plugin-performance.md)) |
| `bench:footprint` | `Scripts/measure-footprint.sh` | The resident's CPU, wakeups and memory before and after a change |
| `bench:cli` | `Scripts/benchmark-cli.py` | The installed `flash` CLI's start-up and its round trip to the running resident over the socket ([performance](performance.md#cli-round-trip)) |
| `bench:help` | `Scripts/benchmark-help.mjs` | The browser help against the running resident: server replies, then load, navigation, typing and stream cost in headless Chrome ([performance](performance.md#browser-help)) |
| `generate:otlp` | `Scripts/generate-otlp.sh`, with the pinned `protoc` | Regenerate `Sources/FlashOTLP` after an OTLP pin change |
| `update:bangs` | `Scripts/update-bangs.sh` | Refresh the vendored Kagi bang list |
| `update:emoji-keywords` | `Scripts/update-emoji-keywords.sh` | Refresh the vendored CLDR emoji keywords |
| `new:plugin` | `Scripts/new-plugin.sh` | Scaffold a bundled Rust plugin |
| `release:publish` | `Scripts/publish-github-release.sh` | CI only: publish the release and its archive |
| `release:cask` | `Scripts/update-homebrew-cask.sh` | CI only: update the Homebrew cask |

`mise.toml`'s `[env]` points every Cargo build at the shared
`build/plugin-target`, outside the plugin trees the dev resident watches, and
quiets pnpm's update notice. `test` sets `FLASH_REQUIRE_PLUGIN_BINARIES=1`, so
an unbuilt plugin fails the suite instead of skipping it; `test:status-format`
sets `FLASH_REQUIRE_TMUX_ORACLE=1`. CI also requires the oracle in its Swift
suite, and sets `MISE_TASK_RUN_AUTO_INSTALL=false` so each job uses exactly
the tools its `jdx/mise-action` step installs. Every workflow action is
pinned to a full commit with its release in a comment
(`uses: actions/checkout@<sha> # v7.0.1`); the guardrails reject a tag or a
branch.

## Verification

Run the required checks, then install the real app before manual UI verification:

```bash
mise run check                     # fmt, lint, guardrails, plugin gate, Swift suite
mise run test:status-format        # status-language changes: the pinned tmux oracle
mise run bench:plugins             # startup, ping, RSS, threads
mise run install:dev
```

The Swift suite's status drawing tests compare against the pinned tmux in
`build/tmux-oracle` and skip without it; `mise run build:tmux-oracle` builds it.

`swift test` runs on the same desktop as the installed resident, and many tests
drive real Flash windows that production code orders front. Drawn there, they
covered the focused app: the resident then found its window with no visible
region and showed no hints. `Tests/FlashTests/TestWindowHygiene.swift`,
registered for every run by the `FlashTestsBootstrap` image constructor, makes
every window the suite orders in fully transparent — WindowServer neither draws
nor hit-tests it, and Flash ignores it as an occluder and as the window under
the pointer — and fails any test that leaves a suite window with alpha above
zero over a display. Keep test windows behind it; do not restore their alpha.

Browser, native AppKit, and Electron integration suites are available separately:

```bash
mise run test:integration:browser
mise run test:integration:native
mise run test:integration:electron
```

`mise run test:integration` runs all three in turn.

Electron setup installs both the pinned npm package and its binary. The
native oracle drives the resident through the installed `flash` CLI, over the
socket; it needs no Automation permission. Its direct clicks wait for fixture
activation, clear inherited keyboard modifiers, and set an explicit click count.
The activation gate checks the system's focused AX element PID. Polling
[`NSRunningApplication.isActive`](https://developer.apple.com/documentation/appkit/nsrunningapplication)
from a blocking sleep loop can keep returning a cached value until the main run
loop turns. Before probing the status item, the oracle clicks the known search
field outside the context menu and waits for the fixture's menu-close callback.
This cleanup is independent of the user's Escape mapping, and the status probe
starts after native menu tracking ends.
Menu-bar reveal reaches the exact display edge (Quartz y=0 on the primary),
then follows the warp with a real mouse-moved event before waiting for an
onscreen AX frame. A warp alone does not trigger native tracking. Reveal
failures compare retained and freshly acquired AX frames and report the chosen
display and final pointer.

The same fixtures time the installed resident's hint activations (see
[performance](performance.md)):

```bash
mise run bench:hints -- --class=all --runs=30
mise run test:hints-summary   # parser unit tests
```

`flash resident doctor` checks an installed resident's permissions, key capture, config,
hotkeys and plugins; `flash config check --file=<path>` validates a config file
without it.

`swift build` alone does not update the resident app in `/Applications`. CI publishes releases; [release.md](release.md) explains versioning, signing and notarization. The documentation is `docs/`, ordered by `docs/nav.json`: the browser help serves it from the app bundle at `/docs/<page>`, and `mise run build:site` builds the published copy into `build/site` (serve that directory under `/flash/` to preview it). The build fails on a broken link or anchor and on a page missing from the navigation; [browser help internals](help-internals.md#building-the-documentation) covers both copies. See [AGENTS.md](https://github.com/aymericbeaumet/flash/blob/main/AGENTS.md) for the architecture, source contracts, and repository guardrails.

Run `mise run test:inspector` and `mise run build:site` serially within a
worktree: the inspector tests also build the site, and both tasks replace
`Inspector/dist-site`.

`DocsExampleConfigTests` loads every TOML snippet of `README.md`, the install,
getting-started, tiling and calendar guides and the alternatives pages over
`config.default.toml` and fails on a diagnostic. Modes are opt-in, so the same
test requires a page whose snippets bind NORMAL, layer, TEXT, VISUAL or HOLD
keys to turn them on first: the first such snippet, or an earlier one on the
page, carries `[mode.all.mappings]` entries running `mode normal`
(`"cmd+ctrl+["`) and `mode insert` (`"cmd+ctrl+i"`), so a copied snippet
gives working keys. A reference page that would only repeat the shortcut
writes `<!-- modes: assumed on -->` on its own line right before that snippet
instead; the help and the site render an HTML comment as nothing.

CI also runs `mise run test:ghostty`: a real cold bootstrap inside
a temporary repository tagged `1.1.0`. Ghostty's archive sits inside Flash's
repository, so the bootstrap passes an explicit upstream version with its
pinned revision rather than detecting Flash's Git tags. Both the framework
and architecture cache stamps include that version. Keep the version beside
the revision and checksum current when updating the Ghostty pin.
