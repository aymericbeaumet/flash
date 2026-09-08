# System and calendar popups

The companion [Flash configuration](flash.toml) replaces four resource labels
with **SYS**, keeps the live **BAT** percentage, and turns the date into a
calendar. Merge it into the existing configuration; keep plugin settings,
mappings, and other personal sections.

Install `bottom` (`btm`) and `calcurse` using the preferred package manager.
These files were checked with bottom 0.14.7 and calcurse 4.8.2 on macOS.
For example: `brew install bottom calcurse`.

Copy `bottom-system.toml`, `bottom-battery.toml`, and the `calcurse/` directory
into `~/.config/flash/status/`, then create `~/.config/flash/status/calcurse/notes/`.
The argv paths in `flash.toml` resolve from the directory containing that file.
Use the equivalent directory under `$XDG_CONFIG_HOME` when configured.
Calcurse needs the supplied `keys`, `apts`, and `todo` files to avoid first-run
prompts in read-only mode. Its calendar data starts empty and is isolated from
other calendar applications. Automatic saving, reminders, and its daemon are
turned off; the persistent process belongs to Flash.

| Segment | Terminal | Grid | Refresh |
| --- | --- | --- | --- |
| SYS | bottom: CPU graph and usage, memory/network graphs, disk capacity/I/O, processes | 100 × 28 | 2 seconds |
| BAT | bottom: battery charge, consumption, state/time remaining, health | 52 × 12 | 5 seconds |
| Date | calcurse: month, ISO weeks, day of year, local clock, empty agenda | 74 × 22 | Live clock |

The system layout hides macOS support volumes and simulator mounts; root/data
and other mounted disks remain visible. Bottom reports interface bandwidth,
not per-process networking. Battery values depend on what macOS supplies.

Hover to preview; click **SYS**, **BAT**, the date, or **AGGR** to keep its popup
open and focus the terminal. Existing links retain their click action: the BAT
percentage opens Battery Settings and article titles open the article. Option-click
a linked segment to focus its popup instead. Bottom allows navigation, sorting,
and searching while `read_only` prevents process termination. Calcurse can be
navigated, but changes are discarded because this setup is a read-only preview.

Use `flash terminal_restart --name=system` (or `battery` / `date`) after editing
a TUI's own configuration. Exited processes restart automatically with a
bounded delay, including after a normal quit or a signal. Flash configuration
reload keeps unchanged terminal commands running, preserving graph history and
calendar navigation. Changing the command restarts only that named session.

References: [bottom layouts](https://bottom.pages.dev/stable/configuration/config-file/layout/),
[battery widget](https://bottom.pages.dev/stable/usage/widgets/battery/),
[calcurse manual](https://calcurse.org/files/calcurse.1.html).
