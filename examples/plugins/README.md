# Example plugins in other languages

Three bundled plugins ported off Rust to road-test the claim in
`docs/plugin-protocol.md`: any executable speaking length-prefixed
MessagePack over stdio is a valid plugin. Each port carries its own
~150–200-line protocol shim (`flashplugin.*`) — framing, a hand-rolled
MessagePack subset, and the v3 lifecycle — plus the actual plugin logic,
which stays comparable in size to the Rust original.

| Example | Ports | Language / runtime | Exercises |
| --- | --- | --- | --- |
| `python-aiproviders` | `Plugins/aiproviders` | system `/usr/bin/python3`, stdlib only | lifecycle, `command.invoke` via `!py*` bangs, subprocess (`open`, osascript) |
| `ts-emojis` | `Plugins/emojis` (curated dataset) | Bun + TypeScript | the warm-catalog contract: publish-before-ready, `published_sources` gate, `sources.snapshot` from memory |
| `go-spotify` | `Plugins/spotify` | Go (zero deps) | the **sandboxed third-party install** compiling the plugin (`go build`), then the compiled command surface |

## Try them

Conformance smoke (no Flash needed) — from an example's directory:

```bash
python3 ../driver.py -- /usr/bin/python3 main.py                # python-aiproviders
python3 ../driver.py --snapshot -- bun run main.ts              # ts-emojis
go build -o flash-plugin-go-spotify . && python3 ../driver.py -- ./flash-plugin-go-spotify
```

Load into Flash as third-party plugins:

```toml
[plugins]
third_party = [
  "file:/Users/ab/workspace/aymericbeaumet/flash/examples/plugins/python-aiproviders",
  "file:/Users/ab/workspace/aymericbeaumet/flash/examples/plugins/ts-emojis",
  "file:/Users/ab/workspace/aymericbeaumet/flash/examples/plugins/go-spotify",
]
```

Then: `!pyclaude how do I …` (Python), `:flashlight @ts-emojis.glyphs ` (TS),
`:go-spotify status` (Go).

## UX findings

- **The protocol really is the boundary.** No host changes were needed for
  any language; the strict manifest schema, quotas, and deadlines are all
  enforced host-side, so a sloppy shim fails loudly instead of corrupting
  state. The v3 stamp caught every hand-rolled framing mistake during
  development as a clean handshake error.
- **The per-language tax is the shim, and it's one-time.** ~150–200 lines
  of MessagePack + framing + lifecycle per language; the plugin logic on
  top is roughly the same size as the Rust original (aiproviders: ~60
  lines of Python vs ~100 of Rust). A real multi-language SDK would just
  be these shims, published.
- **Interpreted plugins need a stable interpreter path.** `exec` argv wants
  an absolute runtime path (`/usr/bin/python3` is universal; the Bun path
  here is this machine's mise install — edit it for yours). Bare-name PATH
  resolution currently exists only for `sandbox.exec` tool allowlists, not
  for `exec` argv[0]; that's the first thing to generalize if non-Rust
  plugins become common.
- **The sandboxed install held for a real compile.** `go build` ran under
  the third-party install profile — login-shell PATH found the toolchain,
  GOCACHE landed inside the redirected HOME under the plugin's data dir,
  and the resulting static binary runs like any bundled plugin.
- **What the Rust SDK still buys you**: SDK-side quota validation before
  frames hit the wire, bounded event queues with watchdogs, the audited
  `run_command` subprocess discipline, compile-time manifest↔handler
  enforcement, and the in-memory test harness. Ports get none of that —
  the host's enforcement is the only net — which is the honest argument
  for keeping Rust as the blessed first-party path.
- **Single-threaded blocking loops are fine** for command plugins (Python,
  Go examples), and Bun's async stream loop maps naturally onto the
  warm-catalog model. None of the three needed threads.

`driver.py` is the reusable conformance tool: initialize → heartbeat →
optional `sources.snapshot` → shutdown, PASS/FAIL exit code.
