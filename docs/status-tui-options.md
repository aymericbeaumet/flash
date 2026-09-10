# Status popup CLI choices

The [ready-to-use status configuration](examples/statusbar/README.md) keeps
Cld/Cdx separate from CPU/MEM/DISK/NET/BAT and attaches one focused interactive
terminal to each section. Plugin-owned numeric labels remain cheap cached
reads; hovering presents a terminal that Flash owns.

- **Claude: ccu.** A focused dashboard reads the existing Claude Code login and
  presents the real OAuth session, weekly, and model quota windows. It also
  shows local token/cost history and cost-based projections; those projections
  are not server quota guarantees. `r` or Space refreshes. `-api=false` disables
  its optional HTTP listener. [ccu](https://github.com/sammcj/ccu)
- **Codex: codex-meter.** A standalone dashboard combines live main-account
  quota/reset windows with local session activity. `r` refreshes. It reads the
  existing Codex login without refreshing or rewriting it, and needs at least
  90 × 32 cells. Supplementary model buckets such as Astra remain available in
  Flash's provider details rather than this CLI.
  [codex-meter](https://github.com/h3nock/codex-meter)
- **CPU: macmon.** Apple Silicon CPU/GPU/ANE usage, power, temperature,
  frequency, and memory detail without sudo; `d`, `v`, and `r` change detail,
  chart style, and CPU scaling. It uses private macOS APIs, so future OS
  compatibility belongs to that external CLI. This is a popup child, not a new
  API dependency in Flash's telemetry plugins.
  [macmon](https://github.com/vladkens/macmon)
- **Memory, disks, battery: bottom.** Its custom layouts isolate memory/swap
  plus process sorting/search/actions, volume capacity/I/O, and battery
  charge/power/health. Battery fields depend on the hardware's macOS reporting.
  Focused layouts also avoid collecting every unused widget. Process controls
  are enabled in this setup.
  [bottom](https://github.com/ClementTsang/bottom),
  [layouts](https://bottom.pages.dev/stable/configuration/config-file/layout/),
  [battery](https://bottom.pages.dev/stable/usage/widgets/battery/)
- **Network: nettop.** The macOS-shipped CLI adds per-process bandwidth and
  connection detail beyond the aggregate status metric. The tested command
  runs without sudo: `nettop -n -d -P -s 2 -J bytes_in,bytes_out`. Delta bytes
  cover each two-second sample, rather than being the bar's bytes-per-second
  value. `h` lists controls; `e`/`c` expand/collapse and `j` selects columns.
  Consult `man nettop` on the installed macOS version.
- **Date: calcurse.** Keep the existing isolated read-only calendar/agenda.
  [calcurse manual](https://calcurse.org/files/calcurse.1.html)

CodexBar is a maintained alternative for quota fetching, but its standalone
`usage`/`cards` CLI produces one-shot output rather than an interactive TUI.
Local token/cost tools such as ccusage are not substitutes for subscription
quota. A separate dashboard daemon would duplicate Flash's lifecycle ownership.
[CodexBar CLI](https://github.com/steipete/CodexBar/blob/main/docs/cli.md)

Keep all commands as foreground `[terminal.<name>]` children. Do not add
background services for popup monitoring. Either unbound mouse button pins the
popup; existing click actions win. The same fixed cells hold grey values as
metrics change, and clean `.label` segments let one named popup cover both the
label and metric without nested inline-popup markers.
