# Status popup TUI options

The configured status strip groups resource monitoring into SYS, retains BAT,
and opens a calendar from the date. The [ready-to-use files](examples/statusbar/README.md)
contain the tested layouts and command declarations. See
[terminal lifecycle](terminal-popups.md) for startup, persistence, and input.

## Configured grouping

| Status group | Persistent view | Purpose |
| --- | --- | --- |
| CPU / MEM / DSK / NET | One shared `bottom` dashboard | CPU, memory, disk capacity/I/O, network history, and processes |
| BAT | Bottom's battery widget | Charge, consumption, time remaining, and health where macOS supplies them |
| Clock | Read-only `calcurse` calendar and clock | Add date context rather than duplicate the bar's clock |

Prefer one monitoring process with a deliberate layout over four independent
copies. The initial shared dashboard can also include battery. Bottom's
`--battery` flag affects default/basic layouts; a custom TOML layout must
declare its battery widget explicitly.

Minimal shared dashboard declaration (the supplied setup adds a custom layout):

```toml
[terminal.system]
persistent = true
command = ["btm", "--battery", "--read_only", "--rate", "2s"]
columns = 100
rows = 28
```

Anchor it with `#[popup=system]SYS#[nopopup]`. Existing plugin summaries
contain their own inline popup markers, so merely wrapping those summaries
with another popup marker does not override their hover target. Keep this
choice explicit when composing the status strip. A custom bottom layout
reduces the default widget set to keep the numeric CPU, memory, network, disks,
and processes visible at this grid.

For a focused battery view, the supported argv is
`btm --battery --default_widget_type battery --expanded --read_only --rate 5s`.
Another process repeats some collection work. Bottom's interface totals are
not per-process bandwidth.

Sources: [bottom](https://github.com/ClementTsang/bottom),
[layouts](https://bottom.pages.dev/stable/configuration/config-file/layout/),
[battery widget](https://bottom.pages.dev/stable/usage/widgets/battery/).

## Alternatives

- `macmon --interval 2000` provides Apple Silicon CPU/GPU/ANE power, frequency,
  temperature, and RAM details without sudo. It uses private macOS APIs and
  does not replace disk, network, or battery views.
  [macmon](https://github.com/vladkens/macmon)
- `btop --update 2000` is an all-in-one alternative with disk, network,
  processes, and a battery meter. Install with `brew install btop`.
  [btop](https://github.com/aristocratos/btop)
- `calcurse --read-only --quiet` is a persistent calendar/agenda TUI, available
  through `brew install calcurse`. It uses its own calendar data; installing
  it does not import Apple Calendar. For only a month grid, the existing
  document popup can present `cal` output without adding an organizer.
  [calcurse CLI](https://calcurse.org/files/calcurse.1.html)
- `tty-clock -c -s -n -f "%a %d %b %Y"` is a simpler clock/date display,
  available through `brew install tty-clock`.
  [tty-clock](https://github.com/xorg62/tty-clock)

Hover shows a passive preview. Click the label to pin and focus it for
keyboard or mouse interaction; click again to close. Option-click preserves
this gesture on labels that also have a link. Bottom keeps navigation,
sorting, and searching in read-only mode. Plain Escape remains TUI input;
the inherited NORMAL mapping exits to the previous application.
