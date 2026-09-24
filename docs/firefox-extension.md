# Firefox tab-bridge add-on

The `firefox` plugin surfaces Firefox tabs in the flashlight. It works with no
browser add-on at all: an Accessibility walk of the tab strip, with URLs filled
in from the compressed session store. That path is complete but imprecise —
the strip exposes titles more reliably than URLs, and it cannot tell Flash
which window is frontmost when several are open.

The optional add-on in `Plugins/firefox/extension` removes that imprecision by
mirroring the browser's own tab model: exact per-window strip indices, tab
counts, titles, URLs and the focused window id. It is optional in the strict
sense — nothing regresses without it, and the plugin falls back on its own.

## Shape: one-way, read-only

The add-on **pushes**; Flash never calls into the browser.

```
Firefox add-on ──sendNativeMessage──▶ Firefox spawns
                                      flash-plugin-firefox-bridge
                                          │ one framed message in
                                          │ one framed reply out
                                          ▼
                            <plugin data dir>/bridge/tabs-<pid>.json
                                          │
                    flash-plugin-firefox reads it off disk (stat + read)
```

Every arrow is either a browser-owned process spawn or an ordinary file read.
There is no resident native-messaging port, no FIFO, no polled command file and
no Flash-initiated channel to a browser-owned process. `flash-plugin-firefox-bridge`
is spawned by **Firefox**, handles exactly one message, and exits; Flash only
ever reads the file it left behind, the same way it already reads
`sessionstore-backups/recovery.jsonlz4` and `places.sqlite`.

Tab **switching** does not go through the add-on. It keeps using the mechanisms
Flash already owns — host-posted key chords (⌘1..⌘8, ⌘9, ctrl+PgDn/PgUp) and
the Accessibility broker. The bridge only makes them accurate, by supplying the
exact strip position, the window's tab count, and which window is frontmost.

## Two different framings

| | Flash plugin protocol | Firefox native messaging |
|---|---|---|
| Transport | long-lived stdio child of the Flash host | process spawned per message by Firefox |
| Framing | newline-delimited JSON (NDJSON) | 4-byte little-endian length prefix + JSON |
| Lifetime | resident; stdin EOF means shut down | one message, one reply, exit |
| Binary | `flash-plugin-firefox` (the manifest `exec`) | `flash-plugin-firefox-bridge` |

The two never meet, which is exactly why the bridge is a second binary in the
crate rather than a mode of the plugin. The plugin's `manifest.json` `exec`
stays the single main binary, and the repository scanner looks exactly one
level below `Plugins/` for a `manifest.json`, so neither the companion binary
nor `Plugins/firefox/extension/manifest.json` (a WebExtension manifest) is ever
mistaken for a Flash plugin.

## State-file contract

Path: `<FLASH_PLUGIN_DATA_DIR>/bridge/tabs-<firefox pid>.json`, which in a real
install is
`~/Library/Application Support/Flash/Plugins/firefox/bridge/tabs-<pid>.json`.
Keying by pid keeps Firefox release and Developer Edition independent and lets
the plugin ignore a file that belongs to a browser that is no longer running.

```json
{
  "version": 1,
  "sequence": 42,
  "timestamp_ms": 1700000000000,
  "focused_window_id": 2,
  "windows": [{ "id": 1, "focused": false }, { "id": 2, "focused": true }],
  "tabs": [
    {
      "id": 10, "window_id": 2, "index": 0,
      "title": "Inbox", "url": "https://mail.example.com/",
      "active": true, "pinned": false
    }
  ]
}
```

`index` is the browser's own 0-based strip position within its window and
counts pinned tabs — precisely what ⌘1..⌘8 address. `focused_window_id` is the
window a ⌘digit chord would land in: when another application is frontmost no
window reports `focused`, so the add-on falls back to Firefox's last-focused
window, which is the one the browser will route the chord to.

Caps are enforced by the writer AND re-enforced by the reader
(`Plugins/firefox/src/bridge_state.rs` is compiled into both binaries, so they
cannot drift):

- at most 2000 tabs and 200 windows,
- titles truncated to 512 characters, URLs to 2048,
- at most 8 MiB for the encoded file, which is also the maximum native-messaging
  frame the host will accept; a zero-length or oversized frame is rejected
  without reading a body,
- tabs whose `window_id` is not in `windows` are dropped, and a
  `focused_window_id` no window claims is repaired from the window list.

`version` mismatch is rejected outright — there is no dual reader and no
upgrade path. A version bump means the plugin uses its Accessibility walk until
both halves are back in step.

Writes are atomic: the host writes `.tabs-<pid>.json.tmp` and renames it, so the
plugin only ever observes a whole file. The host also prunes state files whose
owning process is gone (an hour after their last write, resolved with a single
`/bin/ps` over the candidate pids; an unanswerable check leaves every file in
place).

## Freshness and the fallback

The add-on publishes on tab and window events (created, removed, moved,
activated, updated for title/url/status/pinned, attached, detached, replaced,
and window created/removed/focus-changed), debounced 300 ms, plus a 60 s
heartbeat. The plugin accepts a state file whose mtime is within 5 minutes.

Anything else — file missing, older than the freshness window, oversized,
unparsable, wrong version — silently hands that Firefox process back to the
Accessibility walk for that refresh cycle. The heartbeat is what makes the
staleness window meaningful: without it an idle browser would look
indistinguishable from an add-on that had been disabled.

The switch between the two paths is logged once per transition (the discovery
path is part of the refresh log's transition key), never per cycle:

```
[firefox] refresh outcome=ok mode=bridge count=37 elapsed_ms=3
[firefox] refresh outcome=ok mode=accessibility count=37 elapsed_ms=211
```

`mode` is one of `bridge`, `accessibility`, `mixed` (two editions running,
only one bridged) or `none`.

## Installing

The add-on **cannot be installed for you**. Firefox only loads add-ons the user
loads, and a permanently installed add-on on Firefox Release must be signed by
Mozilla. Two supported routes:

- **Temporary load (iterating, or a single session).** `about:debugging` →
  *This Firefox* → *Load Temporary Add-on…* → pick
  `Plugins/firefox/extension/manifest.json` (inside the installed bundle:
  `Flash.app/Contents/Resources/Plugins/firefox/extension/manifest.json`).
  A temporary add-on is dropped when the browser restarts.
- **Signed package.** Package the same directory and install the signed XPI.

Either way the native-messaging host manifest must exist **before the add-on
sends its first message**: Firefox resolves the host name per message and fails
the call outright when the manifest is missing — it does not queue and retry.
Install it with:

```sh
'<plugin dir>/flash-plugin-firefox-bridge' install
```

which writes
`~/Library/Application Support/Mozilla/NativeMessagingHosts/com.flash.firefox_bridge.json`
(pointing at the binary that wrote it, and allowing only the
`flash-tab-bridge@aymericbeaumet.com` extension id) and prints the path.

`:firefox setup` copies exactly that command to the clipboard and names the
extension directory; `:firefox status` reports whether the host manifest is
installed, whether each running Firefox has a usable state file, and how old it
is — counts and ages only, never a title or a URL. Both commands are gated by
the plugin's manifest `only_bundle_ids`, so run them with Firefox focused.

Re-run `install` after moving or reinstalling Flash: the host manifest records
an absolute path to the binary.

## Standing prohibitions

- The add-on **never supplies hint targets.** Hints come from the
  Accessibility web-area walk. There is no DOM bridge, and the add-on declares
  no `<all_urls>`/host permissions, no content scripts and no
  `tabs.executeScript` — the `tabs` permission alone yields title and URL.
- The add-on **never reads page DOM**, never sees page content, and has no way
  to act on a page.
- The bridge is **one-way**. Nothing in Flash may send this extension a
  command, and no resident port, socket or FIFO may be added to make it
  two-way: that is AGENTS.md hard rule 4 (plugin children are host-owned stdio
  children speaking newline-delimited JSON; no custom external IPC, sockets,
  Mach services or daemonized clients).
