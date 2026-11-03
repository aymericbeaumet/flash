# Contributing to Flash

Thanks for helping. Bug reports, plugins, bar and widget setups, and
documentation fixes are all welcome.
Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## Reporting a bug

Check [troubleshooting](docs/troubleshooting.md) first: it starts with
`flash resident doctor` and ends with the known limitations, which are not
bugs. Then open an [issue](https://github.com/aymericbeaumet/flash/issues/new/choose) with:

- the output of `flash resident doctor` and `flash resident status`;
- the macOS version and CPU architecture (`sw_vers -productVersion`, `uname -m`);
- the app name and version where it happened (`Finder 15.0`, `Firefox 142`);
- the relevant part of `~/.config/flash/flash.toml`;
- for missing or misplaced hints, a screenshot taken with
  `[debug] show_hints_bounds = true`.

If Flash cannot start, include the CLI error and a crash report if macOS
recorded one: find it in Console's Crash Reports or
`~/Library/Logs/DiagnosticReports/`.

Logs live in `~/Library/Logs/Flash/flash.log`. They do not record keys typed in
other apps, but can include submitted command text, paths, URLs and, at trace
level, Accessibility tree dumps. Review logs, configuration and crash reports
before sharing; redact credentials, query text, private URLs and personal paths.
See [privacy](docs/privacy.md) for what each diagnostic can contain.

## Sharing a setup

Send a pull request adding your bar, widget or popup configuration to
[`docs/examples`](docs/examples), with a short README that names every external
tool it runs.

## Changing code

mise is the whole developer environment: `mise.toml` pins the tools and
defines every entry point as a task (`mise tasks ls` lists them).
[docs/development.md](docs/development.md) covers the toolchain, the tasks,
the dev build (`mise run install:dev`), tests and the integration fixtures.
[AGENTS.md](AGENTS.md) is the contributor guide proper: architecture
boundaries, the hard constraints every change must respect, and the required
checks. Read the constraints before proposing a feature; a few requests, such as
screen reading or a second event tap, are declined by design.

Before opening a pull request, run the required checks (format, lint,
guardrails, the plugin gate and the Swift suite):

```sh
mise run check
```

Documentation changes also run `mise run build:site`, which builds the
published manual from `docs/` and fails on a broken link or anchor; a new page
joins `docs/nav.json`.

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).

## Writing a plugin

Plugins are separate programs speaking JSON lines over stdin and stdout, so they
can live in their own repository. Start with the
[plugin cookbook](docs/plugin-cookbook.md) and the
[Rust SDK](docs/plugin-rust-sdk.md). Bundled plugins are reserved for the
glue no external tool provides; if a maintained CLI or TUI already does the
job, Flash shows it in a popup instead.
