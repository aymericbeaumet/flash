# Development

## Build from source

You will need macOS 14+, Xcode command-line tools, mise, Rust, and either pnpm or npm.

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
./Scripts/build-ghostty.sh --dev
export TMUX_ORACLE="$(./Scripts/build-tmux-oracle.sh)"
swift test
./Scripts/test-plugins.sh --lane all   # plugin lint + units + dev builds
./Scripts/benchmark-plugins.py --build # report plugin startup, ping, RSS, and threads
./Scripts/check-guardrails.sh
./Scripts/install.sh --dev
```

Browser, native AppKit, and Electron integration suites are available separately:

```bash
./Scripts/test-integration-browser.sh
./Scripts/test-integration-native.sh
./Scripts/test-integration-electron.sh
```

`swift build` alone does not update the resident app in `/Applications`. See [AGENTS.md](../AGENTS.md) for the architecture, source contracts, and repository guardrails.
