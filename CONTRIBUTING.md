# Contributing to Flash

Thanks for helping. Bug reports, plugins, bar and widget setups, and
documentation fixes are all welcome.

## Reporting a bug

Open an [issue](https://github.com/aymericbeaumet/flash/issues/new/choose) with:

- the output of `flash doctor` and `flash status`;
- the app name and version where it happened (`Finder 15.0`, `Firefox 142`);
- the relevant part of `~/.config/flash/flash.toml`;
- for missing or misplaced hints, a screenshot taken with
  `[debug] show_hints_bounds = true`.

Logs live in `~/Library/Logs/Flash/flash.log`. They never contain keys typed
in other apps, so they are safe to attach; redact anything you consider
personal.

## Sharing a setup

Send a pull request adding your bar, widget or popup configuration to
[`docs/examples`](docs/examples), with a short README that names every external
tool it runs.

## Changing code

[docs/development.md](docs/development.md) covers the toolchain, the dev build
(`Scripts/install.sh --dev`), tests and the integration fixtures.
[AGENTS.md](AGENTS.md) is the contributor guide proper: architecture
boundaries, the hard constraints every change must respect, and the required
checks. Read the constraints before proposing a feature; a few requests, such as
screen reading or a second event tap, are declined by design.

Before opening a pull request:

```sh
swift format lint --strict --recursive Sources Tests Package.swift
./Scripts/check-guardrails.sh
swift test
./Scripts/test-plugins.sh --lane all
```

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).

## Writing a plugin

Plugins are separate programs speaking JSON lines over stdin and stdout, so they
can live in their own repository. Start with the
[plugin cookbook](docs/plugin-cookbook.md) and the
[Rust SDK](docs/plugin-rust-sdk.md). Bundled plugins are reserved for the
glue no external tool provides; if a maintained CLI or TUI already does the
job, Flash shows it in a popup instead.
