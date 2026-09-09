# System status and calendar popups

The companion [Flash configuration](flash.toml) groups live CPU, memory usage,
and battery charge beside **SYS**, and emphasizes local hours and minutes beside
a quieter day/month. The right-hand strip
reads, for example:

```text
AI  SYS CPU 12% MEM 64% BAT 73% · 09/09 14:32
```

**AWAKE** appears at the beginning only while `caffeinate` keeps the Mac awake,
using the date's space to keep the strip the same width; the clock still opens
the full calendar. The compact right-hand strip stays within 48 cells even with
three-digit percentages, leaving room for a 23-cell centred title on a 120-cell
display.
**BAT** shows its percentage unless fully charged on AC power, when only the
label remains. CPU and memory use their compact summaries; memory reports
occupied capacity, not memory pressure. Disk and network telemetry remain in
the system dashboard and `:disks` / `:network` reports. AI usage stays in its
existing popup. Missing plugin values leave no extra separators.

Merge the example into the existing configuration; keep plugin settings,
mappings, and other personal sections. The left and centre sections are shown
for context and need not replace existing choices.

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

The CPU and MEM values retain their own inline detail popups; **SYS** opens the
combined dashboard. The entire date/time remains one calendar target.

The system layout hides macOS support volumes and simulator mounts; root/data
and other mounted disks remain visible. Bottom reports interface bandwidth,
not per-process networking. Battery values depend on what macOS supplies.

Hover to preview; click **SYS**, **BAT**, the date, or **AGGR** to keep its popup
open and focus the terminal. Existing links retain their click action: the BAT
percentage (or its label when fully charged on AC power) opens Battery Settings
and article titles open the article. Option-click
a linked segment to focus its popup instead. Right-click any popup segment to
keep it open and enter terminal mode; a second right-click keeps it pinned.
Shift-click opens links inside the popup, while Shift-drag selects text. Bottom allows navigation, sorting,
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
