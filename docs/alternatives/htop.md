# Flash and htop

[htop](https://github.com/htop-dev/htop) is "a cross-platform interactive
process viewer": a terminal list of every process with its command line,
CPU and memory, meters for the whole system above it, and process tasks
"done without entering their PIDs", from killing to renicing. It is C,
GPL-2.0-or-later, about 8,400 GitHub stars, maintained by the htop-dev
community since 2020, with four releases in 2026, the latest 3.5.3 on
16 August. It runs on Linux, the BSDs, Solaris and macOS; on a Mac
it is one `brew install htop` away, and 3.5.0 added a GPU meter there while
3.5.2 made its used-memory figure match Activity Monitor's.

Flash does not compete with htop. It shows htop in a popup when you want
the list, puts a few figures in its bar for the rest of the day, and raises
an alert when one of them crosses a line.

| | htop | Flash |
| --- | --- | --- |
| License, price | GPL-2.0-or-later, free | MIT, free |
| Platforms | Linux, FreeBSD, OpenBSD, NetBSD, DragonFly, Solaris, macOS | macOS 13+ |
| Permissions | None; `sudo htop` to see every process on macOS, per Homebrew | Accessibility; nothing more for the system figures, which a sandboxed plugin reads |
| Processes | Every process, scrolled sideways for full command lines; tree view, search, filter, sort by any column; kill with any signal, renice, open files (`l`) | `@processes` in the flashlight: every visible process with its pid, CPU and memory share, searched by name; SIGTERM after a confirmation; `#{flash.top_cpu}` and `#{flash.top_mem}` tables |
| System meters | CPU per core, memory, swap, load, tasks, uptime, battery, disk and network I/O, GPU; bars, text, graphs or LEDs | CPU and GPU use, load, memory, disks, network, battery and its health, as bar and widget values with 20-sample charts |
| Alerts | None | `[monitors.<name>]` warning and error thresholds; the centred alert, and a macOS notification with `notify = true` |
| Surfaces | A terminal | Flash's own bar, desktop widgets, popups, including htop itself |
| Configuration | The `F2` setup screen, saved to `~/.config/htop/htoprc` | One TOML file, live reload, `flash config check` |
| Maintenance | 3.5.3, August 2026; active | 1.1.0, October 2026 |

## Where htop is stronger

- **It is the process list.** Full command lines, a tree that shows who
  started what, sorting on any column, a filter that sticks, and every
  signal, not only SIGTERM. Flash's `@processes` finds a process by name
  and stops it; it has no tree, no columns, no renice and no other signal.
- **Per-process detail.** Open files, environment and thread counts are a
  keypress away. Flash shows a process's pid and its shares, nothing more.
- **Meters you arrange.** Two columns of meters in four styles, several
  screens with their own columns, and colour schemes, all from the setup
  screen without editing a file.
- **It goes everywhere.** The same tool and keys on every Linux server you
  log into over SSH, where Flash will never run.

## Where Flash is stronger

- **Always on screen.** CPU, memory and battery in the bar or a desktop
  widget, without a terminal window open.
- **Alerts.** htop shows a runaway process when you look; a Flash monitor
  says so when memory pressure or a disk crosses its threshold, and can run
  a command when it does.
- **htop one key away.** A persistent popup keeps htop running with its
  sort and filter, so a mapped key or hovering the CPU label shows it at
  once.

## Flash features you might like

- `[popup.htop]` with `persistent = true`, and `#[popup=htop]` around the
  bar's CPU and memory labels to show it on hover ([popups](../popups.md)).
- `mode terminal --name=htop` opens it centred and focused; in that
  TERMINAL mode every key, `F9` and Escape included, reaches htop, and
  Command-W hides it ([TERMINAL](../terminal-mode.md)).
- `mode flashlight --query=@processes` to find and stop one process from
  the keyboard without opening htop ([flashlight](../flashlight.md)).
- `#{flash.top_cpu}` in a text popup or a widget: conky's `${top}` table,
  one row per process ([status format](../status-format.md)).

## Moving from htop

Nothing moves; htop moves into a popup.

| htop | Flash |
| --- | --- |
| A terminal tab running htop | `[popup.htop]`, `persistent = true` |
| `sudo htop` for every process | `command = ["sudo", "htop"]` asks for your password in the popup; plain `htop` sees your own processes |
| The CPU and memory meters | `#{flash.plugin.sysinfo.cpu_label}` and `#{flash.plugin.sysinfo.memory_label}` in the bar or a widget |
| `/` to find a process, `k` to kill it | `@processes` in the flashlight: type its name, Return, `y` |
| Sort by CPU or memory | `#{flash.top_cpu}`, `#{flash.top_mem}` |
| Watching for a runaway process | The built-in memory pressure monitor, or `[monitors.<name>]` on a value |
| `htoprc` settings | Stay in `htoprc`; the popup is a real terminal |

```toml
[popup.htop]
command = ["htop"]
size = "90%x85%"
persistent = true

[statusbar]
enabled = true
template = "#[align=right]#[popup=htop]#[label]CPU#[default] #{p-3:flash.plugin.sysinfo.cpu_label} #[label]MEM#[default] #{p-3:flash.plugin.sysinfo.memory_label}#[nopopup] %H:%M"

[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.normal.mappings]
"<leader>p" = ["flash", "mode", "terminal", "--name=htop"]
"<leader>P" = ["flash", "mode", "flashlight", "--query=@processes"]
```

## Using both

htop and Flash do not overlap at run time: Flash's figures come from its
own sandboxed system plugin, so the bar keeps updating whether htop runs or
not, and htop in a popup is the same htop as in any terminal. Keep htop in
the terminal you already use for SSH sessions, and add the popup for the
local Mac. If you also use btop, give each its own popup. One popup owns the
keyboard at a time, and focusing another hides the previous one with its
process still running; a separate hover preview can appear beside it.

*Checked 2026-10-23 against the htop [README](https://github.com/htop-dev/htop),
[ChangeLog](https://github.com/htop-dev/htop/blob/main/ChangeLog) and
[releases](https://github.com/htop-dev/htop/releases), and the
[Homebrew formula](https://formulae.brew.sh/formula/htop).*
