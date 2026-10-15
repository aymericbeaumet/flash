# Development

## Build from source

Development is verified on macOS 26 with Xcode 26.6 and mise; the built app
targets macOS 14+. The repository's `mise.toml` pins Python, Rust with rustfmt
and clippy, Node, pnpm, uv, and Zig; `mise install` installs those tools.
Xcode, libevent, ncurses, and pkg-config are native macOS build prerequisites
for the tmux oracle.

```bash
git clone https://github.com/aymericbeaumet/flash.git
cd flash
mise install
mise exec -- ./Scripts/install.sh --dev
```

The installer builds and signs the app, installs it as `/Applications/Flash 🧪.app`, starts the resident process, and walks through the one-time Accessibility grant. Use `./Scripts/install.sh --release` for a clean universal build.

## Verification

Run the unit and guardrail suites, then install the real app before manual UI verification:

```bash
mise install
mise exec -- ./Scripts/build-ghostty.sh --dev
export TMUX_ORACLE="$(mise exec -- ./Scripts/build-tmux-oracle.sh)"
mise exec -- swift test
mise exec -- ./Scripts/test-plugins.sh --lane all   # plugin lint + units + dev builds
mise exec -- ./Scripts/benchmark-plugins.py --build # startup, ping, RSS, threads
mise exec -- ./Scripts/check-guardrails.sh
mise exec -- ./Scripts/install.sh --dev
```

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
mise exec -- ./Scripts/test-integration-browser.sh
mise exec -- ./Scripts/test-integration-native.sh
mise exec -- ./Scripts/test-integration-electron.sh
```

Electron setup installs both the pinned npm package and its binary. Native
resident probes also require Automation permission for the signed oracle to
send commands to Flash. The oracle bundle declares that usage; a native
AppleEvent error reports its OSStatus rather than an invalid Flash command.

The same fixtures time the installed resident's hint activations (see
[performance](performance.md)):

```bash
mise exec -- ./Scripts/benchmark-hints.sh --class=all --runs=30
mise exec -- python3 Scripts/test-hints-latency-summary.py   # parser unit tests
```

`flash doctor` checks an installed resident's permissions, key capture, config,
hotkeys and plugins; `flash config_check --file=<path>` validates a config file
without it.

`swift build` alone does not update the resident app in `/Applications`. CI publishes releases; [release.md](release.md) explains versioning, signing and notarization. The manual is `docs/` built by mkdocs (`mkdocs.yml`); preview it with `mise exec -- uv run --locked mkdocs serve` and keep `mkdocs build` free of warnings, since the Docs workflow runs it in strict mode. The committed `uv.lock` pins the docs toolchain. See [AGENTS.md](https://github.com/aymericbeaumet/flash/blob/main/AGENTS.md) for the architecture, source contracts, and repository guardrails.
