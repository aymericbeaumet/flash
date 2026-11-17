# Flash and Sensei

[Sensei](https://cindori.com/sensei) from Cindori, the makers of Trim
Enabler, is "The All-in-One Mac System Performance Monitoring Tool": a
dashboard and a status-bar monitor for CPU, GPU, battery health and storage,
with a widget editor and themes; a thermal dashboard of temperature sensors
and fan speeds; S.M.A.R.T. drive health; a disk benchmark; and a set of
maintenance tools that clean junk, caches, logs and large files, uninstall
apps with their leftovers and enable TRIM. It is closed source, $29 a year
or $59 once (with updates through version 2), each for up to three Macs.
Version 2.1.3 shipped in September 2026; it needs macOS 14 or later and
runs on Intel and Apple silicon. Since version 1.6 its privileged work runs
through a LaunchDaemon you approve in System Settings, in place of the older
helper tool.

Flash shares the monitoring half and none of the maintenance half. Its
answer to the tools Sensei bundles is to keep them, or to show a maintained
command-line tool in a popup: Flash cleans nothing and uninstalls nothing.

| | Sensei | Flash |
| --- | --- | --- |
| License, price | Closed; $29/year or $59 once, up to three Macs | MIT, free |
| Platforms | macOS 14+, Intel and Apple silicon | macOS 13+ |
| Permissions | A LaunchDaemon you approve in System Settings | Accessibility; nothing privileged |
| Monitoring | CPU, GPU, battery health, storage; temperatures and fans; S.M.A.R.T. drive health; disk benchmark | CPU and GPU use, load, memory and memory pressure, disks, network, battery health, processes, any command's output |
| Maintenance | Cleaner, large files, uninstaller, TRIM | None; a monitor or a popup can run a cleaning CLI |
| Alerts | Not documented on its product page | Built-in disk, memory, battery and plugin monitors; any threshold; Notification Center with `notify = true` |
| Surfaces | Dashboard window, status-bar monitor with an editor and themes | Flash's own bar, desktop widgets, popups |
| Configuration | In-app editor | One TOML file, live reload, `flash config check` |
| Maintenance | 2.1.3, September 2026 | 1.1.0, October 2026 |

## Where Sensei is stronger

- **Hardware health.** Temperatures, fan speeds and S.M.A.R.T. reports for
  HDDs and SSDs. Flash reads no SMC sensor and no drive health.
- **Maintenance in one window.** Junk and cache cleaning, a large-file
  finder, an uninstaller that removes leftovers, a switch to enable TRIM.
  Flash has none of these and will not grow them.
- **A disk benchmark** for read and write speeds, with one click.
- **A monitor you design visually.** Sensei's editor lays out its
  status-bar widgets with themes; Flash's bar is a template you write.
- **One polished app** for people who would rather not assemble tools.

## Where Flash is stronger

- **Alerts that act.** A threshold on any value raises the centred alert,
  can leave a Notification Center entry, and can run commands: free space
  falling can start a cleanup on its own.
- **Memory pressure, not memory used.** The built-in `memory` monitor reads
  what the kernel does not count as available, so a Mac using its RAM for
  cache stays quiet.
- **Processes from the keyboard.** `@processes` finds one by name and stops
  it after a confirmation; `#{flash.top_cpu}` and `#{flash.top_mem}` show the
  busiest.
- **Free and open source, with no daemon**: Flash's system figures come from
  a sandboxed plugin that spawns no process.

## Flash features you might like

- `:sysinfo cpu`, `:sysinfo memory`, `:sysinfo disks` and `:sysinfo power`
  open each domain's details in a pager.
- btop in a persistent terminal popup as the dashboard, one key or a hover
  away ([btop](btop.md)).
- [Mole](https://github.com/tw93/Mole), a GPL-3.0 command-line cleaner:
  `mo analyze` explores what fills the disk, `mo uninstall` removes an app
  and its files, `mo clean` clears caches, logs and leftovers. Flash shows it
  in a popup or runs `mo clean` from a monitor
  ([running commands](../monitors.md#running-commands)).
- `trash empty`, after a confirmation, on a key.

## Moving from Sensei

| Sensei | Flash |
| --- | --- |
| Dashboard | btop in a terminal popup, the `:sysinfo` pagers |
| Status-bar monitor | `[statusbar] template` with the `sysinfo` labels, meters and sparklines |
| Battery health | `:sysinfo power`, `#{flash.plugin.sysinfo.power_details}` |
| Thermal dashboard, fans | Keep Sensei, or a named source over a sensor CLI ([Macs Fan Control](macs-fan-control.md#moving-from-macs-fan-control) uses macmon) |
| Drive health, S.M.A.R.T. | Keep Sensei |
| Clean, large files | Keep Sensei, or Mole: `mo clean`, `mo analyze` |
| Uninstaller | Keep Sensei, or `mo uninstall` in a terminal popup |
| Disk benchmark, TRIM | Keep Sensei |

```toml
# Mole is yours to install; Flash shows it and runs it.
[popup.mole]
command = ["mo", "analyze"]
size = "90%x85%"

[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.normal.mappings]
"<leader>md" = ["flash", "mode", "terminal", "--name=mole"]

# Below 10 % free on the startup disk, clean caches and logs, at most daily.
[monitors.cleanup]
value = "#{flash.plugin.sysinfo.disks_percent}"
warning = 90
alert = false
timeout = 1800
cooldown = 86400
run = ["mo", "clean"]
```

The built-in `disk` monitor still raises its alert at 90 %; this one only
runs.

## Using both

They coexist: both read, and only Sensei cleans. Pick one place for the
figures. Sensei's monitor lives in the native menu bar, which Flash
auto-hides while its own bar is on, so either keep Flash's bar off and use
Flash for hints, alerts and popups, or move the figures to Flash's bar and
open Sensei for maintenance with `["flash", "app", "open", "--name=Sensei"]`.
Let one tool do the cleaning: Sensei and Mole both clear caches and logs.

*Checked 2026-10-23 against the [Sensei page](https://cindori.com/sensei),
its [store](https://cindori.com/store/sensei) and
[1.6 notes](https://cindori.com/news/sensei-1.6), its
[Homebrew cask](https://formulae.brew.sh/cask/sensei), and the
[Mole README](https://github.com/tw93/Mole).*
