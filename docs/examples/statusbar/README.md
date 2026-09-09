# Resource and calendar popups

The companion [Flash configuration](flash.toml) gives CPU, memory, disk, and
network their own focused interactive views. The right-hand strip stays compact
and emphasizes local hours and minutes beside a quieter weekday and date:

```text
AI CPU MEM DISK NET BAT 73% · Thu Sep 10 00:24
```

**AWAKE** appears at the beginning only while `caffeinate` keeps the Mac awake,
replacing the date prefix while keeping the clock and full calendar available.
The date uses an abbreviated weekday/month and an unpadded day, for example
`Thu Sep 10 00:24` or `Wed Sep 9 14:32`. The strip stays within 47 cells, including
a three-digit battery percentage, leaving room for a 23-cell centred title on a
120-cell display.
**BAT** shows its percentage unless fully charged on AC power, when only the
label remains. CPU, memory, disk, and network measurements live in their
respective popups instead of repeating changing numbers across the strip. AI
usage stays in its existing popup. Missing plugin values leave no extra
separators.

Merge the example into the existing configuration; keep plugin settings,
mappings, and other personal sections. The left and centre sections are shown
for context and need not replace existing choices.

Install `bottom` (`btm`) and `calcurse` using the preferred package manager.
These files were checked with bottom 0.14.7 and calcurse 4.8.2 on macOS.
For example: `brew install bottom calcurse`.

Copy the five `bottom-*.toml` files and the `calcurse/` directory
into `~/.config/flash/status/`, then create `~/.config/flash/status/calcurse/notes/`.
The explicit `working_directory = "."` sets each process's working directory to
the directory containing `flash.toml`. Remaining argv paths pass unchanged to
the program and are interpreted relative to that working directory.
Use the equivalent directory under `$XDG_CONFIG_HOME` when configured.
Calcurse needs the supplied `keys`, `apts`, and `todo` files to avoid first-run
prompts in read-only mode. Its calendar data starts empty and is isolated from
other calendar applications. Automatic saving, reminders, and its daemon are
turned off; the persistent process belongs to Flash.

| Segment | Terminal | Grid | Refresh |
| --- | --- | --- | --- |
| CPU | bottom: CPU history and processes sorted by CPU use | 92 × 22 | 2 seconds |
| MEM | bottom: memory/swap history and processes sorted by memory use | 92 × 22 | 2 seconds |
| DISK | bottom: mounted-volume capacity, free space, and read/write rates | 90 × 16 | 2 seconds |
| NET | bottom: network throughput history, rates, and totals | 84 × 20 | 2 seconds |
| BAT | bottom: battery charge, consumption, state/time remaining, health | 52 × 12 | 5 seconds |
| Date | calcurse: month, ISO weeks, day of year, local clock, empty agenda | 74 × 22 | Live clock |

Each resource owns a persistent terminal, preserving its history and navigation
when another popup opens. The profiles contain only their relevant widgets;
CPU and MEM additionally include a process table for investigating usage. The
entire date/time remains one calendar target.

The disk layout hides macOS support volumes and simulator mounts; root/data
and other mounted disks remain visible. Bottom reports network-interface
bandwidth, not per-process networking. Use `:network` for IP/interface details
and `:cpu`, `:memory`, or `:disks` for the corresponding plugin reports. Memory
usage is not memory pressure. Battery values depend on what macOS supplies.

Hover to preview; click a resource label, **BAT**, the date, or **AGGR** to keep its popup
open and focus the terminal. Existing links retain their click action: the BAT
percentage (or its label when fully charged on AC power) opens Battery Settings
and article titles open the article. Option-click
a linked segment to focus its popup instead. Right-click any popup segment to
keep it open and enter terminal mode; a second right-click keeps it pinned.
Shift-click opens links inside the popup, while Shift-drag selects text. Bottom allows navigation, sorting,
and searching while `read_only` prevents process termination. Calcurse can be
navigated, but changes are discarded because this setup is a read-only preview.

Use `flash terminal_restart --name=cpu` (or `memory`, `disks`, `network`,
`battery`, or `date`) after editing
a TUI's own configuration. Exited processes restart automatically with a
bounded delay, including after a normal quit or a signal. Flash configuration
reload keeps unchanged terminal commands running, preserving graph history and
calendar navigation. Changing the command restarts only that named session.

References: [bottom layouts](https://bottom.pages.dev/stable/configuration/config-file/layout/),
[battery widget](https://bottom.pages.dev/stable/usage/widgets/battery/),
[calcurse manual](https://calcurse.org/files/calcurse.1.html).
