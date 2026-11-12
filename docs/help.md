# Browser help

Flash's browser help combines this documentation with the state of the
running resident. `flash help show` opens its homepage; `:help` (or `:h`) works after
opening the command line with `:` in NORMAL or `flash mode command`.
The default NORMAL `?` mapping opens
the effective mapping table, as does `:mappings`; the [mapping syntax](mappings.md)
page is `:help mappings`.

`:help <topic>` and `flash help show --topic=<topic>` open `/docs/<topic>`:
a page of the documentation by its path or one of its aliases (`config`, `grid`,
`start`, `doctor`), else a plugin's own guide. In the command line the topic
may be cut to a unique prefix (`:h plug`), like any other word there
([commands](commands.md#command-line-abbreviations)).

```text
:help plugins
:help normal-mode
:help widgets
:help config
```

The homepage is one checklist for this Mac. It marks permissions, the config
file, shortcuts, plugins, and the status bar from the resident's state, and it
remembers which pages of the documentation this browser has opened. Items in "What
is missing" open their linked page when they have one; otherwise they jump to
their checklist step. Plugin manifests add their own guides, listed under
Plugin guides in the documentation sidebar.

## Documentation

Documentation lists every page of the repository's `docs/`,
in the order `docs/nav.json` gives, bundled with the app so it describes the
installed version. The same pages are published at
<https://aymericbeaumet.github.io/flash/>: one source, one renderer. The help
serves a page at `/docs/<page>` (`/docs/alternatives/neru`) and the site at
`/flash/<page>/`, with the same content, sidebar, outline and design; only
the shell differs, since the site has no resident behind it. There the live
pages are a note pointing at `?` in NORMAL and `:help`, and the top bar links
the repository instead of showing the connection.

## Live reference

Each live page's header holds two controls: **? About this page** folds a
short explanation of that page open, and **Documentation →** opens the page
of this documentation that covers it.

| Page | What it describes |
| --- | --- |
| Mappings | Effective bindings after defaults, plugin contributions and user overrides, grouped by mode. A blank search stays alphabetical by command. The search ranks what a binding does, including typos. Each row has a small copy control for a TOML snippet that changes the binding; the Source column links plugin origins to their details and config origins to the live editor |
| Keyboard | The `[keyboard] layout` drawn as keys, each showing what it does in the mode Flash is in: the bindings of that mode and `all`, the hint alphabet with each key's ease while labels are up, the grid block while the grid is up, the adjust, pointer and search keys in their sessions, and the zone of `label_order = "zones"`. Follows the resident's mode and hint session over the event stream, or a mode picked by hand. Selecting a key lists its bindings. Nothing typed is shown, only what Flash is ready for |
| Commands | Built-in and installed plugin command definitions, sorted alphabetically |
| Plugins | Loaded manifests, process health, errors and capabilities. Selecting Inspect details opens a dialog; Escape or its close button dismisses it |
| Runtime | Current mode, app, configuration diagnostics, permissions, input capture, hints and window state. Resolved configuration is JSON: default values keep the base colour, and an override is marked with the layer that set it. Config provenance links jump to the editor on the same page; Purge defaults removes bundled values in the editor and Save writes the file |
| Monitors | Every `[monitors.<name>]`, built-in or configured, worst first (error, warning, unknown, OK, then disabled): a dial with its warning and error thresholds, the value as shown and direction, how long it has been in its state, the last alert, the sampling interval, its message, source and expression (see [monitors](monitors.md#the-monitors-page)). State tiles filter the list. Without monitors the page says how to configure `[monitors.<name>]` and links the manual. `flash monitors show` opens it |
| Telemetry | The OpenTelemetry receiver and exporter: whether each is on, the receiver's address and counts per signal, refusals, the exporter's endpoint, signals, header names, sent and dropped items and last error. Below them every received metric with each series' attributes, latest value, rate, total or percentiles and a sparkline, with the `#{flash.otel…}` snippet that reads it; recent received log records; and recent traces as compact waterfalls (see [telemetry](telemetry.md#the-telemetry-page)). `flash telemetry show` opens it |
| Logs | Recent structured diagnostics and interaction traces |
| Clipboard | Live text registers (unnamed, latest yank and named buffers) as one table of key, contents, type and size, above a dense history of recent text, images, formatted copies and files from core history: kind, a one-line preview with an image thumbnail, size or pixel dimensions, and copy, pin and delete actions that appear on hover, focus or selection. Pinned entries list first, marked with a pin. A type filter and search narrow it; `j` `k` or the arrows move, `↩` copies, space opens an entry, `p` pins or unpins it and `⌫` deletes it. The page requests history directly on opening and loads it in pages |

The browser follows the resident's event stream: Flash pushes a snapshot when
something it shows changes, never on a timer, and the page derives uptimes
from the start times it carries. A new stream receives the whole state once;
every later push is a patch of the sections that changed, so a status bar
that updates several times a second resends only the bar, and the page
recomputes only what shows it. The page folds pushes in as they arrive and
draws them once per frame, so a hidden tab draws nothing until it is shown
again. The snapshot is built on the resident's
main thread, so it carries previews and keeps big values behind endpoints:
a clipboard entry is its kind, id and one-line preview (the text, formatted
copy and image come from `/api/clipboard/history` and `/api/clipboard/<id>`,
which the Clipboard page reads on opening), a plugin's status segments are
bounded previews, and a plugin's commands appear once, in the top-level
command catalog with the plugin as their source. A change of the status bar,
a popup or a widget rebuilds only its own sections there. Each snapshot notes itself
to the main-thread watchdog and logs its cost at `trace` as
`[latency] inspector_snapshot ms=…`. Plugin CPU time and memory change without an
event, so they read as of the last whole snapshot; Refresh on the runtime page and
Resample on a plugin's details ask for a fresh one. Runtime state can include private app or clipboard data;
see [privacy](privacy.md#local-inspector) before sharing it.

A disconnected browser keeps its last snapshot and never presents it as
current. The top bar's connection mark turns into a warning icon reading
Offline, a banner under it says when Flash stopped answering and which
snapshot is shown, and tells the reader to reopen help with `?` in NORMAL or
`:help` if Flash quit or restarted. Each live page marks its data Stale with
the snapshot's time. The stream reconnects by itself: the browser retries a
dropped stream, the page reopens one it gave up on with backoff up to 30 s,
and Reconnect now tries at once. Flash sends its state and logs to every new
stream, and the page also asks for a snapshot after a reconnect, so it
re-syncs without a reload.

Requests recover the same way. A failure is classified as offline, timeout,
an HTTP status or a contract error (a reply the page cannot read). Offline,
timeout, 5xx, 408 and 429 are retried three times with backoff from 0.5 s;
a refused request or a contract error is not. After the last try the page
shows an inline error naming what failed, with a Retry. A clipboard history
load that stops keeps every entry it loaded, and the older entries an earlier
load had reached, and resumes from the page that failed rather than from the
top: on Resume, or by itself once the stream reconnects. The configuration
editor retries its load on reconnect too, and a failed save keeps its text.

## Notifications

What the help reports in passing is a toast in the bottom-right corner
(along the bottom on a narrow screen): copies, the configuration editor's
Save and Purge defaults, Refresh on the runtime page, and the failures of
copies and clipboard history actions. A confirmation leaves after five
seconds, held while the pointer or focus is on it; a failure stays until it
is dismissed. Configuration diagnostics that appear, change or clear while
the help is open say so on any page, with Show to read them on the runtime
page. While pages of the documentation are new or updated since this
browser last read them, a toast says what their ✨ marks and offers Mark all
as read; dismissing it holds until the documentation changes again.

Several toasts stack, the newest nearest the corner. They never take focus:
their buttons follow the page in Tab order, Escape on one dismisses it, and
a screen reader announces each as it appears. What belongs to a place stays
there: a load that failed with its Retry, a refused save next to the editor,
the offline banner and everything inside a dialog.

## Printing

Every page prints in full, on paper colours: print styles release the app
shell's fixed-height scroll container, drop the navigation, search, filters, toasts and connection status,
repeat table headers across pages and keep rows whole. The log list prints
every filtered record rather than its visible window. Printing the mappings
page gives a complete reference of the effective bindings; filter it first to
print a subset.

How the help routes pages, renders the documentation and is built is in
[browser help internals](help-internals.md).
