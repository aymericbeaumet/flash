# Interactive status strip

The companion [Flash configuration](flash.toml) produces independent quota and
system sections:

```text
Cld  53% Cdx  54% · CPU   9% MEM  42% DISK  68% NET   1.2M/s BAT 100%
```

Labels are yellow; metrics are grey. Percentages reserve four cells, including
100% and unavailable values. NET reserves eight cells across unit changes.
Cld/Cdx show the least remaining quota across the provider's main session and
weekly limits; CPU/MEM/DISK show usage, NET combines download and upload bytes
per second, and BAT shows charge. DISK prefers the startup APFS Data volume and
accounts for shared-container space. Unavailable metrics use a padded dash. Quota badges also become unavailable
after two missed refresh intervals (Claude: 20 minutes; Codex: 4 minutes); the
last-good provider detail tables remain cached. If Claude shows OAuth
unavailable, sign in again through Claude Code with `/login`; the CLI cannot
show live subscription quotas without that login.

Merge the example into the existing configuration; preserve personal mappings,
plugin settings, and feed sections. Copy `bottom-memory.toml`,
`bottom-disks.toml`, `bottom-battery.toml`, and `calcurse/` to
`~/.config/flash/status/`, then create `status/calcurse/notes/` there. Paths in
terminal declarations resolve relative to the Flash configuration file. Use
`$XDG_CONFIG_HOME/flash` when configured.

## Popup tools

| Section | Interactive CLI | Grid | Useful controls |
| --- | --- | --- | --- |
| Cld | `ccu -refresh=30 -api=false` | 100 × 34 | `r`/Space refresh; session, weekly, and model quotas |
| Cdx | `codex-meter --refresh 60` | 100 × 34 | `r` refresh; session/week reset windows and local activity |
| CPU | `macmon --interval 2000` | 92 × 22 | `d` CPU/RAM detail, `v` chart style, `r` CPU scaling |
| MEM | bottom memory/swap + process table | 92 × 22 | Search and sort memory-heavy processes; process actions |
| DISK | bottom capacity/I/O table | 90 × 16 | Navigate and sort volumes; macOS support/simulator mounts filtered |
| NET | `/usr/bin/nettop -n -d -P -s 2 -J bytes_in,bytes_out` | 100 × 28 | `h` help, arrows scroll, `e` expand, `c` collapse, `j` columns |
| BAT | bottom battery widget | 52 × 12 | Charge, consumption, time remaining, and health when available |
| Date | read-only calcurse calendar | 74 × 22 | Calendar/agenda navigation, isolated from Apple Calendar |

All terminal children are owned by Flash and remain in the foreground.
Persistent sessions preserve history while hidden. Ccu's HTTP listener is
explicitly disabled; quota fetching still runs. Codex-meter reads the existing
Codex login, but does not refresh expired credentials. Its detail view covers
main account limits, not supplementary model buckets; Flash's
`aiproviders.codex_details` also retains Astra. Ccu's cost projections are
estimates, separate from its server-reported quota percentages.

Install `bottom`, `macmon`, and `calcurse` with Homebrew. This configuration was
checked with bottom 0.14.7, macmon 0.8.2, calcurse 4.8.2, ccu 0.2.13, and
codex-meter 0.1.1. The quota tools are standalone release binaries in
`~/.local/bin`; no companion app or daemon is installed. Reproduce them from
[ccu v0.2.13](https://github.com/sammcj/ccu/releases/tag/v0.2.13) and
[codex-meter v0.1.1](https://github.com/h3nock/codex-meter/releases/tag/v0.1.1),
verifying the published checksums before installation. ARM64 artifacts checked:

| Artifact | SHA-256 |
| --- | --- |
| `ccu-darwin-arm64` | `62874b1266e52cd670e3c27febf598d45794e1fe2541505e04a0f4675ca2863c` |
| `codex-meter-v0.1.1-macos-aarch64.tar.gz` | `cbd64f13eafc13f32f5d98706c8dd9933a320161868210d21fe202e6136f322f` |

Hover previews the CLI. Either unbound mouse button pins it open and repeated
clicks keep it pinned. Configured left-click actions and links retain their
action; right-click or Option-left-click pins those linked sections. The current
configuration schema has no separate right-click binding. Command-W hides,
Command-R restarts immediately, and Command-Q quits the child so Flash's
automatic restart can relaunch it. Shift-click opens terminal links.

Bottom process actions are enabled; its configuration no longer forces
read-only mode. Calcurse remains a read-only personal calendar preview: the
supplied data stays empty, saving/reminders/daemon mode are disabled, and no
other calendars are imported. Restart a named terminal after changing the
CLI's own configuration, for example `flash terminal_restart --name=memory`.

See [tool choices and limitations](../../status-tui-options.md) and
[terminal lifecycle](../../terminal-popups.md).
